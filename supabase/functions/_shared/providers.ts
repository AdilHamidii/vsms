// Unified provider router. SMS is served by ONE provider at a time, with no
// cross-provider fallback (owner decision 2026-07-30). The order functions call
// these instead of a specific provider, so routing lives in one place.
//
// Each provider owns its identifier scheme:
//   smspva  — smspva_code ("opt20") + smspva country code ("US")
//
// RETIRED 2026-07-30: smspool (SMS only — it keeps the eSIM line, a separate
// table and code path) and virtualsms (purchase endpoint 503'd for every combo,
// 3 lifetime orders, 0 codes). Their adapters, syncs and route codes are gone.
// Their names survive ONLY as historical values on `orders.provider` — 50 and 3
// rows respectively — which is why `OrderProvider` still admits them and
// `orders_provider_check` still permits them. Rewriting those rows would
// destroy the delivery evidence they carry.

import * as five from "./fivesim.ts";
import * as hero from "./herosms.ts";
import {
  getNumber as smsGetNumber,
  getSms,
  cancelOrder as smsCancel,
  blockNumber as smsBlock,
  getServicePrice,
  getBalance as smsGetBalance,
  isOk,
} from "./smspva.ts";

/** Providers that can be ROUTED TO for a new order.
 *
 *  Ownership is PER SERVICE, not per route (owner decision 2026-07-30): a
 *  service HeroSMS carries goes entirely to HeroSMS, and a service it does not
 *  carry stays entirely on SMSPVA. That keeps the catalog wide — 265 services
 *  instead of the ~148 HeroSMS maps — without ever splitting one service across
 *  two providers, which is what makes evidence per service meaningful.
 *
 *  There is no fallback BETWEEN providers: providerOrder() returns exactly one,
 *  so a HeroSMS stockout fails as a stockout instead of silently re-reserving
 *  at SMSPVA under a different price and delivery profile. SMSPVA also stays
 *  fully wired as the rollback target, and its routes are never deleted. */
export type Provider = "5sim" | "herosms" | "smspva";

/** Providers that may appear on an existing `orders.provider`, including
 *  retired ones. Lifecycle calls (poll/release/markDead/markSuccess) accept
 *  this wider type because they run against rows written long ago. */
export type OrderProvider = Provider | "smspool" | "virtualsms";

/** Documented provider failure classes, so callers map to real user copy.
 *  create-order branches on THIS, never on the raw error string.
 *
 *  Formerly `SmspoolErrorType`, defined in the SMSPool adapter. It was never
 *  SMSPool-specific — it is the router's shared vocabulary — and leaving it
 *  named after a provider that no longer serves SMS invited exactly the kind of
 *  confusion this cleanup exists to remove. */
export type ProviderErrorType =
  | "OUT_OF_STOCK" | "PRICE_NOT_FOUND" | "BALANCE_ERROR"
  | "RATE_LIMITED" | "AUTH_ERROR" | "TRANSPORT_ERROR";

/** Our temporary-EMAIL vocabulary — mirrors `public.email_status` exactly.
 *
 *  Deliberately OURS and not the vendor's: HeroSMS's email status set is
 *  undocumented and only `WAIT`/`CANCEL` have ever been observed. See
 *  `_shared/emailStatus.ts` for the mapping and why guessing a vendor enum into
 *  the database is the mistake that already broke eSIM refunds. */
export type EmailStatus =
  | "waiting" | "received" | "canceled" | "expired" | "failed";

