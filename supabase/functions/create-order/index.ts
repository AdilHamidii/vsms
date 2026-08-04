import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { livePriceUsd, markDead, providerOrder, release, reserve, type RouteCodes } from "../_shared/providers.ts";
import { getCountryPrices, isOk } from "../_shared/smspva.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";

interface Body {
  service_id: string;
  country_id: string;
  /** "standard" (default; random SMSPVA pool — today's behavior) or
   *  "premium" (pinned to the route's real-SIM operator, fail-fast). Old
   *  clients never send this. */
  tier?: string;
  /** The user DELIBERATELY wants a second live number for this service while
   *  the first is still held — the site rejected the first one and the 180s
   *  hold means it cannot be released yet.
   *
   *  Sent only by 1.8+, and that matters. `begin_order` dedupes on
   *  (user, service, tier) for 15s specifically to stop a pre-1.6 reroll
   *  double-charging: those clients cancel, ignore the refusal, and create
   *  anyway. Honouring this flag for every client would re-open that.
   *
   *  It does not disable dedupe, it shortens it to 3s — still long enough to
   *  swallow a genuine double-tap (~500ms), far too short to swallow a user
   *  who has walked back through checkout. */
  allow_concurrent?: boolean;
}

/** Dedupe windows in seconds: the default double-tap guard, and the shortened
 *  one used when the client explicitly asks for a concurrent number. */
const DEDUPE_DEFAULT_SECONDS = 15;
const DEDUPE_CONCURRENT_SECONDS = 3;

// Verify-then-charge guard. Before reserving a number we re-check the LIVE
// provider price and refuse unless the credits we'd charge are worth at least
// MIN_MARGIN× that cost. Runs per candidate provider so we never lose money on
// a price spike, and we skip a provider (falling back) rather than overpay.
//
// NET_USD_PER_CREDIT: conservative net revenue per credit — the 30-credit pack
// ($12.99 ≈ $0.433) after Apple's cut, which is the least favourable rung of the
// live ladder. Deliberately pessimistic: valuing a credit high here would let a
// route clear the margin gate on revenue we might not actually collect.
//
// The floor itself is the credits charged being worth at least MARGIN× the
// wholesale cost. That makes the order-time ceiling exactly the pricing sync's
// implied cost line, so honestly-priced routes always clear and anything
// pricier than what we charged is capped or refused. Moving one without the
// other either blocks honest routes or leaks margin.
// PER-PROVIDER since 2026-07-31. The ceiling below is `credits * NET / MARGIN`
// and MUST equal the divisor the route was PRICED with, exactly:
//
//   provider   priced by            divisor    MIN_MARGIN   0.30 / MARGIN
//   herosms    sync-herosms           0.025        12.0         0.025  ✓
//   smspva     sync-prices            0.05          6.0         0.05   ✓
//
// A single global constant cannot express this any more, and getting it wrong
// is silent in the worst direction: too low and every honestly-priced route is
// refused with margin_too_low — charged and instantly refunded — until the next
// sync repriced it, which is exactly what produced 11 of 22 orders in 24h
// closing in under a second with no number on 2026-07-27.
//
// Why the two differ at all: HeroSMS wholesale is far cheaper, so at a shared
// 0.05 its routes would price into the 1-credit band, which measures 18%
// delivery against 46-59% for 2-8 credits. Applying 0.025 to BOTH instead would
// double SMSPVA — 60% of the catalog, and the better-delivering provider — and
// take its 3-credit reach from 729 routes to 16. See the block in sync-herosms.
const MIN_MARGIN_BY_PROVIDER: Record<string, number> = {
  // 10x (owner, 2026-08-03). LOCKSTEP with sync-5sim's CREDIT_DIVISOR = 0.03,
  // because 0.30 / 10 = 0.03 exactly. Move one without the other and you either
  // refuse honest routes (margin_too_low, charged then refunded) or sell under
  // cost on every order.
  "5sim": 10.0,
  herosms: 12.0,
  smspva: 6.0,
};
/** Falls back to the strictest value we use, never to the loosest: an unknown
 *  provider must under-spend rather than overpay on a route nobody priced. */
const MIN_MARGIN_FALLBACK = 12.0;
const marginFor = (provider: string | null | undefined): number =>
  MIN_MARGIN_BY_PROVIDER[provider ?? ""] ?? MIN_MARGIN_FALLBACK;

/** The price HeroSMS says it WILL sell at, out of `WRONG_MAX_PRICE:0.35`.
 *
 *  Suffixed error codes are matched by PREFIX everywhere in this codebase
 *  (see classifyHerosmsFault) because an exact `switch` silently never fires
 *  on them. Same reason the value is parsed rather than assumed: it is the
 *  provider's own current floor for this (country, service), which is the one
 *  number that turns a refusal into a sale.
 *
 *  Returns null for a missing/garbled suffix so the caller keeps the existing
 *  refusal — never a default, which would authorise a spend nobody quoted. */
function wrongMaxPriceUsd(raw: string | undefined): number | null {
  if (!raw) return null;
  const m = /WRONG_MAX_PRICE:\s*([0-9]+(?:\.[0-9]+)?)/i.exec(raw);
  if (!m) return null;
  const usd = Number(m[1]);
  return Number.isFinite(usd) && usd > 0 ? usd : null;
}

const NET_USD_PER_CREDIT = 0.30;

// Absolute slack added to the order-time ceiling so a trivial provider price
// tick doesn't take a route offline between hourly sync-prices runs. Flat, not
// proportional, on purpose: the exposure is bounded at $0.10 per order at any
// price point, while a percentage would grow precisely where it costs most.
// Worst case it trades margin on the cheapest routes (a 2-credit route worth
// $0.60 of revenue may now pay up to $0.20, i.e. 3× rather than 6×) to stop
// losing the order outright — a refunded order earns nothing and burns trust.
const CEILING_HEADROOM_USD = 0.10;

/** How far above the expected wholesale we will still buy (owner decision,
 *  2026-08-02: "be a bit lenient on the margin, all orders should succeed").
 *
 *  THIS DOES NOT REDUCE MARGIN ON ORDERS THAT ALREADY SUCCEED. It is a cap
 *  passed to the provider, not a price: a normal fill comes from the cheapest
 *  pool and earns the full 12x/6x. The cap only binds when the price has moved
 *  since the last sync — and today that order does not earn less, it FAILS,
 *  returning margin_too_low after charging and refunding the user. So the whole
 *  effect of this constant is to convert failures into lower-margin sales.
 *
 *  Sized from measurement, not taste. Across 1,554 (service,country) pairs, the
 *  ratio of the SECOND-cheapest price tier to the cheapest — i.e. what we pay
 *  when the cheap pool empties between hourly syncs — is:
 *      p50 1.11x · p75 1.25x · p90 1.54x · p95 2.03x · p99 6.38x · max 36.8x
 *
 *  But the stronger reason is HOW LITTLE STOCK the cheap tier holds. We do not
 *  choose a pool; we pass maxPrice and the provider fills from the cheapest
 *  thing under it — so this cap decides how much inventory we can even reach.
 *  Measured over the same pairs, the share of a route's TOTAL stock reachable:
 *      cheapest tier only  mean 10.6%  median  6.2%
 *      1.1x (old ceiling)  mean 19.2%  median 13.6%
 *      2.0x                mean 64.9%  median 65.8%
 *      3.0x                mean 77.0%  median 83.6%
 *  23% of routes hold fewer than 100 numbers in the cheapest tier. Capping just
 *  above it means competing for the thinnest slice of the pool while the bulk
 *  sits a few cents higher — a direct cause of "no numbers available" on routes
 *  that demonstrably have hundreds of thousands of numbers.
 *
 *  Set to 3.0 rather than 2.0 because price does NOT predict delivery in our
 *  own data (16% / 19% / 17% / 23% across <=5c, 6-15c, 16-40c, >40c bands,
 *  n=32/69/23/40) — so the dearer stock is not worse stock, just more of it.
 *  There is therefore no quality argument for staying near the floor, and the
 *  only cost is margin, which MAX_REVENUE_FRACTION already bounds.
 *
 *  The flat CEILING_HEADROOM_USD stays ON TOP because the two solve different
 *  problems: the multiple covers a proportional price move, the flat term
 *  covers the exact-boundary rounding case that took 76.7% of the catalog to
 *  zero tolerance on 2026-07-27. */
