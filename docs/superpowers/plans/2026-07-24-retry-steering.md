# Retry Steering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user retries a failed SMS order, guarantee a number they haven't already tried and, where possible, a different carrier pool.

**Architecture:** All changes in `supabase/functions/create-order/index.ts` (Deno edge function). One new read (retry context) before `begin_order`; a pin-selection block before the provider loop; a redraw loop around `reserve()`. Every new path is best-effort and degrades to today's exact behavior on error. Spec: `docs/superpowers/specs/2026-07-24-retry-steering-design.md`.

**Tech Stack:** Deno / TypeScript, Supabase edge functions, SMSPVA v2 REST (via `_shared/smspva.ts` + `_shared/providers.ts`).

## Global Constraints

- **No test suite exists in this project** (per CLAUDE.md). Verification is: `deno check` (if the deno binary exists locally; otherwise skip), then deploy and **check resulting DB state** — never trust the deploy log alone.
- No new `{ error: ... }` literals — nothing may need a matching case in `Networking/APIError.swift`.
- No schema changes. `orders.smspool_pool` (operator that filled) and `orders.smspva_number` are the existing history columns this feature reads.
- Deploy command: `supabase functions deploy create-order` (JWT-verified group — NO `--no-verify-jwt`).
- All `supabase db query --linked` / deploy commands must run from `/Users/adyl/Desktop/VirtualSIM` (the linked checkout); code edits happen in the worktree.
- Premium orders must never end up unpinned or on a `Donor*` pool.

---

### Task 1: Retry context + fresh-number redraw

**Files:**
- Modify: `supabase/functions/create-order/index.ts` (imports ~line 3; after the `codes` block ~line 165; the `reserve` call ~line 274)

**Interfaces:**
- Produces: `recentNumbers: Set<string>` (numbers this user drew for this service, last 60 min) and `triedOperators: Set<string>` (operators on canceled orders for this route, last 15 min) — Task 2 consumes `triedOperators`.

- [ ] **Step 1: Add the retry-context read.** Insert after the `const codes: RouteCodes = {...};` block and before the `providerOrder(codes)` call:

```ts
// ── Retry steering context. A retry is the one moment we KNOW the previous
// number/pool failed this user — use that knowledge instead of re-selling it.
// Measured 2026-07-24: one user's 9 Betano attempts drew only 6 distinct
// numbers, every attempt pinned to the same carrier. Best-effort: on any
// error both sets stay empty and behavior is exactly today's.
const recentNumbers = new Set<string>();
const triedOperators = new Set<string>();
try {
  const { data: recent } = await sb
    .from("orders")
    .select("smspva_number, smspool_pool, country_id, provider, status, closed_at")
    .eq("user_id", userId)
    .eq("service_id", service.id)
    .gte("created_at", new Date(Date.now() - 60 * 60 * 1000).toISOString());
  for (const r of recent ?? []) {
    if (r.smspva_number) recentNumbers.add(r.smspva_number as string);
    if (
      r.provider === "smspva" && r.smspool_pool && r.status === "canceled" &&
      r.country_id === country.id && r.closed_at &&
      Date.now() - new Date(r.closed_at as string).getTime() <= 15 * 60 * 1000
    ) triedOperators.add(r.smspool_pool as string);
  }
} catch (e) {
  console.warn("retry-context read failed (ignored):", e);
}
```

- [ ] **Step 2: Wrap `reserve()` in the redraw loop.** Replace the single line `const res = await reserve(p, codes, maxCostUsd, pin, tier === "premium");` with:

```ts
    // Fresh-number guarantee: SMSPVA re-issues a just-canceled number to the
    // same buyer. If the fill matches a number this user already drew for
    // this service in the last hour, release it and draw again — at most 3
    // draws. A still-duplicate final draw is kept: a repeat number beats no
    // number. release() never throws (logged internally), and only a
    // SUCCESSFUL duplicate fill re-enters the loop — reserve errors take the
    // existing error path unchanged.
    let res = await reserve(p, codes, maxCostUsd, pin, tier === "premium");
    for (
      let redraw = 0;
      redraw < 2 && res.ok && res.number && recentNumbers.has(res.number);
      redraw++
    ) {
      console.warn(`duplicate number re-issued (${res.number}) — redrawing svc=${service.id} cty=${country.id}`);
      if (res.orderId) await release(p, res.orderId);
      res = await reserve(p, codes, maxCostUsd, pin, tier === "premium");
    }
```