export interface RouteCodes {
  /** `routes.provider` — the column that decides PRICING (which divisor, which
   *  cached-cost column). Passing it here is what stops the router and the
   *  pricing from ever disagreeing.
   *
   *  Before 5sim, routing was code-presence only. That was safe while each
   *  service had codes for exactly one provider — but every service now also
   *  carries a 5sim product, so code-presence alone would route a route whose
   *  `provider` still says 'herosms' to 5sim, and create-order would then price
   *  it with HeroSMS's divisor against HeroSMS's cached cost while buying from
   *  someone else. That is the silent breakage all three previous switches had.
   *  Optional so old callers still work; when absent we fall back to codes. */
  owner?: string | null;
  /** 5sim product slug ("facebook", "leboncoin") and country slug ("usa"). */
  fiveProduct?: string | null;
  fiveCountry?: string | null;
  /** HeroSMS short service code ("ig", "wa", "do"=leboncoin). */
  heroService?: string | null;
  /** HeroSMS numeric country id (16=UK, 187=USA, 33=Colombia). */
  heroCountry?: number | string | null;
  smsService?: string | null;
  smsCountry?: string | null;
  dial: string;
}

/** The one provider that serves this route.
 *
 *  Ownership is per SERVICE, not per route (owner decision 2026-07-30):
 *
 *    - a service HeroSMS carries  -> HeroSMS, in every country
 *    - a service it does not      -> SMSPVA, in every country
 *
 *  So a given service is never split across providers — no country of Instagram
 *  is served by one provider while another country is served by the other. That
 *  keeps delivery evidence per service attributable to a single vendor, which
 *  is exactly what a blended rate destroys (measured once at 10% while the live
 *  provider was at 43%).
 *
 *  It also preserves the catalog: 118 of 268 services have no HeroSMS code, and
 *  routing them to SMSPVA keeps 7,757 active routes that would otherwise go
 *  dark. HeroSMS covers 150 services carrying 99.4% of lifetime order volume.
 *
 *  ALWAYS A SINGLE ELEMENT — there is NO fallback. A HeroSMS service whose
 *  country HeroSMS cannot fill fails honestly rather than quietly buying from
 *  SMSPVA, because a silent cross-provider substitution is what hid
 *  virtualsms's dead purchase endpoint behind SMSPVA for weeks: create-order's
 *  loop tried the next provider and the failure never surfaced.
 *
 *  TO ROLL BACK everything to SMSPVA: drop the first branch.
 *
 *  eSIMs are untouched and stay on SMSPool (a separate table and code path). */
export function providerOrder(c: RouteCodes): Provider[] {
  // OWNERSHIP FIRST. `routes.provider` is authoritative whenever it names a
  // provider we can actually reach — see RouteCodes.owner for why. A route may
  // now carry codes for two providers at once, and the one that prices it must
  // be the one that buys it.
  if (c.owner === "5sim" && c.fiveProduct && c.fiveCountry) return ["5sim"];
  if (c.owner === "herosms" && c.heroService && c.heroCountry != null) return ["herosms"];

  // 🔴 SMSPVA IS RETIRED FROM ROUTING (owner decision, 2026-08-17). It is no
  // longer returned for ANY route, owned or otherwise.
  //
  // It was not a pricing or margin problem — it stopped filling orders at all.
  // Measured over the 14 days to 2026-08-17: **7 orders, 0 numbers reserved,
  // 0 codes**, against 5sim 91/91 and HeroSMS 5/5 in the same window. Every
  // order routed here was a charge-and-refund, and it read to the user as
  // `no_numbers_available` ("try another country") because the adapter never
  // classified its failures — so the pager never fired either.
  //
  // Its 5,099 active routes were re-homed or hidden in the same commit
  // (943 to HeroSMS, 4,156 hidden). Leaving the router able to select it would
  // re-open the hole the moment any route was re-activated by an evidence
  // refresh, which `refresh_route_observed_success` does un-conditionally.
  //
  // The ADAPTER and the account are deliberately NOT deleted — this is a
  // routing change, so rollback is restoring these two lines plus re-activating
  // the routes. Do not "clean up" `smspva.ts` on the strength of this.

  // No owner recorded (or its codes are missing): fall back to code presence,
  // 5sim first — it is the primary SMS provider. HeroSMS stays wired because it
  // also serves the temp-EMAIL line on the same account.
  if (c.fiveProduct && c.fiveCountry) return ["5sim"];
  if (c.heroService && c.heroCountry != null) return ["herosms"];
  return [];
}