const CEILING_SLACK_MULTIPLE = 3.0;

/** Hard backstop: never pay more than this fraction of what we charged. With
 *  NET_USD_PER_CREDIT deliberately conservative, half of revenue still leaves
 *  every order at 2x or better, so no order can ever be sold at a loss no
 *  matter what the multiple above is set to or what a future divisor change
 *  does. This is the invariant; CEILING_SLACK_MULTIPLE is the policy. */
const MAX_REVENUE_FRACTION = 0.5;

/** Numberless attempts on one route, by one user, before we start requiring a
 *  gap between tries. Three, because two in a row is plausibly transient — a
 *  stockout that refills, a price that ticks back under the ceiling. */
const FAIL_BREAKER_THRESHOLD = 3;
/** How far back those attempts are counted. */
const FAIL_BREAKER_WINDOW_MS = 10 * 60 * 1000;
/** Once past the threshold, the minimum gap between attempts on that route.
 *  60s is set from the observed storm — 7 orders in 24 seconds — and from the
 *  two real recoveries it must NOT block: those came 4 seconds and 6 minutes
 *  after the last failure, and only the 4-second one is worth refusing. */
const FAIL_BREAKER_COOLDOWN_MS = 60 * 1000;

// ── Failure paging. A total SMS outage used to be indistinguishable from a
//    quiet day: every failed order refunded politely, console.error'd, and no
//    human ever heard. Two channels, both deduped through app_config state:
//    • streak: N consecutive failed order attempts (any cause) pages at 5,
//      then every 6h while it persists; any success resets it.
//    • fault: AUTH_ERROR / BALANCE_ERROR means the provider ACCOUNT is dead
//      (revoked key, empty balance) — that pages immediately, 6h dedupe.
const FAIL_STREAK_ALERT_AT = 5;
const REALERT_MS = 6 * 60 * 60 * 1000;
type Admin = ReturnType<typeof admin>;

async function bumpFailStreak(sb: Admin, lastError: string, routeDesc: string): Promise<void> {
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "order_fail_streak").maybeSingle();
    const v = (data?.value ?? {}) as { n?: number; last_alert_at?: string };
    const n = (v.n ?? 0) + 1;
    const due = !v.last_alert_at ||
      Date.now() - new Date(v.last_alert_at).getTime() >= REALERT_MS;
    const value: Record<string, unknown> = { n, last_alert_at: v.last_alert_at ?? null };
    if (n >= FAIL_STREAK_ALERT_AT && due) {
      // Only record the alert if it actually sent — otherwise one dropped
      // Telegram message buys 6h of silence on an active outage.
      const sent = await notifySafe(
        `🚨 <b>${n} consecutive SMS order failures</b>\n` +
        `latest: ${esc(lastError)} on ${esc(routeDesc)}\n` +
        `Users are being charged and refunded with no numbers delivered.`,
      );
      if (sent) value.last_alert_at = new Date().toISOString();
      else console.error("fail-streak page FAILED to send — will retry next failure");
    }
    await sb.from("app_config").upsert({ key: "order_fail_streak", value }, { onConflict: "key" });
  } catch (e) {
    console.error("fail-streak tracking failed (ignored):", e);
  }
}

/** How many recent numberless failures to keep. Small: this is a diagnostic
 *  tail for "why did N never get a number", not an event log. */
const FAIL_SAMPLE_KEEP = 25;

/** Persist WHY an order never got a number, so the cause survives the request.
 *
 *  `app_config` is RLS-restricted to an explicit key whitelist
 *  (maintenance / announcement / esim_paused), so this key is reachable only
 *  through the service role — it carries carrier names and wholesale costs and
 *  must never join that whitelist. */
async function recordFailureSample(
  sb: Admin,
  route: string,
  lastError: string,
  diag: Record<string, unknown> | null,
): Promise<void> {
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "order_fail_samples").maybeSingle();
    const prev = Array.isArray(data?.value) ? (data.value as unknown[]) : [];
    const next = [
      { at: new Date().toISOString(), route, error: lastError, ...(diag ?? {}) },
      ...prev,
    ].slice(0, FAIL_SAMPLE_KEEP);
    await sb.from("app_config")
      .upsert({ key: "order_fail_samples", value: next }, { onConflict: "key" });
  } catch (e) {
    console.error("failure-sample write failed (ignored):", e);
  }
}

async function resetFailStreak(sb: Admin): Promise<void> {
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "order_fail_streak").maybeSingle();
    if (((data?.value as { n?: number } | null)?.n ?? 0) > 0) {
      await sb.from("app_config")
        .upsert({ key: "order_fail_streak", value: { n: 0 } }, { onConflict: "key" });
    }
  } catch (e) {
    console.error("fail-streak reset failed (ignored):", e);
  }
}

/** Page when a REAL ORDER was refused because the provider float is too small
 *  to fund it.
 *
 *  Deliberately separate from the balance-tier pages in poll-active-orders.
 *  Those say "the balance is trending low" on a fixed ladder and fire whether
 *  or not anyone is trying to buy. This says **a customer just got turned away**
 *  — which is the only version of the fact that costs money, and which the
 *  ladder can miss entirely: after the 2026-08-04 ceiling removal a route can
 *  need $60 of float while the ladder's lowest rung is $7.50, so every tier
 *  reads "fine" while orders are being refused.
 *
 *  It carries the SHORTFALL, not just the balance, because "top up" is not
 *  actionable without knowing how much. The user sees `provider_unreachable`,
 *  which does not say "we are out of float" — this is the only place that fact
 *  surfaces.
 *
 *  Counts refusals between pages and resets on a successful send, so the
 *  message reports a true "since last alert" figure rather than a lifetime
 *  total. Send BEFORE stamping and stamp only on success — the same rule as
 *  the two alerts above: stamping first means one dropped Telegram message
 *  buys 6h of silence during a live outage.
 *
 *  NEVER throws. A paging failure must not turn a clean 503 into a 500. */
async function alertLowBalanceBlock(
  sb: Admin, provider: string, balanceUsd: number, neededUsd: number, routeDesc: string,
): Promise<void> {
  try {
    const KEY = "low_balance_block";
    const { data } = await sb
      .from("app_config").select("value").eq("key", KEY).maybeSingle();
    const v = (data?.value ?? {}) as { n?: number; last_alert_at?: string };
    const n = (v.n ?? 0) + 1;
    const due = !v.last_alert_at ||
      Date.now() - new Date(v.last_alert_at).getTime() >= REALERT_MS;

    const value: Record<string, unknown> = {
      n, last_alert_at: v.last_alert_at ?? null, provider,
      balance_usd: balanceUsd, needed_usd: neededUsd,
    };

    if (due) {
      const short = Math.max(0, neededUsd - balanceUsd);
      const sent = await notifySafe(
        `🚨 <b>Order refused — ${esc(provider)} float too low</b>\n` +
        `balance <b>$${balanceUsd.toFixed(2)}</b>, this order needed ` +
        `<b>$${neededUsd.toFixed(2)}</b> (short $${short.toFixed(2)})\n` +
        `route: ${esc(routeDesc)}\n` +
        `${n} order${n === 1 ? "" : "s"} refused since the last alert. ` +
        `The customer was NOT charged — they saw "provider unreachable". Top up to resume.`,
      );
      if (sent) { value.last_alert_at = new Date().toISOString(); value.n = 0; }
      else console.error("low-balance-block page FAILED to send — not suppressing, will retry");
    }

    await sb.from("app_config").upsert(
      { key: KEY, value, updated_at: new Date().toISOString() }, { onConflict: "key" },
    );
  } catch (e) {
    console.error("low-balance-block alert failed (ignored):", e);
  }
}

