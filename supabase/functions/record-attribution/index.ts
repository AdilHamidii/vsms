// Apple Search Ads attribution — the join that did not exist.
//
// The app spends on ASA daily. ASA reports installs; `iap_receipts` records
// purchases; nothing has ever connected the two, so "which campaign/keyword
// produced a PAYING user" has been unanswerable for the life of the product.
//
// The client hands us the opaque AdServices token from `AAAttribution
// .attributionToken()`. We resolve it against Apple and store the result keyed
// on the user, so `attribution_summary()` can join it to Production receipts.
//
// Two behaviours of Apple's endpoint that shape this function:
//   * the token is the RAW BODY, `Content-Type: text/plain`, no auth header,
//     no JSON wrapper.
//   * it is **not resolvable immediately**. Apple documents a delay of a few
//     seconds after install; the endpoint answers 404 until then. A 404 is
//     therefore ambiguous — it means either "organic / not attributed" or
//     "ask again". We retry once, then record what we have.
//
// ⚠️ This endpoint NEVER fails the client for Apple's sake. A slow or dead
// api-adservices.apple.com is a measurement gap, not a reason to hand an error
// to an app that is mid-cold-launch. The client is fire-and-forget and only
// marks the install submitted on a 2xx — so a 200 with `attributed: false`
// after a real outage is the one failure mode worth knowing about, and it is
// logged loudly rather than hidden.
import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

const APPLE_URL = "https://api-adservices.apple.com/api/v1/";
const RETRY_DELAY_MS = 3_000;

interface Body {
  token: string;
}

/** Apple's documented payload. Every field but `attribution` is absent when it is false. */
interface AppleAttribution {
  attribution: boolean;
  orgId?: number;
  campaignId?: number;
  conversionType?: string;
  adGroupId?: number;
  countryOrRegion?: string;
  keywordId?: number;
  adId?: number;
  claimType?: string;
}

type Resolution =
  | { kind: "resolved"; payload: AppleAttribution }
  | { kind: "not_attributed" }
  | { kind: "unavailable"; detail: string };

async function resolve(token: string): Promise<Resolution> {
  let res: Response;
  try {
    res = await fetch(APPLE_URL, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: token,
    });
  } catch (e) {
    return { kind: "unavailable", detail: `fetch_failed: ${e}` };
  }

  if (res.status === 404) {
    // Ambiguous: organic, or simply too soon. Caller decides whether to retry.
    await res.body?.cancel();
    return { kind: "not_attributed" };
  }
  if (!res.ok) {
    const detail = `http_${res.status}: ${(await res.text()).slice(0, 200)}`;
    return { kind: "unavailable", detail };
  }

  try {
    const payload = await res.json() as AppleAttribution;
    if (typeof payload?.attribution !== "boolean") {
      // Never guess at a shape we did not expect — record it raw and log it,
      // the same rule the email line's status mapping follows.
      console.error(`record-attribution UNEXPECTED_SHAPE: ${JSON.stringify(payload).slice(0, 400)}`);
      return { kind: "unavailable", detail: "unexpected_shape" };
    }
    return { kind: "resolved", payload };
  } catch (e) {
    return { kind: "unavailable", detail: `bad_json: ${e}` };
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
  const token = typeof body?.token === "string" ? body.token.trim() : "";
  if (!token) return json({ error: "missing_token" }, { status: 400 });

  let out = await resolve(token);
  if (out.kind === "not_attributed") {
    // The one retry Apple's propagation delay asks for. A second 404 is taken
    // at face value: this install is organic.
    await new Promise((r) => setTimeout(r, RETRY_DELAY_MS));
    out = await resolve(token);
  }

  if (out.kind === "unavailable") {
    // Loud, because a run of these means the campaign→revenue join is going
    // silently empty while ads keep spending.
    console.error(`record-attribution APPLE_UNAVAILABLE user=${userId}: ${out.detail}`);
    return json({ ok: true, attributed: null });
  }

  const p = out.kind === "resolved" ? out.payload : null;
  const attributed = p?.attribution === true;

  const sb = admin();
  const { error } = await sb
    .from("install_attributions")
    .upsert({
      user_id: userId,
      attributed,
      org_id: attributed ? p?.orgId ?? null : null,
      campaign_id: attributed ? p?.campaignId ?? null : null,
      ad_group_id: attributed ? p?.adGroupId ?? null : null,
      keyword_id: attributed ? p?.keywordId ?? null : null,
      ad_id: attributed ? p?.adId ?? null : null,
      conversion_type: attributed ? p?.conversionType ?? null : null,
      claim_type: attributed ? p?.claimType ?? null : null,
      country_or_region: attributed ? p?.countryOrRegion ?? null : null,
      raw: p,
      recorded_at: new Date().toISOString(),
    }, { onConflict: "user_id" });

  if (error) {
    console.error(`record-attribution PERSIST_FAILED user=${userId}: ${error.message}`);
    return json({ error: "persist_failed", detail: error.message }, { status: 500 });
  }

  console.log(
    `record-attribution OK user=${userId} attributed=${attributed}` +
    (attributed ? ` campaign=${p?.campaignId} keyword=${p?.keywordId} ad=${p?.adId}` : ""),
  );
  return json({ ok: true, attributed });
});
