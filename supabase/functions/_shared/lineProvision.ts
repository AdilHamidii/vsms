// The ONE provisioning sequence for a rented line, from "we hold the number's
// e164 and a row to hang it on" to "the line is active and can ring".
//
// It existed twice — `verify-line-subscription` (Apple-billed) and
// `rent-line-credits` (credits-billed) — in the same order, with the same
// traps commented in both. `apple-notifications` needed it a THIRD time
// (auto-reprovisioning after a renewal lands on a released line), and a third
// copy is exactly how five of six sold lines ended up unable to make a call:
// voice was provisioned in one path and not the other, and nothing threw.
//
// So the sequence lives here once:
//
//   3. orderNumber                (customer_reference = line id)
//   4. record_line_order          (the only handle on an ASYNCHRONOUS buy)
//   5. poll getOrder              (incl. the requirement-info-pending dead end)
//   6. attachMessagingProfile     (routes inbound SMS to our webhook)
//   6b. provisionLineVoice        (what makes the number RING)
//   7. activate_line_claim        (stamp the ids, flip to active)
//
// Steps 1 and 2 stay with the caller, because they are the part that differs:
// who is charged (Apple / credits / nobody), and which row-creating claim runs.
// Everything after the row exists is identical, and the ONE thing each caller
// still owns after that point is what a failure costs — a credits refund or a
// `fail_line_claim` — which is why `onFail` is a callback rather than a flag.

import { admin } from "./supabaseAdmin.ts";
import {
  orderNumber, getOrder, findNumberId, attachMessagingProfile,
  releaseNumber, searchNumbers, faultOf, type AvailableNumber,
} from "./telnyx.ts";
import { provisionLineVoice } from "./lineVoice.ts";
import {
  localitiesFor, withinWholesaleCeiling,
  type LineCatalogConfig, type LineLocality,
} from "./lineCatalog.ts";
import { NANP } from "./phone.ts";

type SB = ReturnType<typeof admin>;

/** The server's own default place, used when the caller has no country of its
 *  own to honour (or the one it wanted stopped being sellable). It was a
 *  literal in three files; the picker, the reserve step and the two rental
 *  paths must agree on it by construction. */
export const DEFAULT_LINE_COUNTRY = "CA";

/** Telnyx number orders are asynchronous: `pending` → `success`, measured
 *  under 5s. Poll rather than trusting a webhook — a webhook outage must not
 *  strand a purchase Apple has already taken money for. */
const ORDER_POLL_ATTEMPTS = 10;
const ORDER_POLL_MS = 1000;

export type ProvisionResult =
  | { ok: true; e164: string; inboundReady: boolean; numberId: string | null }
  | { ok: false; reason: string; status: number };

export interface CompleteLineProvisionOpts {
  /** The `provisioning` row that already exists. */
  lineId: string;
  /** The number to buy — already re-quoted server-side by the caller. */
  e164: string;
  country: string;
  numberType: string;
  /** Only ever non-null for a country selling under an APPROVED pre-verified
   *  bundle; for US/CA it is null and the request body is byte-identical to the
   *  shape that has always worked. */
  requirementGroupId: string | null;
  /** What `activate_line_claim` stamps as `current_period_end`. */
  periodEnd: string | null;
  /** What TELNYX charges US, from the caller's own server-side quote. When the
   *  caller cannot know it before the buy (the number's exact identity is only
   *  settled by the order), it passes `quoteCost` instead. */
  monthlyCents?: number | null;
  quoteCost?: (e164: string) => Promise<number | null>;
  /** Undo whatever step 2 did — a credits refund, or `fail_line_claim`. Called
   *  with a short machine reason on EVERY failure after the row exists. */
  onFail: (reason: string) => Promise<void>;
}

/**
 * Buy the number and bring the line up. Everything after the caller's own
 * charge-and-row step.
 *
 * Never throws for a provider problem: it returns `{ok:false}` with the status
 * the callers already answer with, so a failure reads the same from the client
 * as it always did.
 */