/** Live wholesale price (USD) at a provider, or null if unavailable. */
export async function livePriceUsd(p: Provider, c: RouteCodes): Promise<number | null> {
  try {
    if (p === "5sim" && c.fiveProduct && c.fiveCountry) {
      // 5sim quotes PER POOL, and the pool we buy from is chosen at sync time
      // (routes.pool_operator) — so a live "price for this route" is not a
      // single number. Returning null here is correct and deliberate:
      // create-order already prefers the synced `fivesim_cost_cents`, which is
      // the cost of the exact pool it is about to pin. Quoting the cheapest
      // pool instead would gate the margin against a pool we are not buying,
      // which is the apple/Turkey `getPrices.cost` bug in a new costume.
      return null;
    }
    if (p === "herosms" && c.heroService && c.heroCountry != null) {
      return await hero.getPrice(c.heroCountry, c.heroService);
    }
    if (p === "smspva" && c.smsService && c.smsCountry) {
      const r = await getServicePrice(c.smsCountry, c.smsService);
      return isOk(r) && Number.isFinite(r.data?.price) && r.data.price > 0 ? r.data.price : null;
    }
  } catch { /* fall through to null */ }
  return null;
}

export interface Reservation {
  ok: boolean;
  orderId?: string;   // provider's order/activation id
  number?: string;    // display-formatted phone number
  costUsd?: number;
  /** Provider's own hold deadline (epoch seconds) when it reports one. */
  expiresAt?: number;
  /** Carrier/pool that actually filled, for outcome attribution. */
  pool?: string;
  error?: string;
  errorType?: ProviderErrorType;
}

/** Reserve a number at a provider. maxPriceUsd caps the fill price where the
 *  provider supports it; pool pins the carrier the route was priced from.
 *  pinStrict=true (premium tier) makes a dry pin a hard failure instead of
 *  retrying unpinned. */
