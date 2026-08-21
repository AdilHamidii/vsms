// Called by pg_cron every minute (relay-telegram-notify). Jobs:
//   1. Relay the watchdog verdict as a grouped, plain-English page (and the
//      all-clear that names what recovered and for how long).
//   2. Sweep new signups / credit purchases / eSIM purchases / line rentals and
//      alert on each. Purchases and eSIMs are normally alerted INSTANTLY from
//      their own edge functions; this sweep is the safety net that catches
//      anything whose Telegram call failed, and is the only sender for signups
//      (deliberately — alerting on signup from a DB trigger would put a network
//      call inside the Supabase Auth transaction).
//   3. Forward-looking money alerts the bot never had: a free trial about to
//      CONVERT (trial_soon), a trial whose auto-renew was switched OFF
//      (trial_off), a route swallowing orders without ever handing back a
//      number (route_fill), and a support thread left waiting (support_waiting).
//   4. The 6-hourly digest, and once per Paris day a morning brief.
//
// Exactly-once for discrete events is a claim row in telegram_events written
// BEFORE sending, so the instant path and this sweep can never double-send.
// Recurring CONDITIONS (watchdog, support) use an app_config stamp instead, and
// that stamp is written ONLY after a confirmed send — stamping first means one
// dropped Telegram message buys hours of silence during a live outage.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";
import { formatDigest, formatNow } from "../_shared/opsFormat.ts";
import { alertHtml, formatWatchdogPage, formatWatchdogRecovered } from "../_shared/tgAlert.ts";
import { parisFull, until, duration, n as plural } from "../_shared/tgFormat.ts";

const DEV_USER = "825688de-6117-4251-9f90-93b83b41b572";
// 24h, not 30 min: the claim rows make re-scans idempotent, so the only cost
// of a wide window is three small indexed scans per minute — while a narrow
// one PERMANENTLY dropped every signup alert whenever Telegram (or this
// function) was down longer than the window.
const SWEEP_WINDOW_MIN = 24 * 60;
const DIGEST_EVERY_MS = 6 * 60 * 60 * 1000;
const WATCHDOG_REALERT_MS = 6 * 60 * 60 * 1000;
/** A trial converting inside this window is worth waking up for. */
const TRIAL_SOON_MS = 24 * 60 * 60 * 1000;
/** A user waiting longer than this has stopped believing anyone is there. */
const SUPPORT_WAIT_MS = 2 * 60 * 60 * 1000;
const SUPPORT_RENAG_MS = 6 * 60 * 60 * 1000;
/** route_fill: N failures on one (service, country) inside this window. */
const ROUTE_FILL_WINDOW_MIN = 60;
const ROUTE_FILL_AT = 3;
/** The morning brief goes out at the first run at or after this Paris hour. */
const BRIEF_HOUR_PARIS = 9;

/** List price a trial converts to, in milliunits, keyed by product id. The
 *  subscription row carries `price_milli = 0` for the whole trial, so the row
 *  itself cannot answer "how much will this bill" — and a trial converting is
 *  precisely when that number matters. Keep in step with App Store Connect. */
const LIST_PRICE_MILLI: Record<string, number> = {
  "com.anthersystems.VirtualSIM.line.monthly": 9990,
  "com.anthersystems.VirtualSIM.line.yearly": 99990,
  "com.anthersystems.VirtualSIM.mail.monthly": 2990,
  "com.anthersystems.VirtualSIM.mail.yearly": 29990,
};

const PARIS_DAY = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit",
});
const PARIS_HOUR = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/Paris", hour: "2-digit", hour12: false,
});
/** "2026-08-21" in Paris — the key the morning brief dedupes on. A UTC date
 *  would send the brief twice on the day the offset changes. */
function parisDayKey(d: Date): string { return PARIS_DAY.format(d); }
function parisHour(d: Date): number { return Number(PARIS_HOUR.format(d)); }

/** "$99.99" from Apple's milliunits, in the transaction's own currency. Mixed
 *  currencies are never silently totalled anywhere in this bot; this only ever
 *  renders ONE transaction, so the symbol can follow the row. */
