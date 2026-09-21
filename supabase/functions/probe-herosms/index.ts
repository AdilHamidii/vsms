// probe-herosms — read-only diagnostic for HeroSMS's UNDOCUMENTED
// deliverability API. Cron-secret gated. Buys nothing and writes nothing.
//
// 🔴 WHY THIS EXISTS. HeroSMS publishes per-country and per-OPERATOR success
// rates on its own website (hero-sms.com/statistics) and documents none of it:
// `/api/v1/statistics`, `/stats`, `/conversion` and `/analytics` all 404, the
// published docs page is a client-rendered SPA listing no such endpoint, and
// the official docs repo mentions no metric of any kind. The two real paths
// below were recovered from the site's own page bundle on 2026-09-21 and
// confirmed live (401 unauthenticated, while `/api/v1/stats` alone 404s — so
// they are real routes, not a wildcard).
//
// This matters because the operator endpoint is something 5sim has no
// equivalent of. 5sim's `rate720` is per POOL; HeroSMS returns a success rate
// per OPERATOR, and with `operatorCodes=1` it names them in API form — the
// same form `routes.herosms_real_operators` stores. We currently pin every
// real carrier on a route blind, with no idea which of them delivers.
//
// 🔴 THE WINDOW IS 12 OR 24 HOURS AND THAT IS THE TRAP THIS REPO ALREADY FELL
// INTO. `pool_rate_pct` was 5sim's `rate24` until 2026-08-05 and "misled users
// in both directions": median |rate24 - rate720| is 9.6 points and 16.6% of
// pools differ by 30+ points. A 24h rate on a thin pool is noise wearing two
// decimal places. The mitigation is `successCount`, which is a SAMPLE-SIZE
// floor and not a rate filter — low <50, medium >=50, high >=500,
// very_high >=1000 successful activations. Anything below `high` must be
// treated as unrated. Never wire this into steering without that floor.
//
// ⚠️ Undocumented means unstable: an empty or failed response must read as
// "unrated", NEVER as "delivers nothing". A published 0% already sorts below
// unrated in `rankedUntestedKey`, and the same rule has to hold here.
//
// Query:
//   ?service=tg[&interval=24][&successCount=very_high][&country=<id>]
//   service     HeroSMS service CODE (`services.herosms_code`), not our id
//   country     numeric HeroSMS country id; when present the per-OPERATOR
//               endpoint is called too
//   raw=1       include the untouched response body, which is the finding
import { corsHeaders } from "../_shared/cors.ts";

const BASE = "https://hero-sms.com/api/v1";
const TIMEOUT_MS = 20_000;

/** Deliberately calls HeroSMS directly rather than through `_shared/herosms.ts`,
 *  so the RAW body is captured — the point of a probe is the text the adapter
 *  would otherwise normalise away. */
async function call(path: string, params: Record<string, string>) {
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url.toString(), {
      signal: ctl.signal,
      headers: {
        // Not `?api_key=` (that is the legacy handler_api side) and not
        // Bearer. Every wrong scheme returns {"title":"Unauthenticated."},
        // which is the SAME body an unknown route returns after auth — so a
        // wrong header reads exactly like "this API does not exist".
        authorization: `ApiKey ${Deno.env.get("HEROSMS_API_KEY") ?? ""}`,
        accept: "application/json, text/plain, */*",
      },
    });
    const body = (await res.text()).trim();
    return { url: url.toString().replace(/ApiKey [^&]*/, "***"), status: res.status, body };
  } catch (e) {
    return { url: url.toString(), status: 0, body: `fetch failed: ${String(e)}` };
  } finally {
    clearTimeout(timer);
  }
}

function summarise(body: string) {
  try {
    const parsed = JSON.parse(body);
    const rows = Array.isArray(parsed?.data) ? parsed.data : null;
    if (!rows) return { shape: Object.keys(parsed ?? {}), rows: null };
    return {
      count: rows.length,
      // The field names ARE the finding — everything else is downstream of
      // knowing what this returns.
      fields: rows.length ? Object.keys(rows[0]) : [],
      sample: rows.slice(0, 8),
    };
  } catch {
    return { unparseable: body.slice(0, 200) };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const q = new URL(req.url).searchParams;
  const service = q.get("service") ?? "tg";
  const interval = q.get("interval") ?? "24";
  const successCount = q.get("successCount") ?? "very_high";
  const country = q.get("country");
  const raw = q.get("raw") === "1";

  const out: Record<string, unknown> = { service, interval, successCount };

  // CONTROL. Without this a 401 on the stats endpoint is ambiguous between
  // "our key is wrong" and "this endpoint does not accept key auth at all",
  // and those have opposite consequences. `activations/offers` is a route the
  // production sync uses every hour, so a 200 here proves the key and the
  // header scheme are good in the very same request.
  const control = await call("/activations/offers", { services: service });
  out.control_offers = {
    status: control.status,
    ok: control.status === 200,
    note: "200 here means the ApiKey header is valid; compare with the stats status below",
  };

  const countries = await call("/stats/deliverability", {
    service,
    interval,
    successCount,
  });
  out.deliverability = {
    url: countries.url,
    status: countries.status,
    ...summarise(countries.body),
    ...(raw ? { raw: countries.body.slice(0, 4000) } : {}),
  };

  if (country) {
    const ops = await call(
      `/stats/deliverability/services/${encodeURIComponent(service)}` +
        `/countries/${encodeURIComponent(country)}/operators`,
      { interval, operatorCodes: "1" },
    );
    out.operators = {
      url: ops.url,
      status: ops.status,
      ...summarise(ops.body),
      ...(raw ? { raw: ops.body.slice(0, 4000) } : {}),
    };
  }

  return new Response(JSON.stringify(out, null, 2), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