export async function reserve(
  p: Provider, c: RouteCodes, maxPriceUsd?: number, pool?: string | null,
  pinStrict = false,
): Promise<Reservation> {
  try {
    if (p === "5sim" && c.fiveProduct && c.fiveCountry) {
      // `pool` is an ORDERED, comma-separated fallback CHAIN, not a set.
      // 5sim buys one operator per URL path segment (unlike HeroSMS, whose
      // getNumberV2 takes a comma list in one call), so we walk the chain.
      //
      // Bounded at 3 pinned attempts + one unpinned, because each is a real
      // round trip inside the order path. The chain is already ordered
      // best-rate-first by sync-5sim.
      const chain = (pool ?? "").split(",").map((s) => s.trim()).filter(Boolean).slice(0, 3);
      const attempts = chain.length ? chain : ["any"];
      let last: Awaited<ReturnType<typeof five.buyActivation>> | null = null;

      for (const op of attempts) {
        last = await five.buyActivation(c.fiveCountry, op, c.fiveProduct);
        if (last.ok) break;
        // Only scarcity is worth trying the next pool. A BALANCE/AUTH fault
        // will fail identically on every pool, and walking the chain would turn
        // one dead account into four pointless calls; an unclassified error is
        // NOT retried here because it may mean the number was already
        // allocated, which is how a double purchase happens.
        if (last.errorType !== "OUT_OF_STOCK") break;
      }

      // Every named pool was dry. Fall back to the general pool unless the
      // caller pinned strictly (premium / real-SIM-only), where an unvetted
      // fill is worth less than an honest stockout.
      if (last && !last.ok && !pinStrict && chain.length &&
          last.errorType === "OUT_OF_STOCK") {
        // The one place 5sim honours maxPrice (operator === "any").
        last = await five.buyActivation(c.fiveCountry, "any", c.fiveProduct, maxPriceUsd);
      }

      if (!last || !last.ok) {
        return { ok: false, error: last?.error, errorType: last?.errorType };
      }
      return {
        ok: true,
        orderId: last.orderId,
        // Already full E.164 from the adapter. Deliberately NOT
        // `${c.dial} ${number}` — that form is SMSPVA's, which returns a
        // NATIONAL number, and reusing it would double the country code.
        number: last.phoneNumber ?? "",
        // 5sim accepts NO price cap, so this is the first moment the real price
        // is known. create-order's post-fill ceiling check is the only guard on
        // this provider and must not be skipped.
        costUsd: last.costUsd,
        expiresAt: last.expiresAt,
        // What actually filled, echoed by the buy response.
        pool: last.operator ?? undefined,
      };
    }
    if (p === "herosms" && c.heroService && c.heroCountry != null) {
      // Unlike SMSPVA, this provider ACCEPTS a price cap and REPORTS the cost,
      // so `maxPriceUsd` is enforced provider-side instead of only being
      // checked after the fill. That closes the window where a route quoted at
      // pennies bills dollars (seen live on the old stack: wechat/kg quoted 6c,
      // filled at 79c).
      //
      // `pool` is a carrier name from getOperators. pinStrict (premium tier)
      // makes a dry carrier a hard failure; standard retries unpinned rather
      // than losing the sale.
      let r = await hero.buyNumber(c.heroCountry, c.heroService, pool ?? undefined, maxPriceUsd);
      if (!r.ok && pool && !pinStrict &&
          (r.errorType === "OUT_OF_STOCK" || r.errorType === undefined)) {
        r = await hero.buyNumber(c.heroCountry, c.heroService, undefined, maxPriceUsd);
      }
      if (!r.ok) return { ok: false, error: r.error, errorType: r.errorType };
      return {
        ok: true,
        orderId: r.orderId,
        // Already normalised to full E.164 with a leading "+" by the adapter.
        // Deliberately NOT `${c.dial} ${number}` — that form exists for SMSPVA,
        // which returns a NATIONAL number, and reusing it here would produce a
        // doubled country code.
        number: r.phoneNumber ?? "",
        costUsd: r.costUsd,
        expiresAt: r.expiresAt,
        // What ACTUALLY filled, not what we asked for. These differ in both
        // directions now: an opportunistic pin can fall back to the general
        // pool, and `pool` may be a comma-separated LIST of acceptable real
        // carriers — which would be useless for attribution. Falls back to the
        // request only when the provider does not say (the v1 text path).
        pool: r.operator ?? pool ?? undefined,
      };
    }
    if (p === "smspva" && c.smsService && c.smsCountry) {
      // SMSPVA's allocation endpoint accepts no price cap and reports no cost
      // — it once billed $3.60 on a route quoted at pennies. Bracket the
      // purchase with balance reads so the caller learns the REAL charge and
      // can hide/reprice the route. Best-effort: if either read fails we
      // still complete the order, just without a measured cost.
      //
      // `pool` here is an SMSPVA OPERATOR pin — a real carrier such as
      // "Vodafone_UK". Random (unpinned) fills come from the anonymized
      // Donor* pools, the VoIP-style stock strict services reject.
      //
      //  - premium (pinStrict): a dry carrier FAILS and create-order refunds
      //    — the buyer paid for the real-SIM pool, never silently downgrade
      //    (owner decision 2026-07-21).
      //  - standard: pin opportunistically and fall back to a random fill
      //    when the carrier is dry or the error is unclassified. Probed
      //    2026-07-21: the carrier costs the same or less than a random fill
      //    on all 16,320 active routes, so this is a free delivery upgrade
      //    that can never do worse than the old always-random behavior.
      const before = await smsGetBalance().catch(() => null);
      let usedPool = pool ?? undefined;
      let r = await smsGetNumber(c.smsCountry, c.smsService, usedPool);
      if (!isOk(r) && usedPool && !pinStrict) {
        const t = classifySmspvaFault(r.error?.type ?? "smspva_error");
        if (t === undefined || t === "OUT_OF_STOCK") {
          usedPool = undefined;
          r = await smsGetNumber(c.smsCountry, c.smsService);
        }
      }
      if (!isOk(r)) {
        const raw = r.error?.type ?? "smspva_error";
        return { ok: false, error: raw, errorType: classifySmspvaFault(raw) };
      }
      let costUsd: number | undefined;
      const after = await smsGetBalance().catch(() => null);
      // `before`/`after` are `.catch(() => null)` — the null is the whole point,
      // because the balance probe is best-effort cost attribution. But `isOk`
      // dereferences `r.statusCode`, so `isOk(null)` THROWS, and it throws here:
      // after the number is already reserved and billed. That is a charge, a
      // refund, and forfeited wholesale on a number we then abandon. Caught by
      // `deno check` 2026-07-30; present since 91dc756 on a path that still
      // serves 7,757 active SMSPVA routes.
      const b0 = before && isOk(before) ? before.data?.balance : undefined;
      const b1 = after && isOk(after) ? after.data?.balance : undefined;
      if (typeof b0 === "number" && typeof b1 === "number" && b0 > b1) costUsd = b0 - b1;
      return {
        ok: true,
        orderId: String(r.data.orderId),
        // SMSPVA returns a NATIONAL number, so the dial code is prepended here.
        // Any future provider that returns full E.164 must NOT reuse this line
        // — it would produce a doubled country code.
        number: `${c.dial} ${r.data.phoneNumber}`,
        costUsd,
        pool: usedPool,
      };
    }
  } catch (e) {
    return { ok: false, error: String(e) };
  }
  return { ok: false, error: "provider_not_configured" };
}