function money(milli: number | null | undefined, currency?: string | null): string {
  if (milli == null) return "";
  const amount = (milli / 1000).toFixed(2);
  const cur = (currency ?? "USD").toUpperCase();
  if (cur === "USD") return `$${amount}`;
  if (cur === "EUR") return `€${amount}`;
  if (cur === "GBP") return `£${amount}`;
  return `${amount} ${cur}`;
}

/** Read `price`/`currency`/`storefront` out of a stored Apple JWS.
 *
 *  `iap_receipts` persists the signed JWS and no price column, so this is the
 *  only place the amount actually billed exists — and it is the amount BILLED,
 *  not a USD list price: the store charges by storefront (credits.12 is $4.99
 *  in the USA and €5.99 in France), so a hardcoded ladder would misprice every
 *  non-USD sale. Same reasoning as `jws_payload()` in revenue_snapshot.
 *
 *  Signature is NOT verified here — it already was, by `iap-verify`, before the
 *  row was written. Nothing downstream of this reads money; it is display only. */
function jwsPayload(raw: string | null | undefined): {
  price?: number; currency?: string; storefront?: string; productId?: string;
} {
  if (!raw) return {};
  try {
    const seg = raw.split(".")[1];
    if (!seg) return {};
    const b64 = seg.replace(/-/g, "+").replace(/_/g, "/");
    const pad = b64.length % 4 ? "=".repeat(4 - (b64.length % 4)) : "";
    return JSON.parse(atob(b64 + pad));
  } catch {
    return {};                                   // display only — never fatal
  }
}

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  return !!header && !!expected && header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) return json({ error: "unauthorized" }, { status: 401 });

  // Not configured yet (no BotFather token / chat id): no-op quietly rather
  // than throwing a 500 from the cron every single minute.
  if (!Deno.env.get("TELEGRAM_BOT_TOKEN") || !Deno.env.get("TELEGRAM_CHAT_ID")) {
    return json({ skipped: "telegram_not_configured" });
  }

  const sb = admin();
  const now = new Date();
  const since = new Date(now.getTime() - SWEEP_WINDOW_MIN * 60_000).toISOString();
  let sent = 0, failed = 0;

  /** app_config read that never throws and never hides an error. */
  async function readCfg<T>(key: string): Promise<T | null> {
    const { data, error } = await sb
      .from("app_config").select("value").eq("key", key).maybeSingle();
    if (error) {
      console.error(JSON.stringify({ alert: "app_config_read_failed", key, detail: error.message }));
      return null;
    }
    return (data?.value ?? null) as T | null;
  }

  async function writeCfg(key: string, value: unknown): Promise<void> {
    const { error } = await sb.from("app_config").upsert(
      { key, value, updated_at: new Date().toISOString() }, { onConflict: "key" },
    );
    if (error) console.error(`app_config write failed key=${key}: ${error.message}`);
  }

  // ── Watchdog alerting. run_watchdog() (plain-SQL pg_cron, every 10 min —
  //    survives even a dead edge/CRON_SECRET layer) writes its verdict to
  //    app_config.'watchdog'; this minutely run is the transport that turns
  //    that verdict into a page. Alerts when the failing set CHANGES or every
  //    6h while broken; sends a one-shot all-clear on recovery. If THIS
  //    function is dead the page can't go out — but then the digest below
  //    also stops, which is the documented human-observable backstop.
  try {
    // ⚠️ THE ERROR IS DESTRUCTURED, and that is not cosmetic. supabase-js
    // RETURNS errors rather than throwing, so a failed read left `wdRow` null,
    // skipped this entire paging block, and returned `200 {sent:0}` —
    // byte-identical to a healthy quiet run. The alert channel would fail in
    // exactly the same shape as "nothing is wrong", which is the one failure
    // mode a monitoring transport must not have.
    const { data: wdRow, error: wdErr } = await sb
      .from("app_config").select("value").eq("key", "watchdog").maybeSingle();
    if (wdErr) {
      // Cannot page about this through the channel that just failed, so make
      // it loud where it CAN be seen, and let the digest's silence be the
      // human-observable backstop the header describes.
      console.error(JSON.stringify({
        alert: "watchdog_read_failed", detail: wdErr.message,
      }));
    }
    if (wdRow?.value) {
      const w = wdRow.value as {
        failing?: { check?: string; detail?: string }[];
        last_alert_at?: string | null;
        alerted?: string[] | null;
        checked_at?: string | null;
      };
      const failing = [...(w.failing ?? [])];

      // THE WATCHDOG'S OWN DEATH WAS INVISIBLE. run_watchdog() stamps
      // checked_at every 10 minutes and nothing ever read it — so if the pg_cron
      // job were unscheduled, or the function raised, the last stored verdict
      // (today: `failing: []`) would persist forever and every channel would
      // report perfect health indefinitely. That is strictly worse than the
      // documented telegram-notify blind spot, which at least shows up as digest
      // silence. A stale verdict is now itself a failing check.
      const wdAgeMs = w.checked_at ? Date.now() - new Date(w.checked_at).getTime() : Infinity;
      if (wdAgeMs > 30 * 60 * 1000) {
        failing.push({
          check: "watchdog_stale",
          detail: w.checked_at
            ? `last ran ${Math.round(wdAgeMs / 60000)} min ago — the watchdog itself is not running`
            : "never recorded a run — the watchdog itself is not running",
        });
      }
      const names = failing.map((f) => f.check ?? "?").sort();
      const alerted = (w.alerted ?? []).slice().sort();
      const changed = JSON.stringify(names) !== JSON.stringify(alerted);
      const due = !w.last_alert_at ||
        Date.now() - new Date(w.last_alert_at).getTime() >= WATCHDOG_REALERT_MS;

      // How long each check has been failing. It CANNOT live in the watchdog
      // row: run_watchdog() rebuilds that object from scratch every 10 minutes
      // and carries forward only `alerted`/`last_alert_at`, so any extra key we
      // wrote there would be silently dropped between runs. Its own key, kept
      // by this function, which runs every minute.
      const sinceMap = (await readCfg<Record<string, string>>("watchdog_since")) ?? {};
      const nowIso = now.toISOString();
      let sinceChanged = false;
      for (const nm of names) {
        if (!sinceMap[nm]) { sinceMap[nm] = nowIso; sinceChanged = true; }
      }
      const recoveredNames = alerted.filter((a) => !names.includes(a));
      const recoveredSince: Record<string, string> = {};
      for (const nm of Object.keys(sinceMap)) {
        if (!names.includes(nm)) {
          recoveredSince[nm] = sinceMap[nm];
          delete sinceMap[nm];
          sinceChanged = true;
        }
      }
      if (sinceChanged) await writeCfg("watchdog_since", sinceMap);

      if (failing.length > 0 && (changed || due)) {
        const r = await sendMessage(formatWatchdogPage(failing, { sinceMap, now }));
        if (r.ok) {
          sent++;
          await sb.from("app_config").update({
            value: { ...w, last_alert_at: new Date().toISOString(), alerted: names },
          }).eq("key", "watchdog");
        } else { failed++; console.error("watchdog alert send failed", r.status, r.body); }
      } else if (failing.length === 0 && alerted.length > 0) {
        const r = await sendMessage(
          formatWatchdogRecovered(recoveredNames.length ? recoveredNames : alerted,
            recoveredSince, now),
        );
        if (r.ok) {
          sent++;
          await sb.from("app_config").update({
            value: { ...w, last_alert_at: null, alerted: [] },
          }).eq("key", "watchdog");
        } else { failed++; console.error("watchdog all-clear send failed", r.status, r.body); }
      }
    }
  } catch (e) {
    console.error("watchdog alerting failed (sweep continues):", e);
  }

  /** Claim (kind, ref) and send. Returns true only if WE sent it. The claim is
   *  released again on send failure so the next run retries. */
  async function claimAndSend(kind: string, ref: string, html: string): Promise<boolean> {
    const { data: claimed, error } = await sb
      .from("telegram_events")
      .insert({ kind, ref })
      .select("ref")
      .maybeSingle();
    // 23505 = another path already claimed this (kind, ref) — the normal,
    // expected case. ANY OTHER code is a bug that loses the alert forever with
    // no trace: a 23514 (kind missing from telegram_events_kind_check, i.e. a
    // new kind shipped without its migration) reads identically here, and that
    // has already happened once (`iap_unknown`, fixed in 20260806090000).
    if (error) {
      if (error.code !== "23505") {
        console.error(`telegram claim failed for ${kind}/${ref}:`,
                      error.code, error.message);
      }
      return false;
    }
    if (!claimed) return false;

    // The claim is already written, so ANY failure path below must release it
    // or that event can never be alerted again.
    let ok = false, detail = "";
    try {
      const r = await sendMessage(html);
      ok = r.ok;
      detail = ok ? "" : `${r.status} ${r.body ?? ""}`;
    } catch (e) {
      detail = String(e);
    }
    if (ok) { sent++; return true; }

    failed++;
    console.error(`telegram send failed kind=${kind} ref=${ref}`, detail);
    await sb.from("telegram_events").delete().eq("kind", kind).eq("ref", ref);
    return false;
  }

  // ── Signups. profiles.created_at is written by handle_new_user() in the same
  //    transaction as the auth.users row, so it is an exact signup timestamp.
  const { data: signups } = await sb
    .from("profiles")
    .select("user_id, display_name, created_at")
    .gte("created_at", since)
    .neq("user_id", DEV_USER);

  // One message each normally; a burst gets coalesced so a viral hour can't
  // hit Telegram's ~1 msg/sec-per-chat limit and lose alerts to rate limiting.
  const newSignups = signups ?? [];

  // The granted amount comes from the ledger, never a constant: the bonus has
  // already changed 5→1→3→1, and a hardcoded figure was lying within hours of
  // the last change.
  const bonusByUser = new Map<string, number>();
  if (newSignups.length > 0) {
    const { data: bonusRows } = await sb
      .from("wallet_transactions")
      .select("user_id, delta")
      .eq("reason", "signup_bonus")
      .in("user_id", newSignups.map((p) => p.user_id));
    for (const b of bonusRows ?? []) bonusByUser.set(b.user_id as string, b.delta as number);
  }
  if (newSignups.length > 3) {
    const refs: string[] = [];
    for (const p of newSignups) {
      const { data: claimed } = await sb
        .from("telegram_events").insert({ kind: "signup", ref: p.user_id })
        .select("ref").maybeSingle();
      if (claimed) refs.push(p.user_id);
    }
    if (refs.length > 0) {
      const r = await sendMessage(alertHtml({
        sev: "ℹ️", title: `${refs.length} new signups`,
        what: `in the last sweep window`,
        at: now,
      })).catch((e) => ({ ok: false, status: 0, body: String(e) }));
      if (r.ok) sent++;
      else {
        failed++;
        // Release every claim so the next run retries them.
        for (const ref of refs) {
          await sb.from("telegram_events").delete().eq("kind", "signup").eq("ref", ref);
        }
      }
    }
  } else {
    for (const p of newSignups) {
      const name = p.display_name ? esc(p.display_name) : "someone";
      // A MISSING row means NO grant, not an unknown one. handle_new_user
      // writes wallet_transactions only when v_bonus > 0, so once the signup
      // grant went to 0 permanently (2026-08-04) every new signup landed on
      // the old `: "welcome credit granted"` fallback — an ops alert asserting
      // a grant that never happened, on every single signup. It read exactly
      // like the grant was still live and prompted "are you sure it's 0?".
      //
      // Same defect the comment above warns about, one branch further down:
      // the figure was made dynamic, but the no-figure case still claimed a
      // credit. Absence of evidence was rendered as evidence.
      const b = bonusByUser.get(p.user_id) ?? 0;
      const bonusLine = b > 0
        ? `${b} free credit${b === 1 ? "" : "s"} granted`
        : "no signup credit (grant is 0)";
      await claimAndSend("signup", p.user_id, alertHtml({
        sev: "ℹ️", title: "New signup",
        what: `${name}\n${bonusLine}`,
        at: p.created_at as string,
      }));
    }
  }

  // ── Credit purchases (safety net; normally sent instantly by iap-verify).
  const { data: buys } = await sb
    .from("iap_receipts")
    .select("id, user_id, product_id, granted_credits, environment, created_at, raw_jws")
    .gte("created_at", since)
    .neq("user_id", DEV_USER);

  for (const b of buys ?? []) {
    const pack = String(b.product_id).split(".").pop();
    const p = jwsPayload(b.raw_jws as string | null);
    const amount = p.price != null ? money(p.price, p.currency) : null;
    const where = p.storefront ? ` · ${esc(p.storefront)}` : "";
    const what =
      `<b>${amount ?? "amount unknown"}</b>${where}\n` +
      `${b.granted_credits} credits · pack ${esc(pack)}` +
      (b.environment !== "Production" ? `\n${esc(String(b.environment))} — no money moved` : "");
    await claimAndSend("purchase", String(b.id), alertHtml({
      sev: "🟢", title: "Credits purchased", what, at: b.created_at as string,
    }));
  }

  // ── eSIM purchases (safety net; normally sent instantly by create-esim-order).
  const { data: esims } = await sb
    .from("esim_orders")
    .select("id, user_id, plan_id, cost_credits, status, created_at")
    .gte("created_at", since)
    .neq("user_id", DEV_USER);

  for (const e of esims ?? []) {
    await claimAndSend("esim", String(e.id), alertHtml({
      sev: "🟢", title: "eSIM purchased",
      what: `${e.cost_credits} credits · plan ${esc(e.plan_id)} · ${esc(String(e.status))}`,
      at: e.created_at as string,
    }));
  }

  // ── Second-number rentals (safety net; normally sent instantly by
  //    verify-line-subscription, or by apple-notifications' SUBSCRIBED branch).
  //    Ref matches both instant paths — original_transaction_id — so the
  //    (kind, ref) claim dedupes across all three senders; the id fallback
  //    covers lines with no Apple transaction (credits-billed).
  const { data: rentedLines } = await sb
    .from("phone_lines")
    .select("id, e164, original_transaction_id, status, billing, created_at")
    .gte("created_at", since)
    .neq("user_id", DEV_USER);

  // The subscription row is where the money is: price, currency, storefront and
  // — for a trial — the date it stops being free. A rental alert that does not
  // say "this converts to $99.99 on 24 Aug" is missing the only number in it.
  const lineTxIds = (rentedLines ?? [])
    .map((l) => l.original_transaction_id as string | null)
    .filter((x): x is string => !!x);
  const lineSubs = new Map<string, Record<string, unknown>>();
  if (lineTxIds.length > 0) {
    const { data: subs } = await sb
      .from("line_subscriptions")
      .select("original_transaction_id, product_id, state, auto_renew, expires_at, price_milli, currency, storefront")
      .in("original_transaction_id", lineTxIds);
    for (const s of subs ?? []) {
      lineSubs.set(String(s.original_transaction_id), s as Record<string, unknown>);
    }
  }

  for (const l of rentedLines ?? []) {
    const tx = l.original_transaction_id as string | null;
    const sub = tx ? lineSubs.get(tx) : undefined;
    const lines = [`${esc(l.e164 ?? "(provisioning)")} · ${esc(String(l.status))}`];
    if (sub) {
      const priceMilli = sub.price_milli as number | null;
      const product = String(sub.product_id ?? "");
      const isTrial = priceMilli === 0;
      const store = sub.storefront ? ` · ${esc(String(sub.storefront))}` : "";
      if (isTrial) {
        const willBill = LIST_PRICE_MILLI[product] ?? null;
        lines.push(`free trial${store}`);
        if (sub.expires_at) {
          lines.push(
            `converts <b>${parisFull(sub.expires_at as string)}</b> ` +
            `(${until(sub.expires_at as string, now)})` +
            (willBill != null ? ` at <b>${money(willBill, sub.currency as string)}</b>` : ""),
          );
        }
      } else {
        lines.push(`<b>${money(priceMilli, sub.currency as string)}</b>${store}`);
      }
    } else if (l.billing === "credits") {
      lines.push("billed in credits");
    }
    await claimAndSend("line", String(tx ?? l.id), alertHtml({
      sev: "🟢", title: "New second number",
      what: lines.join("\n"),
      at: l.created_at as string,
    }));
  }

  // ── trial_soon / trial_off.
  //
  //    A trial is stored with `price_milli = 0` for its whole length, so the
  //    subscription row looks identical to a free one right up to the moment
  //    Apple bills $99.99. These two alerts are the only forward-looking money
  //    signals the bot has: one says revenue is about to land (or is about to
  //    be a refund request), the other is the churn signal — a trial with
  //    auto-renew switched off will never convert, and the window to do
  //    something about it is exactly the remaining trial.
  try {
    for (const table of ["line_subscriptions", "email_subscriptions"] as const) {
      const { data: subs, error } = await sb
        .from(table)
        .select("original_transaction_id, user_id, product_id, state, auto_renew, expires_at, price_milli, currency, storefront, environment")
        .eq("price_milli", 0)
        .in("state", ["active", "grace"]);
      if (error) { console.error(`${table} trial scan failed: ${error.message}`); continue; }

      for (const s of subs ?? []) {
        const product = String(s.product_id ?? "");
        // "yearly product" per the design: only the yearly plans carry a free
        // trial, and a monthly row at price 0 means something we do not
        // understand — alerting on it would be a guess.
        if (!product.endsWith(".yearly")) continue;
        const tx = String(s.original_transaction_id ?? "");
        if (!tx) continue;
        const expIso = s.expires_at as string | null;
        const willBill = LIST_PRICE_MILLI[product] ?? null;
        const store = s.storefront ? ` · ${esc(String(s.storefront))}` : "";
        const sandbox = s.environment && s.environment !== "Production"
          ? `\n${esc(String(s.environment))} — no money will move` : "";

        if (s.auto_renew === false) {
          // ℹ️ once per subscription. The ref is the original transaction, so a
          // user who toggles auto-renew back on and off again does not re-page:
          // the FIRST switch-off is the signal, and a second one adds nothing.
          await claimAndSend("trial_off", tx, alertHtml({
            sev: "ℹ️", title: "Trial will not convert",
            what: `${esc(product.split(".").pop() ?? product)}${store}\n` +
              `auto-renew is OFF` +
              (expIso ? ` · access ends ${parisFull(expIso)}` : "") + sandbox,
            why: "This one is already lost — the only window to change their mind is the rest of the trial.",
            at: now,
          }));
          continue;
        }

        if (!expIso) continue;
        const msLeft = new Date(expIso).getTime() - now.getTime();
        if (!(msLeft > 0 && msLeft <= TRIAL_SOON_MS)) continue;

        await claimAndSend("trial_soon", tx, alertHtml({
          sev: "🟠", title: "Trial converts within 24h",
          what: `<b>${parisFull(expIso)}</b> (${until(expIso, now)})\n` +
            (willBill != null ? `<b>${money(willBill, s.currency as string)}</b>` : "list price") +
            ` · ${esc(product.split(".").pop() ?? product)}${store}` + sandbox,
          why: "Every trial sold so far cancelled within minutes of paying — a conversion that sticks is the first one.",
          action: "Check the product actually works for them before Apple bills it.",
          at: now,
        }));
      }
    }
  } catch (e) {
    console.error("trial alerting failed (sweep continues):", e);
  }

  // ── route_fill: a route swallowing orders and handing back no number.
  //
  //    An order that dies inside create-order closes terminal with a NULL
  //    number: a stockout, a margin refusal, a provider fault. Individually
  //    each is a refund and looks like nothing; three on the SAME route inside
  //    an hour is a route that is dead, and until now the only way to see it
  //    was to go looking. Bucketed to the UTC hour so it re-fires at most once
  //    an hour while the route stays broken, rather than on every third order.
  try {
    const winStart = new Date(now.getTime() - ROUTE_FILL_WINDOW_MIN * 60_000).toISOString();
    const { data: dead, error } = await sb
      .from("orders")
      .select("service_id, country_id, user_id, status")
      .is("smspva_number", null)
      .in("status", ["expired", "canceled", "refunded"])
      .gte("created_at", winStart);
    if (error) console.error("route_fill scan failed:", error.message);

    const buckets = new Map<string, { service: string; country: string; users: Set<string>; nn: number }>();
    for (const o of dead ?? []) {
      const key = `${o.service_id}|${o.country_id}`;
      const b = buckets.get(key) ?? {
        service: String(o.service_id), country: String(o.country_id),
        users: new Set<string>(), nn: 0,
      };
      b.nn++;
      if (o.user_id) b.users.add(String(o.user_id));
      buckets.set(key, b);
    }

    const hourBucket = now.toISOString().slice(0, 13);   // YYYY-MM-DDTHH, UTC
    for (const [key, b] of buckets) {
      if (b.nn < ROUTE_FILL_AT) continue;
      // Provider from ROUTES, never from the order row: `orders.provider`
      // defaults to 'smspva' and is only overwritten once a number is
      // reserved, so a numberless order names the default, not the provider
      // that refused it.
      const { data: rt } = await sb.from("routes").select("provider")
        .eq("service_id", b.service).eq("country_id", b.country).maybeSingle();
      const provider = (rt as { provider?: string } | null)?.provider ?? "unrouted";
      await claimAndSend("route_fill", `${key}|${hourBucket}`, alertHtml({
        sev: "🟠", title: `Route handing back no numbers: ${b.service}/${b.country}`,
        what: `<b>${b.nn}</b> order${b.nn === 1 ? "" : "s"} in the last ` +
          `${ROUTE_FILL_WINDOW_MIN} min closed with no number\n` +
          `${plural("user", b.users.size)} · provider ${esc(provider)}`,
        why: "Every one of these was charged and refunded — the user saw a failure, not a number.",
        action: `<code>/route ${esc(b.service)} ${esc(b.country)}</code> — then block the route or top up the provider.`,
        at: now,
      }));
    }
  } catch (e) {
    console.error("route_fill alerting failed (sweep continues):", e);
  }

  // ── support_waiting: someone asked a question and nobody answered.
  //
  //    A CONDITION, not an event, so it uses a stamp rather than a claim row —
  //    the same shape as create-order's alertLowBalanceBlock, including the
  //    rule that the stamp is written ONLY after a confirmed send. Stamping
  //    first would mean one dropped message buys six hours of a customer
  //    sitting unanswered.
  try {
    const cutoff = new Date(now.getTime() - SUPPORT_WAIT_MS).toISOString();
    const { data: waiting, error } = await sb
      .from("support_threads")
      .select("id, user_id, status, last_message_at")
      .in("status", ["open", "assigned"])
      .eq("last_sender", "user")
      .lt("last_message_at", cutoff)
      .order("last_message_at", { ascending: true });
    if (error) console.error("support_waiting scan failed:", error.message);

    const threads = waiting ?? [];
    if (threads.length > 0) {
      const nag = (await readCfg<{ last_alert_at?: string }>("support_nag")) ?? {};
      const dueNag = !nag.last_alert_at ||
        now.getTime() - new Date(nag.last_alert_at).getTime() >= SUPPORT_RENAG_MS;
      if (dueNag) {
        const oldest = threads[0].last_message_at as string;
        const waitS = (now.getTime() - new Date(oldest).getTime()) / 1000;
        const rows = threads.slice(0, 5).map((t) => {
          const w = (now.getTime() - new Date(t.last_message_at as string).getTime()) / 1000;
          return ` • ${esc(String(t.status))} · waiting ${duration(w)}`;
        });
        const more = threads.length > 5 ? `\n … and ${threads.length - 5} more` : "";
        const r = await sendMessage(alertHtml({
          sev: "🟠",
          title: `${plural("support thread", threads.length)} waiting on you`,
          what: `oldest has waited <b>${duration(waitS)}</b> (since ${parisFull(oldest)})\n` +
            rows.join("\n") + more,
          why: "Impatience is what this product loses users to; a reply inside the wait is the whole point of the channel.",
          action: "Reply to the relayed message in this chat, or run <code>/support</code>.",
          at: now,
        }));
        if (r.ok) { sent++; await writeCfg("support_nag", { last_alert_at: now.toISOString() }); }
        else {
          failed++;
          console.error("support_waiting page FAILED to send — not suppressing, will retry");
        }
      }
    }
  } catch (e) {
    console.error("support_waiting alerting failed (sweep continues):", e);
  }

  // ── 6-hourly digest + the once-a-day morning brief.
  //
  //    Both stamps live in the SAME app_config row, so every write here MERGES
  //    into the existing value. A bare upsert of `{last_digest_at}` would drop
  //    `last_brief_on` and send the brief twice a day, every day — the exact
  //    class of silent regression this file keeps paying for elsewhere.
  let digest = false, brief = false;
  const cfgVal = (await readCfg<{ last_digest_at?: string; last_brief_on?: string }>("telegram_bot")) ?? {};
  const lastAt = cfgVal.last_digest_at;
  const due = !lastAt || (Date.now() - new Date(lastAt).getTime()) >= DIGEST_EVERY_MS;

  if (due) {
    const { data: snap } = await sb.rpc("ops_snapshot", { p_window: "6 hours" });
    // Same 6-hour window as the snapshot above it.
    const { data: dlm, error: dlmErr } = await sb.rpc("lines_money_snapshot", {
      p_window: "6 hours",
    });
    if (dlmErr) console.error("lines_money_snapshot (digest) failed:", dlmErr.message);
    if (snap) {
      const r = await sendMessage(formatDigest(
        snap as Record<string, unknown>,
        dlmErr ? null : (dlm as Record<string, unknown> | null)))
        .catch((e) => ({ ok: false, status: 0, body: String(e) }));
      if (r.ok) {
        digest = true;
        // Stamp only on success, so a failed digest retries next minute.
        cfgVal.last_digest_at = new Date().toISOString();
        await writeCfg("telegram_bot", cfgVal);
      } else {
        failed++;
        console.error("digest send failed", r.status, r.body);
      }
    }
  }

  // The brief is the one message the owner reads without being paged: the
  // whole business on one screen, once, in the morning. Keyed on the PARIS
  // calendar day — a UTC key would send it twice on a DST change — and stamped
  // only after a confirmed send, so a Telegram blip means "next minute", not
  // "tomorrow".
  const todayParis = parisDayKey(now);
  if (parisHour(now) >= BRIEF_HOUR_PARIS && cfgVal.last_brief_on !== todayParis) {
    const { data: nowSnap, error: nowErr } = await sb.rpc("ops_now");
    if (nowErr) console.error("ops_now (brief) failed:", nowErr.message);
    if (nowSnap) {
      const r = await sendMessage(
        `☀️ <b>Morning brief</b>\n\n${formatNow(nowSnap as Record<string, unknown>)}`,
      ).catch((e) => ({ ok: false, status: 0, body: String(e) }));
      if (r.ok) {
        brief = true;
        sent++;
        cfgVal.last_brief_on = todayParis;
        await writeCfg("telegram_bot", cfgVal);
      } else {
        failed++;
        console.error("morning brief send failed", r.status, r.body);
      }
    }
  }

  return json({ sent, failed, digest, brief });
});
