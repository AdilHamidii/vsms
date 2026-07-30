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
const PRICING: Record<string, number> = {
  "gmail.com": 1,
  "icloud.com": 1,
  "outlook.com": 0,
  "hotmail.com": 0,
};

/** Render order: paid first (they are the reliable, high-stock ones), then the
 *  free pair. Deliberately NOT sorted by price ascending — leading with the
 *  scarcest inventory is how you make a picker whose top entry is usually
 *  "Out of stock". */
const ORDER = ["gmail.com", "icloud.com", "outlook.com", "hotmail.com"];

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