/** Map an SMSPVA error `type` onto the shared fault taxonomy.
 *
 *  Until now the SMSPVA branch set `error` (a free string) but never
 *  `errorType`, and create-order classifies purely on `errorType`. So EVERY
 *  SMSPVA failure — dead account, bad key, rate limit, genuine stockout — fell
 *  through to "no_numbers_available". Two consequences, both bad:
 *
 *    - the user is told "try another country or service", so they dutifully
 *      try every country and get the same lie each time;
 *    - the one console.error written to make a dead provider loud is itself
 *      gated on errorType, so it never fired for the only SMS provider we have.
 *
 *  With one SMS provider and no fallback, an empty balance would take the
 *  product down with no signal anywhere.
 *
 *  SMSPVA's error vocabulary is not publicly documented (docs.smspva.com
 *  describes a different, older API), and the only string confirmed live is
 *  APIKEY_NOT_SET. So match on substrings rather than pretending to know the
 *  full enum, and log anything unrecognised so the real vocabulary can be
 *  learned from production instead of guessed.
 */
function classifySmspvaFault(raw: string): ProviderErrorType | undefined {
  const t = raw.toUpperCase();
  // FIRST, because these are OUR sentinels, not SMSPVA's vocabulary. smspva.ts
  // manufactures UPSTREAM_TIMEOUT (fetch threw, or the 10s AbortSignal fired)
  // and UPSTREAM_NON_JSON itself. Neither matched any regex below, so both fell
  // through to `undefined` — and the reserve() retry gate reads `undefined` as
  // "the pinned carrier is dry, retry unpinned" and immediately buys a SECOND
  // number while SMSPVA has already allocated and billed the first. We never
  // learn the first one's id, so nothing ever reclaims it: up to $7.50 of
  // wholesale spent twice, one number held to natural expiry, and no log line.
  //
  // Live on the whole SMSPVA catalog, because all 7,757 active SMSPVA routes
  // carry an operator to pin, and pinStrict is false for every standard order.
  //
  // Classifying as TRANSPORT_ERROR fixes three things at once: the retry gate
  // no longer fires (TRANSPORT_ERROR is neither `undefined` nor OUT_OF_STOCK),
  // create-order's "possible orphaned paid reservation" console.error — which
  // is gated on exactly this type and therefore never fired on the SMSPVA path
  // it was written for — starts working, and the user is told the provider is
  // unreachable instead of being sent to try another country.
  if (/UPSTREAM_TIMEOUT|UPSTREAM_NON_JSON|ABORT|ECONNRESET/.test(t)) {
    return "TRANSPORT_ERROR";
  }
  if (/BALANCE|FUND|MONEY|DEPOSIT|PAYMENT/.test(t)) return "BALANCE_ERROR";
  if (/APIKEY|API_KEY|AUTH|TOKEN|FORBID|DENIED/.test(t)) return "AUTH_ERROR";
  if (/LIMIT|FREQUENT|TOO_MANY|FLOOD|THROTTL/.test(t)) return "RATE_LIMITED";
  // From SMSPVA's official OpenAPI schema (smspva.com/json/schema.php):
  // PRICE_FETCH_FAIL(501) is a transient price-lookup failure — route it to
  // the margin path, not "no numbers". SERVER_BUSY(503) is "server overload,
  // try later" — a retryable hiccup, NOT a stockout; classifying it as
  // OUT_OF_STOCK told users to abandon a route that was fine seconds later.
  if (/PRICE_FETCH|PRICE_NOT/.test(t)) return "PRICE_NOT_FOUND";
  if (/SERVER_BUSY|OVERLOAD/.test(t)) return "RATE_LIMITED";
  if (/STOCK|NO_NUMBER|NUMBERS|AVAIL|EMPTY|SOLD|NUMBER_NOT_FOUND/.test(t)) return "OUT_OF_STOCK";
  // Deliberately undefined: create-order then uses its existing default. We do
  // NOT invent a classification we cannot justify — but we do make it visible.
  console.error(`smspva: unclassified error type "${raw}" — add it to classifySmspvaFault`);
  return undefined;
}