Note: `res` becomes `let`; all downstream uses (`res.ok`, `res.costUsd`, …) are unchanged. Known acceptable quirk: a release refund can land between the next draw's balance-bracket reads, leaving that draw's `costUsd` undefined — the existing `b0 > b1` guard already treats that as "no measurement" and `usedCostUsd` falls back to `liveCost`.

- [ ] **Step 3: Type-check if deno is available**

Run: `which deno && deno check supabase/functions/create-order/index.ts || echo "deno absent — verified at deploy+E2E instead"`
Expected: `Check` output with no errors, or the fallback message.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/create-order/index.ts
git commit -m "feat(create-order): fresh-number guarantee on retry"
```

---

### Task 2: Operator rotation

**Files:**
- Modify: `supabase/functions/create-order/index.ts` (import line ~3; after the `standardCarrier` computation ~line 240; the premium `liveCost` branch ~line 253; the `pin` selection ~line 271)

**Interfaces:**
- Consumes: `triedOperators` (Task 1), `maxCostUsd`, `standardCarrier`, `route.smspva_operator`, `route.smspva_operator_cents`.
- Produces: `smspvaPin: string | null` (the pin the provider loop uses), `rotatedPinUsd: number | null` (live USD of a rotated pin, for the premium margin pre-check).

- [ ] **Step 1: Add the smspva.ts import** alongside the existing imports at the top:

```ts
import { getCountryPrices, isOk } from "../_shared/smspva.ts";
```

- [ ] **Step 2: Add the rotation block** immediately after the `const standardCarrier = ...;` statement:

```ts
  // ── Operator rotation. If the pin we'd use is one this user just failed
  // on, pick a different real carrier from the live per-operator price map
  // (getCountryPrices → po). The alternate must be untried, non-Donor (the
  // anonymized VoIP pools strict services reject), and inside the same
  // margin ceiling as any other fill. Fallbacks: standard → unpinned (at
  // least a different pool than the one that just failed), premium → keep
  // the route pin (the buyer paid for THAT real-SIM pool; never downgrade).
  let smspvaPin: string | null = tier === "premium"
    ? route.smspva_operator as string
    : standardCarrier;
  let rotatedPinUsd: number | null = null;
  if (
    smspvaPin != null && triedOperators.has(smspvaPin) &&
    country.smspva_code && service.smspva_code
  ) {
    try {
      const pr = await getCountryPrices(country.smspva_code as string);
      const row = isOk(pr)
        ? pr.data.find((x) => x.s === service.smspva_code)
        : null;
      const alt = Object.entries(row?.po ?? {})
        .map(([op, usd]) => ({ op, usd: parseFloat(usd) }))
        .filter(({ op, usd }) =>
          !triedOperators.has(op) &&
          !op.toLowerCase().startsWith("donor") &&
          Number.isFinite(usd) && usd <= maxCostUsd)
        .sort((a, b) => a.usd - b.usd)[0] ?? null;
      if (alt) {
        console.warn(`operator rotation: ${smspvaPin} already failed this user — pinning ${alt.op} svc=${service.id} cty=${country.id}`);
        smspvaPin = alt.op;
        rotatedPinUsd = alt.usd;
      } else if (tier !== "premium") {
        console.warn(`operator rotation: ${smspvaPin} already failed this user, no eligible alternate — unpinned svc=${service.id} cty=${country.id}`);
        smspvaPin = null;
      }
    } catch (e) {
      console.warn("operator rotation lookup failed (ignored):", e);
    }
  }
