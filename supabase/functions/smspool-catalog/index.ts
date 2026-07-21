// Operator-only: dump SMSPool's raw service/country lists so unmapped catalog
// entries can be matched to their SMSPool ids. CRON_SECRET-gated, read-only.

import { handleCors, json } from "../_shared/cors.ts";
import { listServices, listCountries, allStock, validPools, poolSuccessRate } from "../_shared/smspool.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  const h = req.headers.get("x-cron-secret");
  const e = Deno.env.get("CRON_SECRET");
  if (!h || !e || h !== e) return json({ error: "unauthorized" }, { status: 401 });

  const url = new URL(req.url);
  const want = url.searchParams.get("type") ?? "services";
  if (want === "countries") {
    const c = await listCountries();
    return json({ count: c.length, countries: c });
  }
  if (want === "stock") {
    const t0 = Date.now();
    const rows = await allStock();
    return json({
      count: Array.isArray(rows) ? rows.length : -1,
      ms: Date.now() - t0,
      sample: Array.isArray(rows) ? rows.slice(0, 3) : rows,
    });
  }
  if (want === "esim") {
    const tx = url.searchParams.get("tx") ?? "";
    const resp = await fetch("https://api.smspool.net/esim/profile", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
      body: new URLSearchParams({ key: Deno.env.get("SMSPOOL_API_KEY") ?? "", transactionId: tx }),
    });
    const raw = await resp.text();
    return json({ status: resp.status, raw: raw.slice(0, 900) });
  }
  if (want === "pools") {
    const svc = url.searchParams.get("service") ?? "";
    const cty = url.searchParams.get("country") ?? "";
    // raw passthrough to see exactly what SMSPool returns
    const rawResp = await fetch("https://api.smspool.net/pool/retrieve_valid", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
      body: new URLSearchParams({ key: Deno.env.get("SMSPOOL_API_KEY") ?? "", service: svc, country: cty }),
    });
    const rawBody = (await rawResp.text()).slice(0, 400);
    const pools = await validPools(svc, cty);
    if (url.searchParams.get("raw") === "1") {
      return json({ status: rawResp.status, body: rawBody });
    }
    const rates = [];
    for (const p of pools) rates.push({ pool: p.pool, name: p.name, price: p.price, ...(await poolSuccessRate(cty, svc, p.pool)) });
    return json({ pools, rates });
  }
  const s = await listServices();
  return json({ count: s.length, services: s });
});
