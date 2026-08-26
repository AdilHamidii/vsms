// The four mail domains we sell for one service, with LIVE stock.
//
// Exists because stock is per (site, domain) and genuinely runs dry: measured
// 2026-07-30, hotmail.com had 1,028 available for google.com and TWO for
// discord.com. Without this the picker would have to assume availability and
// discover the truth only after a user taps buy — and the free tier, which is
// the scarcest inventory we sell, would look broken rather than empty.
//
// Prices are OURS and fixed (1 credit / free); only `available` is live.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { listDomains, faultOf } from "../_shared/heromail.ts";

interface Body { service_id: string; }

/** Keep in lockstep with create-email-order's PRICING — it is the gate that
 *  actually charges, this is only what the picker renders. */
// gmail.com REMOVED 2026-08-26 (owner decision) — its HeroSMS pool delivered
// 1 code in 36 orders since ~08-10 while the free pair delivered normally.
// See create-email-order's copy for the full note; change both together.
const PRICING: Record<string, number> = {
  "outlook.com": 0,
  "hotmail.com": 0,
};

/** Render order: FREE first (owner decision, 2026-07-31).
 *
 *  This reverses the original "paid first" rule, whose reasoning was that the
 *  free pair is the scarcest inventory and leading with it makes a picker whose
 *  top entry is often "Out of stock". That risk is real but already handled a
 *  layer up: the client defaults to `first(where: { $0.inStock })`, so an empty
 *  outlook.com falls through to hotmail.com and then gmail.com automatically.
 *
 *  Free-first is the right default because e-mail exists to ACQUIRE users, not
 *  to earn — the paid tier is 1 credit against an SMS median of 16, so nothing
 *  here is worth optimising for revenue at the cost of a first-run wall.
 *
 *  icloud.com was REMOVED 2026-07-31 (owner decision). Handing out throwaway
 *  addresses on Apple's own consumer domain, from an app distributed on Apple's
 *  store, is an avoidable review risk for a tier that earned nothing. Removing
 *  it from PRICING is also the enforcement: create-email-order rejects any
 *  domain missing from its own copy of the map with `domain_unavailable`. */
const ORDER = ["outlook.com", "hotmail.com"];

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.service_id) return json({ error: "missing_fields" }, { status: 400 });

  const sb = admin();
  const { data: service, error: svcErr } = await sb
    .from("services").select("id, domain").eq("id", body.service_id).maybeSingle();
  if (svcErr) {
    console.error(`email-domains: service read failed: ${svcErr.message}`);
    return json({ error: "service_lookup_failed" }, { status: 500 });
  }
  if (!service) return json({ error: "unknown_service" }, { status: 404 });

  // 11 of 265 visible services have no domain, so email cannot be offered for
  // them at all — the provider requires a target site.
  const site = (service.domain ?? "").trim().toLowerCase();
  if (!site) return json({ error: "email_unsupported_service" }, { status: 409 });

  const live = await listDomains(site);
  const fault = faultOf(live);
  if (fault) {
    console.error(`email-domains: ${site} ${fault.title}: ${fault.message}`);
    return json({ error: "provider_unreachable" }, { status: 502 });
  }

  const bySite = new Map(
    (live as { name: string; cost: number; count: number }[])
      .map((d) => [d.name.toLowerCase(), d]),
  );

  const domains = ORDER.map((name) => ({
    domain: name,
    credits: PRICING[name],
    // 0 when the provider does not list it at all for this site — same meaning
    // as listing it with no stock, and the picker treats both as unavailable.
    available: bySite.get(name)?.count ?? 0,
  }));

  return json({ site, domains });
});