```

- [ ] **Step 3: Use the rotated price in the premium margin pre-check.** Replace:

```ts
    if (tier === "premium" && route.smspva_operator_cents != null) {
      const cachedOp = (route.smspva_operator_cents as number) / 100;
      const liveBase = p === "smspva" ? await livePriceUsd(p, codes) : null;
      liveCost = liveBase != null ? Math.max(cachedOp, liveBase) : cachedOp;
```

with:

```ts
    if (tier === "premium" && (rotatedPinUsd != null || route.smspva_operator_cents != null)) {
      const opUsd = rotatedPinUsd ?? (route.smspva_operator_cents as number) / 100;
      const liveBase = p === "smspva" ? await livePriceUsd(p, codes) : null;
      liveCost = liveBase != null ? Math.max(opUsd, liveBase) : opUsd;
```

- [ ] **Step 4: Route the pin through the selection.** Replace:

```ts
    const pin = p === "smspva"
      ? (tier === "premium" ? route.smspva_operator as string : standardCarrier)
      : route.smspool_pool;
```

with:

```ts
    // smspvaPin already encodes the tier rule (premium → route carrier,
    // standard → opportunistic) plus any rotation away from a pool this
    // user just failed on.
    const pin = p === "smspva" ? smspvaPin : route.smspool_pool;
```

- [ ] **Step 5: Type-check if deno is available**

Run: `which deno && deno check supabase/functions/create-order/index.ts || echo "deno absent — verified at deploy+E2E instead"`
Expected: no type errors, or the fallback message.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/create-order/index.ts
git commit -m "feat(create-order): rotate carrier pin away from a pool the user just failed on"
```

---

### Task 3: Deploy + live E2E verification

**Files:** none (operations only). Run every command from `/Users/adyl/Desktop/VirtualSIM` unless noted; deploy from the worktree so the new code ships.

- [ ] **Step 1: Deploy from the worktree**

```bash
cd /Users/adyl/Desktop/VirtualSIM/.claude/worktrees/retry-steering
supabase functions deploy create-order
```
Expected: `Deployed Functions on project enugzltysdmjzavisloy: create-order`.

- [ ] **Step 2: Get keys and create a disposable user**

```bash
cd /Users/adyl/Desktop/VirtualSIM
supabase projects api-keys --project-ref enugzltysdmjzavisloy   # note anon + service_role
BASE=https://enugzltysdmjzavisloy.supabase.co
curl -s -X POST "$BASE/auth/v1/admin/users" \
  -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" \
  -H "Content-Type: application/json" \
  -d '{"email":"e2e-retry-2026-07-24@example.com","password":"<random-32>","email_confirm":true}'
curl -s -X POST "$BASE/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"email":"e2e-retry-2026-07-24@example.com","password":"<random-32>"}'
# → access_token = $TOK ; user id = $UID
```
Expected: JSON user object, then a JSON with `access_token`.

- [ ] **Step 3: Fund the wallet** (signup trigger creates the wallet; top it up to cover two cheap orders):

```sql
select public.wallet_credit(p_user := '<UID>', p_amount := 10,
                            p_reason := 'adjustment', p_order := null);
```
Expected: balance function returns; verify `select balance from wallets where user_id='<UID>'` ≥ 10.

- [ ] **Step 4: Pick the cheapest active SMSPVA route with an operator**

```sql
select r.service_id, r.country_id, r.retail_credits, r.smspva_operator
from routes r where r.provider='smspva' and r.status='active'
  and r.smspva_operator is not null and r.retail_credits <= 3
order by r.retail_credits asc limit 5;
```
Pick one (prefer a mainstream service). Note `service_id`/`country_id`.

- [ ] **Step 5: Order → cancel → re-order**

```bash
curl -s -X POST "$BASE/functions/v1/create-order" -H "apikey: $ANON" \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"service_id":"<SVC>","country_id":"<CTY>"}'          # order 1
curl -s -X POST "$BASE/functions/v1/cancel-order" -H "apikey: $ANON" \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"order_id":"<ORDER1>"}'
curl -s -X POST "$BASE/functions/v1/create-order" -H "apikey: $ANON" \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"service_id":"<SVC>","country_id":"<CTY>"}'          # order 2 (the retry)
```
Expected: two order JSONs; order 2's `smspva_number` **differs** from order 1's, and its `smspool_pool` differs from order 1's (or is null = unpinned fallback).

- [ ] **Step 6: Cancel order 2 and verify DB state**

```sql
select id, status, smspva_number, smspool_pool, cost_credits, closed_at
from orders where user_id='<UID>' order by created_at;
select type, amount, order_id from wallet_transactions where user_id='<UID>' order by created_at;
select balance from wallets where user_id='<UID>';
```
Expected: both orders `canceled`; distinct `smspva_number`; a spend+refund pair per order; balance back to 10. Also check the function logs / `console.warn` lines in the dashboard for `duplicate number re-issued` or `operator rotation` if they fired (they fire only when SMSPVA actually re-issued — absence is fine).

- [ ] **Step 7: Clean up the disposable user**

```bash
curl -s -X DELETE "$BASE/auth/v1/admin/users/<UID>" \
  -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE"
```
Expected: 200. (Cascades per existing FK rules — same pattern as the 2026-07-22 E2E.)

- [ ] **Step 8: Commit the plan checkboxes + push + draft PR**

```bash
git add -A && git commit -m "docs: retry-steering plan executed (live E2E verified)"
git push -u origin worktree-retry-steering
gh pr create --draft --title "Retry steering: fresh numbers + operator rotation on SMS retries" --body "..."
```