async function alertProviderFault(sb: Admin, provider: string, errorType: string, detail: string): Promise<void> {
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "provider_fault_alert").maybeSingle();
    const last = (data?.value as { last_at?: string } | null)?.last_at;
    if (last && Date.now() - new Date(last).getTime() < REALERT_MS) return;
    // Send BEFORE stamping the 6h suppression window, and only stamp on
    // success. Stamping first meant a single failed send silenced "the provider
    // account is dead" for six hours.
    const sent = await notifySafe(
      `🚨 <b>${esc(provider)} account fault: ${esc(errorType)}</b>\n${esc(detail)}\n` +
      `Every order on this provider will fail until this is fixed (key revoked or balance empty).`,
    );
    if (!sent) {
      console.error("provider-fault page FAILED to send — not suppressing, will retry");
      return;
    }
    await sb.from("app_config").upsert({
      key: "provider_fault_alert",
      value: { last_at: new Date().toISOString(), provider, error_type: errorType },
    }, { onConflict: "key" });
  } catch (e) {
    console.error("provider-fault alert failed (ignored):", e);
  }
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.service_id || !body.country_id) {
    return json({ error: "missing_fields" }, { status: 400 });
  }
  const tier = body.tier ?? "standard";
  if (tier !== "standard" && tier !== "premium") {
    return json({ error: "invalid_body" }, { status: 400 });
  }

  const sb = admin();

  const { data: service, error: svcErr } = await sb
    .from("services").select("id, smspva_code, herosms_code, fivesim_product")
    .eq("id", body.service_id).single();
  if (svcErr || !service) return json({ error: "unknown_service" }, { status: 404 });

  const { data: country, error: cErr } = await sb
    .from("countries").select("id, smspva_code, herosms_id, dial_code, fivesim_country")
    .eq("id", body.country_id).single();
  if (cErr || !country) return json({ error: "unknown_country" }, { status: 404 });

  const { data: route, error: rErr } = await sb
    .from("routes")
    .select("retail_credits, status, last_cost_cents, fivesim_cost_cents, pool_operator, pool_rate_pct, herosms_cost_cents, herosms_physical_count, herosms_real_operator, herosms_real_operators, real_sim_only, provider, smspool_pool, smspva_operator, smspva_operator_cents, premium_credits")
    .eq("service_id", service.id)
    .eq("country_id", country.id)
    .maybeSingle();
  if (rErr) return json({ error: "route_lookup_failed", detail: rErr.message }, { status: 500 });
  if (!route || route.status !== "active" || route.retail_credits == null) {
    return json({ error: "route_unavailable" }, { status: 409 });
  }
  // Premium = "pin a NAMED carrier", and each provider names one differently:
  // SMSPVA via sync-smspva-operators (`smspva_operator`), HeroSMS via the
  // per-country operator probe (`herosms_real_operator`). Either way the route
  // must carry a `premium_credits` price, which is what the checkout chips key
  // off — selling a tier the client cannot price is a dead end.
  //
  // HeroSMS used to be refused outright here because there was no pin to apply;
  // there is now, so the refusal is gone. It remains a HARD refusal when the
  // route has no carrier: downgrading silently would charge the 20% uplift and
  // reserve exactly the standard fill.
  const premiumPin = route.provider === "smspva"
    ? (route.smspva_operator as string | null)
    : route.provider === "herosms"
      ? (route.herosms_real_operator as string | null)
      : null;
  if (tier === "premium" && (premiumPin == null || route.premium_credits == null)) {
    return json({ error: "premium_unavailable" }, { status: 409 });
  }

  // The mirror case: services that reject VoIP are sold ONLY as Real SIM. A
  // standard fill on such a route would knowingly hand back a number the
  // service refuses.
  //
  // This used to be a hard 409 `real_sim_required`, and that was a dead end for
  // every shipped client: build 18 has no `real_sim_only` in its Route model,
  // so it renders the Standard chip, preselects it, and then cannot interpret
  // the error code — the user just saw "Not available right now. Try a
  // different option." Working around it by HIDING those routes
  // (`real_sim_only_sellable = false`) was worse still: measured 2026-07-31,
  // it removed 145 routes across facebook/instagram/whatsapp — 45% of all
  // order volume — and HeroSMS's own deliverability data then showed the hidden
  // set was specifically the BEST inventory: all nine of facebook's top-ten
  // countries (US 43.4%, Portugal 42.0%, Germany 35.7% …), leaving one
  // bookable route, Costa Rica, which the vendor does not rank at all.
  //
  // So serve it instead: pin the real carrier STRICTLY and charge the STANDARD
  // price. That is premium behaviour at the standard price, which costs us the
  // 20% uplift on routes running 56-153x margin — nothing, against losing the
  // order outright. `realSimForced` carries the decision to the pin below;
  // there is no client change and no new error code, so it works on the
  // released build today.
  const realSimForced = tier !== "premium" && route.real_sim_only === true;
  if (realSimForced && premiumPin == null) {
    // The genuinely unsellable case, and the only one left: a VoIP-rejecting
    // service with no real carrier to pin. Refusing beats reserving a number
    // the service is certain to reject.
    return json({ error: "real_sim_required" }, { status: 409 });
  }

  // Idempotency backstop against a double-submit (fast double-tap, a retry, or
  // two devices): if the user already has a live 'waiting' order for this exact
  // service+country from the last few seconds, return it instead of charging +
  // reserving a second number. The client also guards this on the main actor;
  // this makes the server safe even if that guard is bypassed. A short window
  // (not a blanket rule) so a deliberate repeat order later still works.
  // Dedupe + charge now happen together in begin_order (one transaction, an
  // advisory lock per user). The old version SELECTed here and INSERTed ~200
  // lines later, with a multi-second provider call in between — two concurrent
  // requests both passed this check and both charged.
  const cost = tier === "premium"
    ? route.premium_credits as number
    : route.retail_credits as number;
  const codes: RouteCodes = {
    // The route's own provider column decides which arm of the router runs, so
    // routing can never disagree with the pricing. See RouteCodes.owner.
    owner: route.provider as string | null,
    fiveProduct: service.fivesim_product,
    fiveCountry: country.fivesim_country,
    heroService: service.herosms_code,
    heroCountry: country.herosms_id,
    smsService: service.smspva_code,
    smsCountry: country.smspva_code,
    dial: country.dial_code,
  };

  // ── Retry steering context. A retry is the one moment we KNOW the previous
  // number/pool failed this user — use that knowledge instead of re-selling it.
  // Measured 2026-07-24: one user's 9 Betano attempts drew only 6 distinct
  // numbers, every attempt pinned to the same carrier. Best-effort: on any
  // error both sets stay empty and behavior is exactly today's.
  const recentNumbers = new Set<string>();
  const triedOperators = new Set<string>();
  // Attempts on THIS route that never even reserved a number, and how long ago
  // the most recent one was. See the brake below — gathered here to avoid a
  // second round-trip on the order path.
  let recentNumberless = 0;
  let sinceLastNumberlessMs = Number.POSITIVE_INFINITY;
  try {
    const { data: recent } = await sb
      .from("orders")
      .select("smspva_number, smspool_pool, country_id, provider, status, closed_at, created_at")
      .eq("user_id", userId)
      .eq("service_id", service.id)
      .gte("created_at", new Date(Date.now() - 60 * 60 * 1000).toISOString());
    for (const r of recent ?? []) {
      if (r.smspva_number) recentNumbers.add(r.smspva_number as string);
      if (
        r.smspva_number == null && r.country_id === country.id && r.created_at
      ) {
        const age = Date.now() - new Date(r.created_at as string).getTime();
        if (age <= FAIL_BREAKER_WINDOW_MS) {
          recentNumberless++;
          if (age < sinceLastNumberlessMs) sinceLastNumberlessMs = age;
        }
      }
      if (
        // 'expired' counts too: an order that held the full window with no SMS
        // is the STRONGEST evidence that carrier is dead, and rotation was
        // ignoring it entirely — only user-cancels populated this set.
        r.provider === "smspva" && r.smspool_pool &&
        (r.status === "canceled" || r.status === "expired") &&
        r.country_id === country.id && r.closed_at &&
        Date.now() - new Date(r.closed_at as string).getTime() <= 15 * 60 * 1000
      ) triedOperators.add(r.smspool_pool as string);
    }
  } catch (e) {
    console.warn("retry-context read failed (ignored):", e);
  }

  // ── Stop a user burning their session on a route that will not serve them ──
  //
  // An order that never reserves a number is charged and instantly refunded, so
  // nothing stopped a user firing them as fast as they could tap. Measured
  // 2026-08-01: one user placed SEVEN orders on apple-music/tr in 24 SECONDS
  // and fourteen in eleven minutes, every one a charge-and-refund, and left
  // without a single code — having bought 12 credits ninety seconds earlier.
  // Two separate bugs caused those particular failures, but the absence of any
  // brake is what turned each one into a dozen bad experiences instead of one.
  //
  // A COOLDOWN, not a circuit breaker, and that distinction came from replaying
  // this against the real orders. A hard "3 strikes and the route is closed for
  // 10 minutes" would have blocked 10 attempts in that window — but TWO of them
  // (21:37:04 and 21:43:15, leboncoin/my) actually SUCCEEDED. The route had
  // recovered and a breaker would have refused a working order and told the user
  // to go elsewhere. So after 3 numberless attempts we only require breathing
  // room between tries: the 24-second storm collapses to one attempt, while the
  // patient retry six minutes later still goes through.
  //
  // Only NUMBERLESS attempts count. An order that held a number and expired or
  // was cancelled is a different event — the route worked, delivery did not —
  // and the retry steering above already handles that case.
  //
  // Fails OPEN: if the read above threw, the counter is 0 and behaviour is
  // exactly as before. A brake that trips on its own DB blip would refuse orders
  // the product could have served, which is worse than what it prevents.
  //
  // Reuses `no_numbers_available` deliberately rather than inventing a code:
  // it is true (we could not get one, three times running), every shipped build
  // already maps it, and its copy — "No numbers available for this combination
  // right now. Try another country or service." — is the exact steer we want.
  // A new code would render as a generic failure until an App Store release.
  if (
    recentNumberless >= FAIL_BREAKER_THRESHOLD &&
    sinceLastNumberlessMs < FAIL_BREAKER_COOLDOWN_MS
  ) {
    console.warn(`fail_cooldown user=${userId} svc=${service.id} cty=${country.id} numberless=${recentNumberless} since_last_ms=${Math.round(sinceLastNumberlessMs)}`);
    return json({ error: "no_numbers_available" }, { status: 503 });
  }

  // ONE provider, no fallback (owner decision 2026-07-30). `route.provider`
  // only reflects the display-price source, not the fulfilment preference —
  // providerOrder() is the single routing truth and reads only the codes.
  const providers = providerOrder(codes);
  if (providers.length === 0) return json({ error: "route_unavailable" }, { status: 409 });

  // The most we can pay and still keep MIN_MARGIN on what we charged. Passed
  // to the provider as a purchase-time cap AND enforced on the actual charged
  // cost — the live quote is per cheapest pool and does not bind the fill
  // price (seen live: wechat/kg quoted 6¢, uncapped purchase filled at 79¢).
  //
  // + CEILING_HEADROOM_USD, because without it this ceiling has ZERO tolerance
  // on most of the catalog. sync-prices sets retail = ceil(cost / 0.05) and
  // this computes cost * 0.05, so whenever wholesale lands on an exact 5¢
  // boundary the cap equals the cost to the cent — measured 2026-07-27:
  // 12,507 of 16,303 active routes (76.7%) sat at exactly zero headroom. A
  // one-cent rise at SMSPVA then made `liveCost > maxCostUsd` true and every
  // order on that route was refused with margin_too_low, charged, and instantly
  // refunded until the next hourly sync-prices repriced it. That is what
  // produced 11 of 22 orders in 24h closing in <1s with no number, and it also
  // fed the auto-hide (see 20260727120000) which removed TikTok/Netherlands
  // from the catalog on 8 orders that never got a number.
  //
  // Resolved from the route's OWN provider, because the two are priced at
  // different divisors — see MIN_MARGIN_BY_PROVIDER. `route.provider` is the
  // right source: providerOrder() returns exactly one provider per service and
  // there is no cross-provider fallback, so the row we priced is the row we buy.
  //
  // Computed BEFORE the charge (not in the reservation loop) because the
  // pre-charge balance guard below needs it.
  const minMargin = marginFor(route.provider as string | null);
  // What we EXPECTED to pay, i.e. the divisor the route was priced with.
  const expectedCostUsd = (cost * NET_USD_PER_CREDIT) / minMargin;
  // What we are WILLING to pay. Deliberately much higher — see the block above
  // CEILING_SLACK_MULTIPLE for why, and note it is a cap, not a price: a normal
  // order still fills from the cheapest pool and still earns the full margin.
  const maxCostUsd = Math.min(
    expectedCostUsd * CEILING_SLACK_MULTIPLE + CEILING_HEADROOM_USD,
    cost * NET_USD_PER_CREDIT * MAX_REVENUE_FRACTION,
  );

  // Pre-charge balance guard, and it FAILS OPEN. Every product line used to
  // charge → attempt reservation → refund, so a dry provider balance turned
  // every order into a guaranteed charge-and-refund — and each one fed the
  // fail-cooldown machinery as if it were a stockout. poll-active-orders
  // already writes {balance_usd, checked_at} into app_config every 60s; refuse
  // BEFORE charging only when that reading is fresh and provably too small for
  // this order's own ceiling. A stale or missing reading proceeds as before —
  // a guard that trips on its own DB blip refuses orders the product could
  // have served, which is worse than what it prevents. `provider_unreachable`
  // is already mapped in every shipped build, and out-of-balance IS the
  // provider being unable to serve.
  try {
    const healthKey = `${providers[0]}_health`;
    const { data: h } = await sb
      .from("app_config").select("value").eq("key", healthKey).maybeSingle();
    const health = h?.value as { balance_usd?: number; checked_at?: string } | null;
    const fresh = !!health?.checked_at &&
      Date.now() - new Date(health.checked_at).getTime() < 5 * 60 * 1000;
    if (fresh && typeof health?.balance_usd === "number" && health.balance_usd < maxCostUsd) {
      console.error(
        `create-order: pre-charge refusal — ${healthKey} $${health.balance_usd} ` +
          `below order ceiling $${maxCostUsd.toFixed(2)} (svc=${service.id} cty=${country.id})`,
      );
      // Page the owner. Until this existed the refusal was console.error only,
      // so "nobody can buy the expensive half of the catalog" was invisible
      // unless someone read the logs. Awaited, matching the other two alerts:
      // this path is terminal, and the helper never throws.
      await alertLowBalanceBlock(
        sb, providers[0], health.balance_usd, maxCostUsd,
        `${service.id}/${country.id} · ${cost} cr`,
      );
      return json({ error: "provider_unreachable" }, { status: 503 });
    }
  } catch { /* fail open */ }

  // Write the order row AND charge, atomically. Every paid attempt now has a
  // row from this point on, so a failure below is recorded instead of vanishing
  // — 51% of all charge attempts previously left no trace, which is why the
  // real failure rate was never measurable.
  const { data: begun, error: beginErr } = await sb.rpc("begin_order", {
    p_user: userId,
    p_service: service.id,
    p_country: country.id,
    p_credits: cost,
    p_tier: tier,
    p_dedupe_seconds: body.allow_concurrent
      ? DEDUPE_CONCURRENT_SECONDS
      : DEDUPE_DEFAULT_SECONDS,
  });
  if (beginErr) {
    return json({ error: "spend_failed", detail: beginErr.message }, { status: 500 });
  }

  const begunStatus = (begun as { status?: string } | null)?.status;
  const orderId = (begun as { order_id?: string } | null)?.order_id;

  if (begunStatus === "insufficient_credits") {
    return json({ error: "insufficient_credits", needed: cost }, { status: 402 });
  }
  if (begunStatus === "duplicate" && orderId) {
    const { data: dupe } = await sb.from("orders").select("*").eq("id", orderId).single();
    return json({ order: dupe, deduped: true });
  }
  if (begunStatus !== "ok" || !orderId) {
    return json({ error: "spend_failed", detail: String(begunStatus) }, { status: 500 });
  }

  /** Close the reserved row and return the credits. Linked to the order, so the
   *  ledger reconciles and the attempt stays visible as a closed order rather
   *  than disappearing. */
  const failOrder = async (reason: string) => {
    // CLAIM-GATED. This refund used to be unconditional, which minted credits:
    // begin_order commits the `waiting` row and charges BEFORE the provider
    // loop runs, and that row is readable over PostgREST immediately. A user
    // could cancel-order it mid-loop (refund #1), then this function would lose
    // the flip and refund again (#2) — repeatable, +cost credits per round.
    // The `order_persist_failed` path was worse than a race: reaching it MEANS
    // something else already flipped the row, and every such path refunds.
    // Every other terminal writer (cancel-order, poll-active-orders,
    // check-order) already gates on the row count; this was the only hole.
    const { data: claimed, error: cErr } = await sb
      .from("orders")
      .update({ status: "canceled", closed_at: new Date().toISOString() })
      .eq("id", orderId)
      .eq("status", "waiting")
      .select("id");
    if (cErr) {
      console.error("failOrder: could not close order", orderId, cErr);
      return;
    }
    if (!claimed || claimed.length === 0) {
      // Someone else already closed and refunded this order. Refunding here
      // would be a second credit for one charge.
      console.warn(`failOrder: lost the claim for ${orderId} (reason=${reason}) — refund already issued elsewhere, skipping`);
      return;
    }
    // supabase-js RETURNS errors, it does not throw, and wallet_credit RAISES
    // on a missing wallet row or non-positive amount. This is the busiest
    // failure path in the order flow (margin_too_low, stockout and provider
    // faults all land here) — discarding the error left the order terminal,
    // the user charged, and the console.warn below looking identical to a
    // clean refund. Mirrors the guard cancel-order already had.
    const { error: refundErr } = await sb.rpc("wallet_credit", {
      p_user: userId, p_amount: cost, p_reason: "refund", p_order: orderId,
    });
    if (refundErr) {
      // Roll back to 'waiting' so the expiry sweep closes and refunds it a
      // minute later — every recovery path requires status='waiting', so
      // leaving it terminal makes the charge PERMANENTLY unrefundable.
      // `wallet_transactions_refund_once_idx` makes the retry safe.
      console.error(`create-order: REFUND FAILED order=${orderId} user=${userId} ` +
                    `credits=${cost}: ${refundErr.message} — reverting to waiting`);
      await sb.from("orders")
        .update({ status: "waiting", closed_at: null })
        .eq("id", orderId).eq("status", "canceled");
      return;
    }
    console.warn(`create-order failed svc=${service.id} cty=${country.id} reason=${reason} order=${orderId}`);
  };

  // Try providers in preference order; on each, verify margin against the live
  // price, then reserve. Skip (fall back) on margin failure or a reserve error.
  let reservation = null as Awaited<ReturnType<typeof reserve>> | null;
  let used: (typeof providers)[number] | null = null;
  let usedCostUsd: number | null = null;
  /** What the order is finally CHARGED and what tier it records. They start at
   *  the tier the client asked for and move together only when a premium order
   *  takes a standard fill — see the downgrade block in the provider loop.
   *  `cost` stays the amount `begin_order` actually debited, so the difference
   *  is what has to be returned. */
  let chargedCredits = cost;
  let effectiveTier = tier;
  let lastError = "no_numbers_available";
  /** Why the last reservation attempt failed, in enough detail to tell a real
   *  stockout from a price refusal WITHOUT reading the function logs.
   *
   *  Every numberless order is a charge-and-refund, and today the only record
   *  of the cause is a console line in a dashboard nobody reads at 3am — the
   *  order row keeps `actual_cost_cents` null and carries no error at all. So
   *  "4 never got a number" in the 6h digest is unanswerable after the fact,
   *  which is exactly the position this session started from. */
  let lastDiag: Record<string, unknown> | null = null;

  // ── Real-SIM carrier ─────────────────────────────────────────────────────
  //
  // `routes.herosms_real_operator` is the named carrier with the most stock for
  // this route, resolved per country by `sync-herosms`. It replaced an earlier
  // `app_config.force_physical_operator` that pinned the single operator
  // `physic` for the whole of the US — which turned out to be one narrow pool,
  // empty for services holding thousands of real numbers elsewhere (badoo/us:
  // physic 0, verizon 14,224, textnow 458,985).
  //
  // Premium pins the route's named carrier STRICTLY (a dry carrier fails and
  // refunds). Standard pins it OPPORTUNISTICALLY — same as the SMSPVA arm
  // below — so a dry carrier, or one over the ceiling, falls back to the
  // general pool instead of losing the sale.
  //
  // Standard must NOT be left unpinned. The tier chips that let a user choose
  // are in the 1.5 archive still awaiting review, and `defaultPremium` is in
  // build 19 — so every order a real user places today is `standard`. Leaving
  // it unpinned put US orders straight back onto a pool that is ~99.97% VoIP
  // (`textnow` alone is 458,985 of ~477,000 numbers), which took 175 of 198
  // credits charged for ZERO codes in the 12h before this was first fixed.
  // Opportunistic pinning costs nothing: the worst case is the old behaviour.
  // EVERY real carrier with stock, comma-joined, not just the best one.
  // getNumberV2's `operator` param takes a list ("tele2,beeline" per the spec),
  // so this draws on the union of real-SIM stock instead of one carrier's.
  //
  // Why it matters: the pin here is OPPORTUNISTIC — a dry carrier falls back to
  // the unpinned pool, which is overwhelmingly VoIP (badoo/us: verizon 14,224
  // real numbers against textnow's 458,985, ~96% of the country on one VoIP
  // operator). So the old single pin quietly degraded to the exact stock strict
  // services reject, every time that one carrier ran dry. Naming them all makes
  // that fallback far rarer without making it strict, i.e. without trading
  // availability for quality.
  //
  // Falls back to the single carrier for routes probed before the list column
  // existed, so behaviour is never worse than before while the hourly cursor
  // (8 countries/run) fills it in.
  const heroCarrier = (route.herosms_real_operators as string | null) ??
    (route.herosms_real_operator as string | null);

  // Standard orders pin the route's real-SIM carrier too, whenever it fits
  // the margin ceiling. Probed 2026-07-21: on all 16,320 active routes the
  // carrier costs the same or LESS than a random fill — random just means
  // "probably a Donor* pool", the stock strict services reject. reserve()
  // falls back to a random fill if the carrier is dry (premium doesn't).
  const standardCarrier =
    route.smspva_operator != null && route.smspva_operator_cents != null &&
      (route.smspva_operator_cents as number) / 100 <= maxCostUsd
      ? route.smspva_operator as string
      : null;

  // ── Operator rotation. If the pin we'd use is one this user just failed
  // on, pick a different real carrier from the live per-operator price map
  // (getCountryPrices → po). The alternate must be untried, non-Donor (the
  // anonymized VoIP pools strict services reject), and inside the same
  // margin ceiling as any other fill. Fallbacks: standard → unpinned (at
  // least a different pool than the one that just failed), premium → keep
  // the route pin (the buyer paid for THAT real-SIM pool; never downgrade).
  let smspvaPin: string | null = tier === "premium"
    ? route.smspva_operator as string
    : standardCarrier;
  let rotatedPinUsd: number | null = null;
  if (
    smspvaPin != null && triedOperators.has(smspvaPin) &&
    country.smspva_code && service.smspva_code
  ) {
    try {
      const pr = await getCountryPrices(country.smspva_code as string);
      const row = isOk(pr)
        ? pr.data.find((x) => x.s === service.smspva_code)
        : null;
      const alt = Object.entries(row?.po ?? {})
        .map(([op, usd]) => ({ op, usd: parseFloat(usd) }))
        .filter(({ op, usd }) =>
          !triedOperators.has(op) &&
          !op.toLowerCase().startsWith("donor") &&
          Number.isFinite(usd) && usd <= maxCostUsd)
        .sort((a, b) => a.usd - b.usd)[0] ?? null;
      if (alt) {
        console.warn(`operator rotation: ${smspvaPin} already failed this user — pinning ${alt.op} svc=${service.id} cty=${country.id}`);
        smspvaPin = alt.op;
        rotatedPinUsd = alt.usd;
      } else if (tier !== "premium") {
        console.warn(`operator rotation: ${smspvaPin} already failed this user, no eligible alternate — unpinned svc=${service.id} cty=${country.id}`);
        smspvaPin = null;
      }
    } catch (e) {
      console.warn("operator rotation lookup failed (ignored):", e);
    }
  }

  for (const p of providers) {
    // Premium margins are checked against the pinned operator's own price —
    // livePriceUsd returns the country/service BASE price, usually the
    // cheapest pool, which can sit well under the carrier we actually buy from
    // (whatsapp/UK: base 1.40, Giffgaff 6.00). But smspva_operator_cents is a
    // DAILY-cached column (sync-smspva-operators cursor): if SMSPVA raised
    // prices since the last pass it is stale-LOW, and checking margin against
    // it alone would sell under floor for up to ~24h. So take the HIGHER of
    // the cached operator price and the live base price — a broad live price
    // rise is caught immediately, the carrier premium is still respected.
    let liveCost: number | null;
    // The pinned-carrier floor belongs to the provider that HAS that carrier.
    // `smspva_operator_cents` is SMSPVA's price for SMSPVA's operator, written
    // only by sync-smspva-operators. Applying it to any other provider prices
    // a purchase we are not making.
    //
    // This was `p === "smspva" ? ... : null`, which under-checked non-SMSPVA
    // premium. Making it provider-GENERIC over-corrected and took the product
    // down: on a HeroSMS route the gate became max(SMSPVA carrier price, live
    // HeroSMS price), and SMSPVA's carrier is far dearer — leboncoin/my is
    // $3.00 at SMSPVA against $0.02 at HeroSMS, versus a $0.15 ceiling. So
    // EVERY Real SIM order on 3,064 of 4,080 priced HeroSMS routes (75%) was
    // refused margin_too_low, charged and instantly refunded. Measured
    // 2026-08-02 after users reported not getting numbers.
    //
    // Scoped, not reverted: SMSPVA still gets its carrier floor (the bug the
    // generic version was written for), and HeroSMS is checked against its own
    // live price. HeroSMS exposes no per-operator PRICE — getNumbersStatus
    // returns per-operator STOCK only — so there is no carrier floor to apply.
    // The pin is still enforced strictly at reserve(), and the actual charged
    // cost is re-checked against maxCostUsd below, so a dearer real fill is
    // caught there rather than being sold under floor.
    const carrierFloorUsd = p === "smspva"
      ? (rotatedPinUsd ??
        (route.smspva_operator_cents != null
          ? (route.smspva_operator_cents as number) / 100
          : null))
      : null;
    // ── HeroSMS: the SYNCED cost is the accurate one, the live quote is not.
    //
    // `livePriceUsd` resolves HeroSMS through `getPrices`, whose `cost` is the
    // DEFAULT advertised price — and that number is wrong in both directions.
    // Measured over 1,554 (service,country) pairs on 2026-08-02: 1,107 (71%)
    // had stock CHEAPER than it and 60 (4%) had NO stock at all at that price.
    // That is precisely why `sync-herosms` was moved onto
    // /api/v1/activations/offers the same day, taking the cheapest key in the
    // price→stock map WITH a non-zero count and storing it in
    // `herosms_cost_cents`.
    //
    // The order path was left behind. So the gate below compared an inflated
    // phantom price against a ceiling derived from the accurate one, and
    // refused `margin_too_low` on routes with plenty of buyable stock under
    // our cap — charged and instantly refunded, permanently, until the price
    // moved. Same failure that cost a paying customer eight straight attempts
    // on apple/Turkey.
    //
    // Preferring the cached value cannot overpay: `maxPriceUsd` is enforced
    // provider-side by getNumberV2 and the ACTUAL charged cost is re-checked
    // against the ceiling after the fill. If the price rose since the hourly
    // sync, the provider refuses with WRONG_MAX_PRICE and the retry below
    // handles it with the real number instead of a guess.
    if (p === "herosms" && route.herosms_cost_cents != null &&
        (route.herosms_cost_cents as number) > 0) {
      liveCost = (route.herosms_cost_cents as number) / 100;
    } else if (tier === "premium" && carrierFloorUsd != null) {
      const liveBase = await livePriceUsd(p, codes);
      liveCost = liveBase != null ? Math.max(carrierFloorUsd, liveBase) : carrierFloorUsd;
    } else {
      liveCost = await livePriceUsd(p, codes);
    }
    // Graceful degrade to the last SYNCED cost — but only to a cost synced for
    // THIS provider.
    //
    // `last_cost_cents` is written by sync-prices, which prices SMSPVA and
    // deliberately skips non-SMSPVA rows. So on a HeroSMS route it holds a
    // frozen SMSPVA number. Falling back to it margin-checked a HeroSMS
    // purchase against a retired provider's price, and for routes HeroSMS
    // cannot serve at all (livePriceUsd -> null) that stale cost PASSED the
    // gate — the reservation then failed NO_NUMBERS and the user was charged,
    // refunded, and told to "try another country or service". ~16% of HeroSMS
    // routes were in that state.
    //
    // A HeroSMS route with no HeroSMS cost is now correctly unavailable rather
    // than sellable-then-broken. sync-herosms hides those routes; this is the
    // belt to that braces, for the window before it next runs.
    const cachedCents = p === "5sim"
      ? (route.fivesim_cost_cents as number | null)
      : p === "herosms"
      ? (route.herosms_cost_cents as number | null)
      : (route.last_cost_cents as number | null);
    if (liveCost == null && cachedCents != null && cachedCents > 0) {
      liveCost = cachedCents / 100;
    }
    if (liveCost == null) { lastError = "route_unavailable"; continue; }
    // Pre-flight refusal bound. For HeroSMS this is the INVARIANT (half of
    // revenue), not the policy ceiling — because HeroSMS enforces the cap we
    // pass server-side, so there is no exposure in asking. We still pass
    // `maxCostUsd` on the first reservation, so a normal order fills from the
    // cheapest stock and earns the full margin; only if the provider itself
    // answers WRONG_MAX_PRICE do we escalate, and only to the figure IT names.
    //
    // Refusing here at `maxCostUsd` instead would skip reserve() entirely and
    // with it that recovery — throwing the order away on the strength of an
    // hourly price snapshot, when the provider was about to tell us the real
    // number. That is a charge-and-refund on a route we can profitably serve.
    //
    // SMSPVA keeps the tighter bound: it accepts no price cap and reports no
    // cost, so an over-ceiling fill can only be discovered after the purchase
    // and undone by release() — churn worth avoiding.
    // 5sim takes NO price cap, so like SMSPVA it gets the TIGHT bound: an
    // over-ceiling fill can only be found after the purchase and undone with
    // release(). Only HeroSMS, which enforces maxPrice server-side, earns the
    // loose one.
    const refuseAboveUsd = p === "herosms"
      ? cost * NET_USD_PER_CREDIT * MAX_REVENUE_FRACTION
      : maxCostUsd;
    if (liveCost > refuseAboveUsd) {
      console.warn(`margin_too_low provider=${p} tier=${tier} svc=${service.id} cty=${country.id} credits=${cost} liveUsd=${liveCost} bound=${refuseAboveUsd.toFixed(3)}`);
      lastError = "margin_too_low";
      lastDiag = {
        provider: p, tier, credits: cost, error_type: "PRE_FLIGHT_PRICE",
        raw: "", quoted_usd: liveCost, ceiling_usd: Number(refuseAboveUsd.toFixed(4)),
        pin: null, strict_pin: null,
      };
      continue;
    }
    // smspva rides the real-SIM carrier (mandatory for premium, opportunistic
    // for standard). smspvaPin already encodes the tier rule plus any rotation
    // away from a carrier this user just failed on.
    //
    // This used to read `p === "smspva" ? smspvaPin : route.smspool_pool`. Any
    // future provider MUST get its own explicit arm here — the old else-branch
    // silently handed an SMSPool pool name to whatever provider ran next.
    // Any future provider MUST get its own explicit arm here — the old
    // else-branch silently handed an SMSPool pool name to whatever provider
    // ran next.
    //
    // On a real_sim_only route the pin is MANDATORY, not opportunistic:
    // `standardCarrier` is gated on the cached operator cost fitting the
    // ceiling and goes null when it does not, which would leave the order
    // unpinned — i.e. filled from the VoIP pool this route exists to avoid.
    // `premiumPin` is the route's real carrier unconditionally, so force it.
    // On HeroSMS the forced-real pin takes the UNION of real carriers, not the
    // single best one. `premiumPin` is `herosms_real_operator` — one carrier,
    // the most-stocked at probe time — while `herosms_real_operators` holds
    // every real carrier the same probe found (mean 3.34 per route, max 7).
    //
    // This path is STRICT (see strictPin below), so a dry pin is a hard
    // `no_numbers_available` with no unpinned fallback — which is correct, but
    // it means naming one carrier throws away the other real stock on the same
    // route for no reason. Every member of the union was probed non-VoIP, so
    // the quality guarantee that makes this route real-SIM-only is unchanged;
    // only the amount of real stock we can reach goes up. 51 of the 105
    // real_sim_only routes priced at 1-6 credits carry more than one carrier.
    //
    // Falls back to the single carrier for rows probed before the list column
    // existed, so behaviour is never worse than before.
    const forcedRealPin = p === "herosms" ? (heroCarrier ?? premiumPin) : premiumPin;
    const pin = realSimForced ? forcedRealPin
              : p === "smspva" ? smspvaPin
              : p === "5sim" ? (route.pool_operator as string | null)
              : p === "herosms" ? heroCarrier
              : null;
    // Strict when the buyer paid for a specific real-SIM pool (premium), and
    // strict when policy forces one — both mean "this pool or nothing".
    //
    // realSimForced MUST be strict. A non-strict pin falls back to a random
    // fill when the carrier is dry, and on a VoIP-rejecting service that fill
    // is the exact number the service will refuse: we would charge for a
    // number that cannot work, which is worse than failing as a stockout.
    // Everything else keeps the old rule — premium is strict because that
    // buyer paid for THAT pool, standard may fall back, which is what makes
    // the opportunistic pin free.
    const strictPin = tier === "premium" || realSimForced;
    // Fresh-number guarantee: SMSPVA re-issues a just-canceled number to the
    // same buyer. If the fill matches a number this user already drew for
    // this service in the last hour, release it and draw again — at most 3
    // draws. A still-duplicate final draw is kept: a repeat number beats no
    // number. release() never throws (logged internally), and only a
    // SUCCESSFUL duplicate fill re-enters the loop — reserve errors take the
    // existing error path unchanged.
    // The ceiling actually passed to the provider. Starts at maxCostUsd and is
    // raised at most once, to a figure the PROVIDER named, never above the
    // no-loss invariant. Tracked separately so the post-fill check below
    // compares against the cap we really authorised.
    let ceilingUsd = maxCostUsd;
    // The pin/strictness that produced the CURRENT `res`. They change if the
    // premium downgrade below fires, and the duplicate-number redraw must
    // re-issue the same kind of request rather than silently re-pinning
    // strictly on a fill we already decided to take unpinned.
    let effPin: string | null = pin;
    let effStrict = strictPin;
    let res = await reserve(p, codes, ceilingUsd, effPin, effStrict);

    // ── WRONG_MAX_PRICE tells us the price that WOULD have worked. Use it.
    //
    // HeroSMS answers an unfillable cap with `WRONG_MAX_PRICE:0.35` — the
    // suffix is the minimum it will sell at right now. We classified that as
    // PRICE_NOT_FOUND → margin_too_low and threw the number away, so a route
    // whose stock had moved a couple of cents above a stale ceiling was a
    // charge-and-refund every single time until the next hourly sync. The
    // apple/Turkey case was 1.8 CENTS short and burned eight consecutive
    // attempts by a paying customer.
    //
    // Retry exactly once, and only up to `MAX_REVENUE_FRACTION` of what we
    // charged — the invariant that guarantees no order is ever sold at a loss
    // (see the constant). When maxCostUsd is already at that cap there is no
    // room and we correctly decline: that route is mispriced and needs
    // repricing, not a looser gate. Both outcomes are logged so the split
    // between "recovered" and "genuinely too dear" is measurable.
    if (!res.ok && res.errorType === "PRICE_NOT_FOUND") {
      const askUsd = wrongMaxPriceUsd(res.error);
      const hardCapUsd = cost * NET_USD_PER_CREDIT * MAX_REVENUE_FRACTION;
      if (askUsd != null && askUsd > ceilingUsd && askUsd <= hardCapUsd + 1e-9) {
        console.warn(
          `price_retry provider=${p} svc=${service.id} cty=${country.id} ` +
            `askUsd=${askUsd} ceiling=${ceilingUsd.toFixed(3)} invariant=${hardCapUsd.toFixed(3)}`,
        );
        ceilingUsd = askUsd;
        res = await reserve(p, codes, ceilingUsd, pin, strictPin);
      } else if (askUsd != null) {
        console.warn(
          `price_retry_declined provider=${p} svc=${service.id} cty=${country.id} ` +
            `credits=${cost} askUsd=${askUsd} invariant=${hardCapUsd.toFixed(3)} — route is mispriced`,
        );
      }
    }

    // ── Premium falls back to a STANDARD fill, at the STANDARD price.
    //
    // A premium order pins the real carriers STRICTLY, and strict means
    // reserve() does not retry unpinned. So whenever the real pool is
    // momentarily dry the user gets NO NUMBER AT ALL and is told to try
    // another country — while the identical standard order fills seconds
    // later from the same catalog. Measured 2026-08-03: subito/uk premium
    // returned NO_NUMBERS at 04:32:21 and subito/uk standard filled on
    // `lebara` at 04:32:24, three seconds later, with `lebara` in the very
    // list the premium call had pinned. Six of the eight recent HeroSMS
    // numberless orders were this, all on routes that do not reject VoIP.
    //
    // This is NOT the silent downgrade that was rejected on 2026-07-21. That
    // objection was to charging the 20% real-SIM uplift and quietly handing
    // back standard stock. Here the order is REPRICED to `retail_credits`,
    // the difference is returned, and the row records `tier: standard` — so
    // the user pays for exactly what they received and the history is honest.
    //
    // Hard boundary: `real_sim_only` routes never take this path. There a VoIP
    // number is one the service is certain to reject, so failing as a stockout
    // is the correct outcome and a cheaper number is worth nothing.
    if (
      !res.ok && res.errorType === "OUT_OF_STOCK" &&
      tier === "premium" && route.real_sim_only !== true &&
      route.retail_credits != null && (route.retail_credits as number) < cost
    ) {
      const stdCredits = route.retail_credits as number;
      // Re-derive the ceiling from the STANDARD price, so the margin rule is
      // the one that belongs to the price we are about to charge. Same
      // expression as maxCostUsd — the invariant still bounds it at half of
      // revenue, so a downgraded order can no more be sold at a loss than a
      // normal one.
      const stdCeiling = Math.min(
        (stdCredits * NET_USD_PER_CREDIT / minMargin) * CEILING_SLACK_MULTIPLE +
          CEILING_HEADROOM_USD,
        stdCredits * NET_USD_PER_CREDIT * MAX_REVENUE_FRACTION,
      );
      // Unpinned deliberately: the strict call above just proved the named
      // carriers are dry, so re-offering them would only spend another round
      // trip inside the order path to be told the same thing.
      const alt = await reserve(p, codes, stdCeiling, null, false);
      if (alt.ok) {
        console.warn(
          `premium_downgraded_to_standard provider=${p} svc=${service.id} cty=${country.id} ` +
            `credits=${cost}->${stdCredits} ceiling=${stdCeiling.toFixed(3)}`,
        );
        res = alt;
        ceilingUsd = stdCeiling;
        effPin = null;
        effStrict = false;
        chargedCredits = stdCredits;
        effectiveTier = "standard";
      }
    }

    for (
      let redraw = 0;
      redraw < 2 && res.ok && res.number && recentNumbers.has(res.number);
      redraw++
    ) {
      console.warn(`duplicate number re-issued (${res.number}) — redrawing svc=${service.id} cty=${country.id}`);
      // markDead, not release. A plain cancelorder leaves the request id alive
      // at SMSPVA for ~10 minutes and the SAME number gets re-allocated — so
      // discarding a duplicate with release() fought retention using the exact
      // mechanism that causes it. Measured: 13.9% of paid orders drew a
      // re-issued number, and those delivered 21.4% against 36.8% for a first
      // issuance. markDead bans first, then cancels, so the wholesale refund is
      // still attempted.
      if (res.orderId) await markDead(p, res.orderId);
      res = await reserve(p, codes, ceilingUsd, effPin, effStrict);
    }
    if (res.ok) {
      if (res.costUsd != null && res.costUsd > ceilingUsd + 0.001) {
        console.warn(`actual_cost_over_ceiling provider=${p} svc=${service.id} cty=${country.id} credits=${cost} paidUsd=${res.costUsd} maxUsd=${ceilingUsd}`);
        if (res.orderId) await release(p, res.orderId).catch(() => {});
        lastError = "margin_too_low";
        continue;
      }
      reservation = res; used = p; usedCostUsd = res.costUsd ?? liveCost; break;
    }
    console.warn(`reserve failed provider=${p} svc=${service.id} cty=${country.id} err=${res.error}`);
    // Map the provider's documented failure types onto codes the app already
    // has copy for. Previously every one of these arrived as raw provider text
    // (SMSPool wraps them in HTML), matched nothing in APIError.userMessage,
    // and fell through to "Something went wrong on our side." — the least
    // actionable message, on the most common failure.
    lastError = res.errorType === "OUT_OF_STOCK"    ? "no_numbers_available"
              : res.errorType === "PRICE_NOT_FOUND" ? "margin_too_low"
              : res.errorType === "BALANCE_ERROR"   ? "provider_unreachable"
              : res.errorType === "RATE_LIMITED"    ? "provider_unreachable"
              : res.errorType === "AUTH_ERROR"      ? "provider_unreachable"
              // A timeout or socket failure is NOT a stockout. Without this arm
              // it fell through to no_numbers_available, telling the user to
              // "try another country" for a network problem — and worse, a
              // timeout on the BUY call may mean the number was allocated and
              // billed, so it must be visible rather than filed as scarcity.
              : res.errorType === "TRANSPORT_ERROR" ? "provider_unreachable"
              : res.error === "number_never_activated" ? "no_numbers_available"
              : "no_numbers_available";
    lastDiag = {
      provider: p,
      tier,
      credits: cost,
      error_type: res.errorType ?? null,
      raw: (res.error ?? "").slice(0, 120),
      // The two numbers that separate "nothing in stock" from "priced us out".
      quoted_usd: liveCost,
      ceiling_usd: Number(ceilingUsd.toFixed(4)),
      // A strict pin cannot fall back to the unpinned pool, so a dry carrier
      // is terminal here by design — worth recording, because it is the
      // difference between "we could have served this" and "we chose not to".
      pin,
      strict_pin: strictPin,
    };
    if (res.errorType === "TRANSPORT_ERROR") {
      console.error(`${p} TRANSPORT_ERROR — possible orphaned paid reservation: ${res.error}`);
    }
    if (res.errorType === "BALANCE_ERROR" || res.errorType === "AUTH_ERROR") {
      console.error(`${p} ${res.errorType} — orders will keep failing until fixed: ${res.error}`);
      try {
        EdgeRuntime.waitUntil(alertProviderFault(sb, p, res.errorType, res.error ?? ""));
      } catch { /* paging must never affect the order path */ }
    }
  }

  if (!reservation || !used) {
    await failOrder(lastError);
    try {
      EdgeRuntime.waitUntil(bumpFailStreak(sb, lastError, `${service.id}/${country.id} (${tier})`));
      EdgeRuntime.waitUntil(
        recordFailureSample(sb, `${service.id}/${country.id}`, lastError, lastDiag),
      );
    } catch { /* paging must never affect the order path */ }
    const status = lastError === "margin_too_low" ? 409 : 503;
    return json({ error: lastError }, { status });
  }

  // UPDATE, not insert: the row already exists (begin_order wrote it with the
  // charge). Attach the reservation to it. Guarded on status='waiting' so a
  // row the expiry sweep has already closed underneath us is not resurrected.
  const { data: rows, error: insertErr } = await sb
    .from("orders")
    .update({
      provider: used,
      // Both move only on a premium->standard downgrade. Written unconditionally
      // so the row can never claim a tier the fill did not deliver, or a price
      // the wallet was not left holding.
      tier: effectiveTier,
      cost_credits: chargedCredits,
      smspva_id: reservation.orderId,      // generic: the provider's order id
      smspva_number: reservation.number,   // generic: display number
      actual_cost_cents: usedCostUsd != null ? Math.round(usedCostUsd * 100) : null,
      smspool_pool: reservation.pool ?? null,
      // Real-SIM stock on this route at the moment we reserved. Recorded so the
      // VoIP hypothesis behind `voip_strict_services` can be TESTED rather than
      // believed — without it we would hide inventory on a plausible story and
      // never be able to tell whether it helped. Null means "not recorded",
      // never "no real SIMs".
      // The rate the route was SOLD on, and the chain we asked for. sync-5sim
      // rewrites `routes` hourly, so without these the number that drove the
      // pick — and that the picker showed the user as a colour — is gone within
      // the hour and rate720 can never be tested against real delivery.
      pool_rate_pct: route.pool_rate_pct ?? null,
      pool_pinned: (route.pool_operator as string | null) ?? null,
      route_physical_count: (route.herosms_physical_count as number | null) ?? null,
      // The carrier that ACTUALLY filled, straight from getNumberV2's
      // `activationOperator` ("any" when unpinned). This is the control arm the
      // VoIP hypothesis has never had: route_physical_count above describes the
      // ROUTE at sync time, whereas this describes the NUMBER the user got. The
      // physicalCount experiment was unfalsifiable because sync-herosms hid
      // every zero-physical route on strict services before an order could land
      // on one; per-order operator attribution sidesteps that entirely. Null
      // means not recorded — never read it as "unpinned", which is "any".
      operator_used: reservation.pool ?? null,
      // Honour the provider's own hold window when it tells us one. The DB
      // default is a flat 8 minutes, but SMSPool's window is pool-dependent
      // (their docs show 1200s) — expiring first meant refunding and
      // abandoning a number we had already paid to hold. Never EXTEND past 8
      // minutes though: every code we have ever received arrived within 337s,
      // so a longer wait only leaves the user staring at a dead number.
      //
      // Always written, not just when the provider reports a deadline: the DB
      // default stamps expires_at at INSERT, which is before the provider
      // loop runs (margin checks, an operator-rotation price lookup that can
      // block up to 10s, and up to two duplicate-number redraws). That time
      // came out of the user's live-number window even though they had no
      // number yet. Measuring from the moment the number actually exists is
      // what the 8 minutes was always meant to be.
      expires_at: new Date(Math.min(
        reservation.expiresAt != null ? reservation.expiresAt * 1000 : Number.MAX_SAFE_INTEGER,
        Date.now() + 8 * 60 * 1000,
      )).toISOString(),
    })
    .eq("id", orderId)
    .eq("status", "waiting")
    .select("*");

  const order = rows && rows.length > 0 ? rows[0] : null;

  if (order) {
    try {
      EdgeRuntime.waitUntil(resetFailStreak(sb));
    } catch { /* paging must never affect the order path */ }
  }

  if (insertErr || !order) {
    // Release the just-reserved number so we don't pay for an order we can't
    // track (and it wouldn't count against the provider's concurrent cap),
    // then close the row and refund the user.
    if (reservation.orderId) await release(used, reservation.orderId);
    await failOrder("order_persist_failed");
    return json({ error: "order_persist_failed", detail: insertErr?.message }, { status: 500 });
  }

  // Return the premium uplift on a downgraded order.
  //
  // AFTER the row is persisted, never before: the failure branch above refunds
  // the FULL `cost`, so returning part of it first would over-credit an order
  // that then failed to persist.
  //
  // Reason is `adjustment`, NOT `refund`, and that is load-bearing.
  // `wallet_transactions_refund_once_idx` is UNIQUE on (order_id) WHERE
  // reason='refund', i.e. exactly one refund row per order — it exists so a
  // retried refund cannot double-pay. Spending that slot on a partial
  // correction would make the LATER full refund (expiry, cancel, late-code
  // sweep) violate the index and raise, leaving a terminal order with the
  // user's credits kept. `adjustment` is outside the index, so the refund slot
  // stays free for the refund.
  if (chargedCredits < cost) {
    const { error: adjErr } = await sb.rpc("wallet_credit", {
      p_user: userId,
      p_amount: cost - chargedCredits,
      p_reason: "adjustment",
      p_order: orderId,
    });
    if (adjErr) {
      // The user holds a number and is overcharged by the uplift (1-2 credits).
      // Loud, not fatal: failing the order here would release a working number
      // over a rounding-sized amount. Recoverable with goodwill-credit.
      console.error(
        `create-order: DOWNGRADE REFUND FAILED order=${orderId} user=${userId} ` +
          `owed=${cost - chargedCredits} credits — ${adjErr.message}`,
      );
    }
  }

  return json({ order });
});
