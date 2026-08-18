// probe-telnyx-connection — READ-ONLY diagnostic. Cron-secret gated.
//
// Reads a credential connection back from Telnyx and returns ONLY the fields
// that decide whether the connection can place an outbound call. Exists
// because `attachOutboundProfile` PATCHes `outbound_voice_profile_id` at the
// TOP LEVEL while the docs put it under `outbound: {}` — and Telnyx returns
// 200-and-changes-nothing for a misplaced field (documented twice already in
// providers.md). Our DB says `provider_voice_attached = true`; this asks
// Telnyx what it actually holds. If `outbound.outbound_voice_profile_id` reads
// null on a line we marked attached, every outbound dial is rejected before a
// session exists — which is exactly the 0-of-7 symptom.
//
// The API key never leaves the platform: this runs edge-side and returns a
// projection, never the raw response.
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  const key = Deno.env.get("TELNYX_API_KEY");
  if (!key) return Response.json({ error: "no_api_key" }, { status: 500 });

  const url = new URL(req.url);
  const id = url.searchParams.get("connection_id");
  if (!id || !/^\d{6,30}$/.test(id)) {
    return Response.json({ error: "connection_id required (digits)" }, { status: 400 });
  }
  const r = await fetch(`https://api.telnyx.com/v2/credential_connections/${id}`, {
    headers: { Authorization: `Bearer ${key}` },
  });
  const j = await r.json().catch(() => ({}));
  const d = (j as { data?: Record<string, unknown> }).data ?? {};
  const outbound = (d.outbound ?? null) as Record<string, unknown> | null;
  return Response.json({
    http: r.status,
    connection_id: d.id ?? null,
    active: d.active ?? null,
    // The two places the profile could live. Docs say `outbound.*`.
    outbound_voice_profile_id_top_level: d.outbound_voice_profile_id ?? null,
    outbound_voice_profile_id_nested: outbound?.outbound_voice_profile_id ?? null,
    outbound_block_keys: outbound ? Object.keys(outbound) : null,
    ios_push_credential_id: d.ios_push_credential_id ?? null,
    sip_uri_calling_preference: d.sip_uri_calling_preference ?? null,
  });
});