export async function completeLineProvision(
  sb: SB, o: CompleteLineProvisionOpts,
): Promise<ProvisionResult> {
  // ── 3. Buy it ────────────────────────────────────────────────────────────
  // `customer_reference` = the line id is what makes orphan reconciliation
  // possible: a number we own with no live line pointing at it is otherwise
  // invisible until the invoice.
  const order = await orderNumber(o.e164, o.lineId, {
    requirementGroupId: o.requirementGroupId,
  });
  if (faultOf(order)) {
    await o.onFail(`order_${order.type}`);
    return { ok: false, reason: "provision_failed", status: 502 };
  }

  // ── 4. Stamp the order id NOW, not on success ────────────────────────────
  // A provision that fails after the buy is exactly when this handle matters:
  // the order is ASYNCHRONOUS, the number may still arrive after we stop
  // polling, and `activate_line_claim` never runs on that path.
  const { error: orderIdErr } = await sb.rpc("record_line_order", {
    p_line: o.lineId, p_order_id: order.orderId,
  });
  if (orderIdErr) {
    console.error(JSON.stringify({
      alert: "line_order_id_unrecorded", line: o.lineId, order: order.orderId,
      detail: orderIdErr.message,
    }));
  }

  // ── 5. Poll ──────────────────────────────────────────────────────────────
  let e164: string | null = null;
  for (let i = 0; i < ORDER_POLL_ATTEMPTS; i++) {
    const st = await getOrder(order.orderId);
    if (faultOf(st)) break;
    const n = st.numbers[0];
    // ⚠️ `requirement-info-pending` means BOUGHT AND UNUSABLE pending
    // regulatory documents. It reads like progress and is a dead end — the
    // mistake that cost $3.83 on a GB number. Our catalog said this country
    // needs none, so seeing it here means the CATALOG is wrong, and the number
    // must be released rather than waited on.
    if (n?.status === "requirement-info-pending") {
      await releaseIfPossible(o.e164);
      // Self-healing: Telnyx's refusal is EVIDENCE and it beats our own probe,
      // so the next user does not walk into the same wall.
      // `refresh_line_country_sellability()` preserves an `order_rejected`
      // block rather than re-opening it. Best-effort — the purchase is already
      // lost either way, so a failed write must not change the answer.
      const { error: blockErr } = await sb.from("line_country_catalog")
        .update({ sell_state: "blocked", sell_reason: "order_rejected" })
        .eq("country_code", o.country).eq("number_type", o.numberType);
      if (blockErr) {
        console.error(JSON.stringify({
          alert: "line_catalog_selfheal_failed", country: o.country,
          number_type: o.numberType, detail: blockErr.message,
        }));
      }
      await o.onFail("requirements_pending");
      return { ok: false, reason: "provision_failed", status: 502 };
    }
    if (st.status === "success" && n?.e164) { e164 = n.e164; break; }
    if (st.status === "failed") break;
    await new Promise((r) => setTimeout(r, ORDER_POLL_MS));
  }

  if (!e164) {
    // Might still land after we stop looking, so do NOT release blindly — the
    // orphan reconciler sweeps a number that arrived late.
    await o.onFail("order_timeout");
    return { ok: false, reason: "provision_failed", status: 504 };
  }

  // ── 6. Configure ─────────────────────────────────────────────────────────
  // The messaging profile is what routes inbound SMS to our webhook, and it is
  // NOT settable on the main number resource (error 10027) — it lives on the
  // /messaging sub-resource.
  const numberId = await findNumberId(e164);
  const msgProfile = Deno.env.get("TELNYX_MESSAGING_PROFILE_ID") ?? null;
  if (typeof numberId === "string" && msgProfile) {
    const attached = await attachMessagingProfile(numberId, msgProfile);
    if (faultOf(attached)) {
      // Not fatal — the number exists and voice works — but it means inbound
      // SMS goes nowhere, so it pages.
      console.error(JSON.stringify({
        alert: "line_msg_profile_failed", line: o.lineId, detail: attached.detail,
      }));
    }
  }

  // 🔴 VOICE IS PROVISIONED HERE, not lazily on first dialer open. Attaching
  // the number's voice to a connection is what makes it RING, and it used to
  // happen only in `mint-line-token` — so a number was sold that could not
  // receive a call until its owner opened the Number tab. Best-effort: the
  // money has already moved, so a voice fault must not fail the provision, and
  // the lazy path still repairs it.
  const voice = await provisionLineVoice(
    sb,
    { id: o.lineId, provider_number_id: typeof numberId === "string" ? numberId : null },
    // `activate_line_claim` writes the same columns moments later; writing
    // them first would target a line that is not live yet.
    { persistIds: false },
  );
  if (voice.faults.length) {
    console.error(JSON.stringify({
      alert: "line_voice_provision_failed", line: o.lineId,
      steps: voice.faults.map((f) => f.step),
      detail: voice.faults.map((f) => f.fault.detail).join("; "),
    }));
  }

  // ── 7. Activate ──────────────────────────────────────────────────────────
  const monthly = o.quoteCost ? await o.quoteCost(e164) : (o.monthlyCents ?? null);
  const { data: activated, error: actErr } = await sb.rpc("activate_line_claim", {
    p_line: o.lineId,
    p_number_id: typeof numberId === "string" ? numberId : null,
    p_connection: voice.connectionId,
    p_msg_profile: msgProfile,
    p_voice_profile: voice.voiceProfileId,
    p_credential: voice.credentialId,
    p_period_end: o.periodEnd,
    // From a server-side quote, never from a request: this is what we PAY, and
    // a client-supplied cost is a client-supplied margin.
    p_monthly_cost_cents: monthly,
    p_order_id: order.orderId,
  });
  if (actErr || activated !== true) {
    // 🔴 THE PROVISIONING LOCKOUT. Returning here without failing the line
    // leaves the row `provisioning` forever — and because
    // phone_lines_one_apple_line_per_user counts that status, the user is
    // BARRED from renting again while still paying. Give the number back too,
    // so we stop paying for it.
    console.error(JSON.stringify({
      alert: "line_activate_failed", line: o.lineId,
      detail: actErr?.message ?? "claim returned false",
    }));
    await releaseIfPossible(e164);
    await o.onFail("activate_failed");
    return { ok: false, reason: "provision_failed", status: 500 };
  }

  // `activate_line_claim` has no `p_attached`, so the one fact that decides
  // whether the phone RINGS is recorded separately, after the line is live.
  if (voice.attached) {
    await sb.rpc("record_line_voice_binding", { p_line: o.lineId, p_attached: true });
  }

  return {
    ok: true, e164, inboundReady: voice.attached,
    numberId: typeof numberId === "string" ? numberId : null,
  };
}

