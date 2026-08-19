// probe-5sim — a paid, one-shot diagnostic. Cron-secret gated.
//
// Two questions the docs cannot answer and one live probe on 2026-08-03 only
// half-answered, both decided by ARITHMETIC on `user/profile.balance` read
// before and after each step (never by trusting a 200 or a status string):
//
//   A. CANCEL REFUNDS?  Buy the cheapest pool, cancel, compare balance.
//      cancel-order assumes yes on the strength of one $0.008 probe; ~60% of
//      numbered orders are cancelled, so if this is ever wrong we bleed float
//      on every one.
//   B. REUSE — cost + window.  Buy with `reuse=1`, cancel (or expire), then
//      call `user/reuse/{product}/{number}` and compare balance. If reuse is
//      free or near-free it rescues "cancelled just before the code" for less
//      than a fresh number. Docs give the endpoint and three error strings
//      ("reuse not possible" / "reuse false" / "reuse expired") and are
//      silent on cost.
//
// Deliberately calls 5sim directly rather than through the adapter, so the
// RAW response text is captured — that text is the finding.
//
// Query: ?mode=cancel | ?mode=reuse   (one experiment per invocation)
//        &country=england&product=snapchat&operator=virtual63
import { corsHeaders } from "../_shared/cors.ts";

const BASE = "https://5sim.net/v1";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  const key = Deno.env.get("FIVESIM_API_KEY") ?? Deno.env.get("FIVESIM_KEY");
  if (!key) return Response.json({ error: "no_api_key" }, { status: 500 });

  const u = new URL(req.url);
  const mode = u.searchParams.get("mode") ?? "cancel";
  const country = u.searchParams.get("country") ?? "england";
  const product = u.searchParams.get("product") ?? "snapchat";
  const operator = u.searchParams.get("operator") ?? "any";
  if (!/^[a-z0-9_-]+$/i.test(country + product + operator.replace(/,/g, ""))) {
    return Response.json({ error: "bad params" }, { status: 400 });
  }

  const H = { Authorization: `Bearer ${key}`, Accept: "application/json" };
  const log: Record<string, unknown>[] = [];
  const at = () => new Date().toISOString();

  async function raw(path: string) {
    const r = await fetch(`${BASE}/${path}`, { headers: H });
    const text = await r.text();
    let json: unknown = null;
    try { json = JSON.parse(text); } catch { /* keep text */ }
    return { status: r.status, text: text.slice(0, 400), json };
  }
  async function balance(): Promise<number | null> {
    const p = await raw("user/profile");
    const b = (p.json as { balance?: number } | null)?.balance;
    return typeof b === "number" ? b : null;
  }
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  const b0 = await balance();
  log.push({ step: "balance_start", at: at(), balance: b0 });

  // ── BUY ──────────────────────────────────────────────────────────────────
  const buyPath = `user/buy/activation/${country}/${operator}/${product}` +
    (mode === "reuse" ? "?reuse=1" : "");
  const buy = await raw(buyPath);
  log.push({ step: "buy", at: at(), path: buyPath, http: buy.status, body: buy.text });
  const order = buy.json as { id?: number; phone?: string; price?: number; status?: string } | null;
  if (buy.status !== 200 || !order?.id) {
    return Response.json({ mode, ok: false, reason: "buy_failed", log });
  }
  const b1 = await balance();
  log.push({ step: "balance_after_buy", at: at(), balance: b1,
             charged: b0 != null && b1 != null ? +(b0 - b1).toFixed(4) : null,
             quoted_price: order.price });

  // ── CANCEL ───────────────────────────────────────────────────────────────
  // 5sim may refuse an instant cancel; wait a little like a real user would.
  await sleep(4000);
  const cancel = await raw(`user/cancel/${order.id}`);
  log.push({ step: "cancel", at: at(), http: cancel.status, body: cancel.text });
  await sleep(2500);
  const b2 = await balance();
  log.push({ step: "balance_after_cancel", at: at(), balance: b2,
             refunded: b1 != null && b2 != null ? +(b2 - b1).toFixed(4) : null,
             fully_refunded: b0 != null && b2 != null ? Math.abs(b2 - b0) < 0.0005 : null });

  if (mode !== "reuse") {
    return Response.json({ mode, ok: true,
      verdict: {
        charged: b0 != null && b1 != null ? +(b0 - b1).toFixed(4) : null,
        refunded_on_cancel: b1 != null && b2 != null ? +(b2 - b1).toFixed(4) : null,
        net_cost: b0 != null && b2 != null ? +(b0 - b2).toFixed(4) : null,
      }, log });
  }

  // ── REUSE ────────────────────────────────────────────────────────────────
  const phone = String(order.phone ?? "").replace(/^\+/, "");
  const reuse = await raw(`user/reuse/${product}/${phone}`);
  log.push({ step: "reuse", at: at(), path: `user/reuse/${product}/${phone}`,
             http: reuse.status, body: reuse.text });
  await sleep(2500);
  const b3 = await balance();
  log.push({ step: "balance_after_reuse", at: at(), balance: b3,
             reuse_charged: b2 != null && b3 != null ? +(b2 - b3).toFixed(4) : null });

  // If reuse produced an order, cancel it too so nothing is left running.
  const reused = reuse.json as { id?: number } | null;
  if (reuse.status === 200 && reused?.id) {
    await sleep(4000);
    const c2 = await raw(`user/cancel/${reused.id}`);
    log.push({ step: "cancel_reused", at: at(), http: c2.status, body: c2.text });
    await sleep(2500);
    const b4 = await balance();
    log.push({ step: "balance_final", at: at(), balance: b4,
               net_cost_total: b0 != null && b4 != null ? +(b0 - b4).toFixed(4) : null });
  }

  return Response.json({ mode, ok: true,
    verdict: {
      original_charged: b0 != null && b1 != null ? +(b0 - b1).toFixed(4) : null,
      original_refunded_on_cancel: b1 != null && b2 != null ? +(b2 - b1).toFixed(4) : null,
      reuse_http: reuse.status, reuse_body: reuse.text,
      reuse_charged: b2 != null && b3 != null ? +(b2 - b3).toFixed(4) : null,
    }, log });
});