/** A lifecycle call arrived for a provider we can no longer talk to.
 *
 *  This function is the whole reason the retired names survive in the type.
 *  Previously every lifecycle switch ended in an UNGUARDED SMSPVA call, so any
 *  provider without an explicit branch silently had its orders polled and
 *  cancelled against SMSPVA using a foreign order id — returning HTTP 200 the
 *  entire time, delivering nothing, and never reclaiming the wholesale. Refuse
 *  loudly instead; a retired provider has no open orders to service anyway
 *  (verified 2026-07-30: zero waiting orders on any provider). */
/** Cancel a HeroSMS activation and classify the outcome LOUDLY.
 *
 *  `hero.cancel()` RETURNS `{ok:false, error}` — it does not throw — so a bare
 *  try/catch around it is dead code and the failure vanishes. That mattered:
 *  handler_api refuses a cancel inside the first ~2 minutes with
 *  EARLY_CANCEL_DENIED, and several call sites fire milliseconds after the buy
 *  (the over-ceiling release and the order_persist_failed release). Every one
 *  of those forfeits the wholesale AND leaves the number held against the
 *  account's concurrency cap, with nothing in the logs.
 *
 *  We cannot retry from here — the caller has already flipped the row terminal,
 *  so no sweep will revisit it. What we CAN do is make it visible and
 *  distinguish the three real outcomes, so the cost is measurable rather than
 *  invisible. A durable retry queue is the proper fix and is tracked separately.
 */
