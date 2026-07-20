// Operator-only: dump SMSPool's raw service/country lists so unmapped catalog
// entries can be matched to their SMSPool ids. CRON_SECRET-gated, read-only.

import { handleCors, json } from "../_shared/cors.ts";
import { listServices, listCountries } from "../_shared/smspool.ts";

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
  const s = await listServices();
  return json({ count: s.length, services: s });
});
