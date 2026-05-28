// Called by pg_cron every minute. Scans all 'waiting' orders, polls SMSPVA
// for incoming SMS, persists OTPs, dispatches push notifications to the
// user's devices.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getSms } from "../_shared/smspva.ts";
import { sendPush } from "../_shared/apns.ts";

async function validateCronSecret(req: Request): Promise<boolean> {
  const header = req.headers.get("x-cron-secret");
  if (!header) return false;
  const { data, error } = await admin()
    .schema("vault" as never)
    .from("decrypted_secrets" as never)
    .select("decrypted_secret")
    .eq("name", "cron_secret")
    .maybeSingle();
  if (error) {
    console.error("vault read failed:", error);
    return false;
  }
  return header === (data as { decrypted_secret?: string } | null)?.decrypted_secret;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;

  if (!(await validateCronSecret(req))) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();

  // Auto-expire anything past its window before polling.
  const { data: expiredCandidates } = await sb
    .from("orders")
    .select("id")
    .eq("status", "waiting")
    .lt("expires_at", new Date().toISOString());

  for (const row of expiredCandidates ?? []) {
    await sb.rpc("expire_order", { p_order: row.id });
  }

  // Active orders to poll.
  const { data: pending, error: pErr } = await sb
    .from("orders")
    .select(`
      id, user_id, smspva_id,
      service:service_id ( id, smspva_code, name ),
      country:country_id ( smspva_code )
    `)
    .eq("status", "waiting")
    .not("smspva_id", "is", null);

  if (pErr) return json({ error: "list_failed", detail: pErr.message }, { status: 500 });

  let polled = 0, arrived = 0, pushSent = 0;

  for (const o of pending ?? []) {
    polled++;
    const service = o.service as { smspva_code: string; name: string };
    const country = o.country as { smspva_code: string };

    let resp;
    try {
      resp = await getSms(country.smspva_code, service.smspva_code, o.smspva_id!);
    } catch (e) {
      console.error("SMSPVA poll failed for order", o.id, e);
      continue;
    }

    if ((resp.response === "1" || resp.response === "4") && resp.sms) {
      arrived++;
      const { error: uErr } = await sb
        .from("orders")
        .update({
          status: "received",
          otp: resp.sms,
          raw_message: resp.text ?? null,
          arrived_at: new Date().toISOString(),
          closed_at: new Date().toISOString(),
        })
        .eq("id", o.id)
        .eq("status", "waiting");

      if (uErr) {
        console.error("update failed for order", o.id, uErr);
        continue;
      }

      // Push to all of this user's devices.
      const { data: devices } = await sb
        .from("push_devices")
        .select("token, environment, bundle_id")
        .eq("user_id", o.user_id);

      for (const d of devices ?? []) {
        try {
          const r = await sendPush(d.token, {
            alertTitle: `${service.name} code arrived`,
            alertBody: `Your code is ${resp.sms}`,
            customData: { orderId: o.id, otp: resp.sms },
          }, d.environment as "sandbox" | "production");
          if (r.ok) pushSent++;
          else console.error("APNs status", r.status, r.body);
        } catch (e) {
          console.error("APNs send failed:", e);
        }
      }
    }
  }

  return json({ polled, arrived, pushSent });
});
