// Hold a specific number for one user while they decide, and — more
// importantly — REFUSE BEFORE APPLE CHARGES if we could not deliver it.
//
// ── Why the float check lives here and nowhere else ────────────────────────
//
// Every other product line in this app charges credits, which we control and
// can refund in the same transaction. This one charges through Apple, and an
// Apple refund is the one money path we cannot drive. So the ordering is
// inverted from `create-order`: there, the guard sits immediately before OUR
// charge; here it must sit before we ever show a paywall, because after that
// the money is gone and the only remedy is a refund we have to ask Apple for.
//
// That is the whole reason the flow is reserve → paywall → provision rather
// than paywall → provision. It costs a round trip and removes an entire class
// of "charged and got nothing".
//
// ── The price is re-quoted server-side, never taken from the client ────────
//
// The client sends a city and a number. We re-search that city and require the
// number to still be in OUR results before reserving it. That proves the number
// is real and still available, and it means the cost we check the balance
// against is a figure the server produced — the same discipline as the
// order-time price ceiling, which exists because a client-supplied price is a
// client-supplied spend.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  searchNumbers, reserveNumber, getBalance, faultOf,
} from "../_shared/telnyx.ts";

/** Codes per city, ordered most-likely-to-have-stock first. Mirrors
 *  `search-line-numbers` deliberately: the two must agree on what "Toronto"
 *  means, or this function reserves from a different pool than the one the
 *  picker showed. */
const CITIES: Record<string, { country: string; codes: string[] }> = {
  toronto:   { country: "CA", codes: ["437", "647", "416", "905", "289"] },
  montreal:  { country: "CA", codes: ["438", "514"] },
  vancouver: { country: "CA", codes: ["604", "778", "236"] },
  calgary:   { country: "CA", codes: ["587", "403", "825"] },
  ottawa:    { country: "CA", codes: ["343", "613"] },
  halifax:   { country: "CA", codes: ["902", "782"] },
  winnipeg:  { country: "CA", codes: ["204", "431"] },
};

/** Headroom over the number's own first-month cost. Not a guess at future
 *  months — this only has to cover the purchase we are about to authorise. */
const BALANCE_BUFFER_CENTS = 50;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { city?: string; phone_number?: string } = {};
  try { body = await req.json(); } catch { /* handled by the guards below */ }

  const cityKey = (body.city ?? "").toLowerCase();
  const wanted = body.phone_number ?? "";
  const city = CITIES[cityKey];
  if (!city || !wanted) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  // Fails CLOSED on a read error: a flag we cannot read must not be treated as
  // "not paused". Same precedent as the eSIM pause.
  const { data: pausedRow, error: pausedErr } = await sb.from("app_config")
    .select("value").eq("key", "lines_paused").maybeSingle();
  if (pausedErr || (pausedRow?.value as boolean | null) !== false) {
    return json({ error: "lines_paused" }, { status: 409 });
  }

  // One live line per user. The partial unique index enforces this anyway, but
  // finding out at INSERT time would mean finding out after Apple charged.
  const { data: live, error: liveErr } = await sb.from("phone_lines")
    .select("id").eq("user_id", userId)
    .in("status", ["provisioning", "active", "grace", "past_due", "suspended", "releasing"])
    .maybeSingle();
  if (liveErr) return json({ error: "lookup_failed" }, { status: 500 });
  if (live) return json({ error: "line_exists" }, { status: 409 });

  // Re-quote server-side. Walk the same codes in the same order and take the
  // first page that has stock, then require the requested number to be in it.
  let quoted: Awaited<ReturnType<typeof searchNumbers>> = [];
  for (const code of city.codes) {
    const r = await searchNumbers({ country: city.country, areaCode: code, limit: 8 });
    if (faultOf(r)) {
      if (r.type === "AUTH_ERROR" || r.type === "RATE_LIMITED") {
        return json({ error: "provider_unreachable" }, { status: 502 });
      }
      continue;
    }
    if (r.length > 0) { quoted = r; break; }
  }
  if (faultOf(quoted)) return json({ error: "provider_unreachable" }, { status: 502 });

  const offer = quoted.find((n) => n.phoneNumber === wanted);
  // Gone between the picker and the tap. Ordinary, and the client re-searches
  // rather than treating it as an error — it must never provision a number
  // other than the one on screen.
  if (!offer) return json({ error: "number_taken" }, { status: 409 });

  // ── The float guard ──────────────────────────────────────────────────────
  // Fails CLOSED, unlike `create-order`'s balance guard which fails OPEN on a
  // stale reading. The asymmetry is deliberate: there, a wrong refusal costs a
  // credit sale we can retry; here, a wrong ALLOW means Apple charges $9.99 for
  // a number we cannot buy.
  const needCents = offer.upfrontCents + offer.monthlyCents + BALANCE_BUFFER_CENTS;
  const bal = await getBalance();
  if (faultOf(bal)) return json({ error: "provider_unreachable" }, { status: 502 });
  if (Math.round(bal.usd * 100) < needCents) {
    console.error(JSON.stringify({
      alert: "line_float_exhausted",
      balance_usd: bal.usd,
      need_cents: needCents,
      number: wanted,
    }));
    return json({ error: "line_unavailable" }, { status: 409 });
  }

  // ── The hold ─────────────────────────────────────────────────────────────
  // Never probed live (see `reserveNumber`). Snapshot the balance either side
  // of the first call so ONE real invocation settles whether a hold costs
  // anything, rather than us assuming it is free the way `regulatory_
  // requirements: null` was assumed to mean "no paperwork" — a $3.83 lesson.
  const before = bal.usd;
  const held = await reserveNumber(wanted, `vsms-${userId}`);
  let heldUntil: string | null = null;
  let reservationId: string | null = null;

  if (faultOf(held)) {
    // ORDINARY. The client renders a number with no hold as "Available now"
    // and the purchase still works — a reservation is a nicety, not a
    // prerequisite. Recorded so a permanently-failing endpoint is visible
    // rather than silently degrading forever.
    console.log(JSON.stringify({ reserve_fault: held.type, detail: held.detail }));
  } else {
    heldUntil = held.expiresAt;
    reservationId = held.reservationId;
    const after = await getBalance();
    if (!faultOf(after)) {
      const deltaCents = Math.round((before - after.usd) * 100);
      await sb.from("app_config").upsert({
        key: "telnyx_reservation_cost",
        value: {
          delta_cents: deltaCents,
          measured_at: new Date().toISOString(),
          note: deltaCents === 0
            ? "reservations are FREE — measured, not assumed"
            : "reservations COST money — check before holding at scale",
        },
      }, { onConflict: "key" });
    }
  }

  return json({
    phone_number: offer.phoneNumber,
    region: offer.region,
    city: cityKey,
    held_until: heldUntil,
    reservation_id: reservationId,
    // Never rendered. Carried so `verify-line-subscription` can stamp it onto
    // phone_lines.monthly_cost_cents — nothing reports the cost again after
    // purchase, so this quote is the only chance to record it.
    monthly_cents: offer.monthlyCents,
    upfront_cents: offer.upfrontCents,
  });
});