/** Best-effort release. A release we could not make must not vanish: the line
 *  is still failed by the caller, and `release-lines`' orphan sweep finds a
 *  number nothing points at — but only if we say so here. */
export async function releaseIfPossible(e164: string) {
  const id = await findNumberId(e164);
  if (typeof id !== "string") return;
  const r = await releaseNumber(id);
  if (faultOf(r)) {
    console.error(JSON.stringify({
      alert: "line_orphan_number", e164, detail: r.detail,
    }));
  }
}

export type PickResult =
  | { ok: true; offer: AvailableNumber; place: LineLocality | null }
  | { ok: false; reason: "no_numbers_available" | "provider_unreachable" | "line_wholesale_ceiling" };

/**
 * Choose a number ON THE USER'S BEHALF, walking the same localities and area
 * codes the picker walks — for the paths where nobody is on screen to choose
 * (today: reprovisioning after a renewal landed on a released line).
 *
 * Read-only at the provider: a search buys nothing, so it is safe to run
 * before the row-creating claim and safe to run concurrently with another
 * delivery of the same notification. The mutex is the row, never this.
 */
export async function pickLineNumber(
  sb: SB,
  o: {
    country: string; numberType: string; features: string[];
    cfg: LineCatalogConfig; localityId?: string | null;
  },
): Promise<PickResult> {
  const localities = await localitiesFor(sb, o.country, o.numberType);
  let place: LineLocality | null = null;
  if (o.localityId) place = localities.find((l) => l.id === o.localityId) ?? null;
  if (!place) place = localities[0] ?? null;

  const quote = (opts: { areaCode?: string; locality?: string; administrativeArea?: string }) =>
    searchNumbers({
      country: o.country, numberType: o.numberType, limit: 8,
      // From the catalog, never a literal: a hardcoded `sms+voice` returns 400
      // `10015` on a voice-only country.
      features: o.features,
      ...opts,
    });

  const offers: AvailableNumber[] = [];
  const codes = NANP.has(o.country) ? (place?.areaCodes ?? []) : [];
  if (codes.length > 0) {
    for (const code of codes) {
      const r = await quote({ areaCode: code });
      if (faultOf(r)) {
        // Only a real stockout justifies trying the next code — a dead key or
        // an outage is not a stock problem.
        if (r.type !== "OUT_OF_STOCK") return { ok: false, reason: "provider_unreachable" };
        continue;
      }
      if (r.length) { offers.push(...r); break; }
    }
  } else {
    const r = await quote({
      locality: place?.locality ?? undefined,
      administrativeArea: place?.adminArea ?? undefined,
    });
    if (faultOf(r)) {
      if (r.type !== "OUT_OF_STOCK") return { ok: false, reason: "provider_unreachable" };
    } else {
      offers.push(...r);
    }
  }
  if (!offers.length) return { ok: false, reason: "no_numbers_available" };

  // The wholesale ceiling is a SAFETY guard, not pricing — it stops a $27/mo
  // number being handed out against a $5.99 subscription. Take the first offer
  // that clears it rather than refusing outright on an expensive head of list.
  for (const offer of offers) {
    if (withinWholesaleCeiling(offer, o.cfg, o.country).ok) {
      return { ok: true, offer, place };
    }
  }
  return { ok: false, reason: "line_wholesale_ceiling" };
}