async function heroRelease(fn: string, orderId: string): Promise<void> {
  try {
    const r = await hero.cancel(orderId);
    if (r.ok) return;
    const err = r.error ?? "unknown";
    if (hero.isCancelAlreadyDone(err)) return;      // already finished — fine
    if (hero.isCodeArrived(err)) {
      // Cancelling would discard a code the provider says has ARRIVED.
      console.error(`${fn} herosms order=${orderId}: code already arrived (${err}) — not cancelled`);
      return;
    }
    console.error(
      `${fn} herosms order=${orderId}: cancel FAILED (${err})` +
      `${hero.isCancelRetryable(err) ? " — retryable, wholesale forfeited for now" : ""}`,
    );
  } catch (e) {
    console.error(`${fn} herosms order=${orderId} threw:`, e);
  }
}

function refuseRetired(fn: string, p: string, orderId: string): void {
  console.error(
    `${fn}: refusing retired provider "${p}" order=${orderId} — no adapter, ` +
    `and falling through to another provider's API would corrupt its state`,
  );
}

/** Tell the provider an activation SUCCEEDED. SMSPVA's blocknumber marks the
 *  number used — their docs ask for it, and account karma influences the
 *  quality of numbers they hand out next. Best-effort hygiene: a failure here
 *  must never affect the delivered order. */
export async function markSuccess(p: OrderProvider, orderId: string): Promise<void> {
  if (p === "5sim") {
    // `finish` closes the activation. 5sim tracks an account `rating` (96/96
    // today) that falls on abusive cancel patterns and blocks buying below a
    // floor, so closing successful orders properly is not just hygiene here.
    try { await five.finish(orderId); } catch { /* hygiene only */ }
    return;
  }
  if (p === "herosms") {
    // setStatus=6 (finish) is HeroSMS's "this activation is done" signal.
    try { await hero.finish(orderId); } catch { /* hygiene only */ }
    return;
  }
  if (p !== "smspva") return;
  try { await smsBlock(orderId); } catch { /* hygiene only */ }
}

/** Tell the provider an activation FAILED (ran its whole window with no SMS)
 *  and close it. SMSPVA's own docs instruct exactly this: "If you haven't
 *  received an SMS within 580 seconds, make sure to ban the number" — an
 *  unbanned request id is retained for ~10 minutes and the same dead number
 *  is allocated again (measured live 2026-07-24: 9 retry orders drew only 6
 *  distinct numbers). Ban and cancel carry the identical karma cost
 *  (-0.0125 each, smspva.com/info.html), so this is free hygiene that stops
 *  dead numbers cycling back into our own orders. Ban first, then cancel to
 *  reclaim the wholesale refund; both best-effort — the user's credit refund
 *  has already happened by the time this runs and must never depend on it. */
export async function markDead(p: OrderProvider, orderId: string): Promise<void> {
  if (p === "5sim") {
    // CANCEL FIRST, then ban — the same order as SMSPVA below and for the same
    // reason: cancel is what reclaims the wholesale (verified live 2026-08-03,
    // balance returned to the cent), ban is hygiene so the number is not
    // re-issued. `ban` refuses with "order has sms" once a code landed, which
    // the adapter treats as success.
    const c = await five.cancel(orderId);
    const b = await five.ban(orderId);
    console.log(`markDead 5sim order=${orderId} cancel=${c.ok} ban=${b.ok}` +
      `${c.error ? ` cancelErr=${c.error}` : ""}${b.error ? ` banErr=${b.error}` : ""}`);
    return;
  }
  if (p === "herosms") {
    await heroRelease("markDead", orderId);
    return;
  }
  if (p !== "smspva") { refuseRetired("markDead", p, orderId); return; }
  // Log both outcomes explicitly: these calls return SMSPVA's error ENVELOPE
  // rather than throwing, so a silent try/catch would hide whether the ban
  // registered and whether the follow-up cancel still reclaims the wholesale
  // cost (undocumented — the ban may consume the request id). This line is
  // the only evidence available for that interaction.
  // CANCEL FIRST, then ban. This order is deliberate and was reversed on
  // 2026-07-27.
  //
  // `cancelorder` is what reclaims the wholesale cost; `blocknumber` is
  // hygiene. Banning first risked consuming the request id (undocumented — the
  // comment above has always said so), which would forfeit the refund on every
  // call. That became material the moment cancel-order stopped calling
  // release() and routed all reclamation through here: measured $38.14 of
  // wholesale sat in cancels over 30 days, against ~$146 of net revenue in the
  // same period.
  //
  // The trade is explicit: if cancelling frees the number before the ban
  // registers, it can be re-issued — but the client's fresh-number guarantee
  // already filters numbers this user recently burned, whereas a forfeited
  // refund is certain, unrecoverable cash.
  let banOk = false, cancelOk = false, detail = "";
  try {
    const c = await smsCancel(orderId);
    cancelOk = isOk(c);
    if (!cancelOk) detail += `cancel=${(c as { error?: { type?: string } }).error?.type ?? "?"} `;
  } catch (e) { detail += `cancel_threw=${e} `; }
  try {
    const b = await smsBlock(orderId);
    banOk = isOk(b);
    if (!banOk) detail += `ban=${(b as { error?: { type?: string } }).error?.type ?? "?"}`;
  } catch (e) { detail += `ban_threw=${e}`; }
  console.log(`markDead order=${orderId} ban=${banOk} cancel=${cancelOk} ${detail}`);
}

export interface PollResult {
  state: "waiting" | "received" | "canceled" | "expired" | "unknown";
  code?: string;
  fullText?: string;
}

/** Poll a provider order for the SMS code. */
export async function poll(p: OrderProvider, orderId: string): Promise<PollResult> {
  if (p === "5sim") {
    // The adapter reads sms[].code, NOT `status` — 5sim returns
    // `status:"RECEIVED"` for a number that is merely waiting.
    const s = await five.getStatus(orderId);
    return { state: s.state, code: s.code, fullText: s.fullText };
  }
  if (p === "herosms") {
    const s = await hero.getStatus(orderId);
    return { state: s.state, code: s.code, fullText: s.fullText };
  }
  if (p !== "smspva") {
    refuseRetired("poll", p, orderId);
    return { state: "unknown" };
  }
  const r = await getSms(orderId);
  if (isOk(r) && r.data.sms?.code) {
    return { state: "received", code: r.data.sms.code, fullText: r.data.sms.fullText };
  }
  // The envelope statusCode carries meaning we used to throw away (spec:
  // docs/apidocs.pdf, getSms error table). 407 is the expensive one: SMSPVA
  // HAS the SMS and is withholding it because our balance can't pay for it —
  // treating that as "waiting" polls the order to expiry, refunds the user,
  // records a delivery failure, and forfeits a code that a top-up releases.
  const sc = (r as { statusCode?: number }).statusCode ?? 0;
  if (sc === 407) {
    console.error(
      `smspva poll ${orderId}: 407 SMS RECEIVED BUT BALANCE TOO LOW — ` +
        `the code exists and is withheld; top up SMSPVA to release it`,
    );
    return { state: "waiting" }; // keep alive: a top-up inside the window rescues it
  }
  if (sc === 406 || sc === 410) return { state: "expired" }; // order invalid/closed at provider
  if (sc === 411) console.error(`smspva poll ${orderId}: 411 karma/rate-limit`);
  return { state: "waiting" };
}

/** Best-effort release/cancel at a provider (local refund happens regardless). */
export async function release(p: OrderProvider, orderId: string): Promise<void> {
  if (p === "5sim") {
    const r = await five.cancel(orderId);
    if (!r.ok) console.error(`release failed provider=5sim order=${orderId}: ${r.error}`);
    return;
  }
  if (p === "herosms") { await heroRelease("release", orderId); return; }
  if (p !== "smspva") { refuseRetired("release", p, orderId); return; }
  try {
    await smsCancel(orderId);
  } catch (e) {
    console.error(`release failed provider=${p} order=${orderId}:`, e);
  }
}
