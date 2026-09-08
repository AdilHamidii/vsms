# Second-Code Resend Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop calling `finish` on a delivered 5sim order for five minutes, so a second SMS to the same number reaches the user instead of being foreclosed.

**Architecture:** On code arrival, if the 5sim pool is on 5sim's published multi-SMS list, write `orders.resend_watch_until = now() + 5 min` and skip `markSuccess`. A new sweep in `poll-active-orders` — placed *before* the pending loop — re-polls those orders, promotes any newer code onto `orders.otp`, appends it to `orders.otp_history`, and resets the clock. When the window lapses the sweep makes the deferred `markSuccess` call and nulls the column. No new `order_status` value; no money path.

**Tech Stack:** Deno / TypeScript edge functions on Supabase, Postgres migrations applied via `supabase db query --linked --file`, SwiftUI client (iOS 18.0 floor), verification by hand-written assertion scripts (there is no test suite).

**Spec:** `docs/superpowers/specs/2026-09-08-second-code-window-design.md`

## Global Constraints

- **5sim only.** HeroSMS's `STATUS_RETRY` is a different verb and is out of scope.
- **No new `order_status` value.** The iOS `OrderStatus` enum (`VirtualSIM/Components/Pills.swift`) is a plain String enum with no unknown case; an unrecognised status throws on decode and breaks the Orders tab for every shipped build.
- **No money path.** No `wallet_*` call, no refund, no new `wallet_reason`. A second code is free within the original activation.
- **No change to `orders.expires_at`.** The expiry sweep selects `status='waiting'` only.
- **Eligibility fails closed.** Unknown operator, null operator, or non-5sim provider ⇒ no window.
- **`markSuccess` itself is not modified.** It is deferred by its callers.
- **The window is 5 minutes from the LAST SMS.** The clock restarts on every message. Copy must never count down from a fixed total.
- **Migration versions come from the DB, not the clock:** `select max(version) from supabase_migrations.schema_migrations` — currently `20260908220000`. Two sessions picking the same timestamp is a real failure here.
- **Never `Text("literal")`** in the client. Every user-visible string goes through the string catalog with all six locales.
- **`supabase db push` is broken.** Apply with `supabase db query --linked --file <path>`, then insert the `schema_migrations` row and **SELECT it back**.
- **After touching `_shared/`, redeploy every consumer**, not just the function you edited.

---

### Task 1: `supportsResend()` in the 5sim adapter

**Files:**
- Modify: `supabase/functions/_shared/fivesim.ts` (append near the lifecycle helpers, after `ban` at ~line 375)
- Test: `scripts/verify-resend-eligibility.ts` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `export function supportsResend(country: string | null | undefined, operator: string | null | undefined): boolean`

- [ ] **Step 1: Write the failing test**

Create `scripts/verify-resend-eligibility.ts`. This repo verifies TypeScript with standalone assertion scripts (`scripts/verify-telnyx-signature.ts`, `scripts/verify-line-catalog-gate.ts`); follow that shape.

```ts
// Offline assertions for fivesim.supportsResend(). Run:
//   deno run --allow-read scripts/verify-resend-eligibility.ts
import { supportsResend } from "../supabase/functions/_shared/fivesim.ts";

let pass = 0, fail = 0;
function check(name: string, got: boolean, want: boolean) {
  if (got === want) { pass++; return; }
  fail++;
  console.error(`FAIL ${name}: got ${got}, want ${want}`);
}

// Unconditional pools from 5sim's published list.
for (const op of ["virtual2", "virtual21", "virtual26", "virtual34", "virtual36",
                  "virtual38", "virtual40", "virtual47", "virtual49", "virtual51",
                  "virtual52", "virtual53", "virtual54", "virtual58"]) {
  check(`${op}/usa`, supportsResend("usa", op), true);
  check(`${op}/england`, supportsResend("england", op), true);
}

// virtual8 is USA + Canada only; virtual12 is Canada only.
check("virtual8/usa", supportsResend("usa", "virtual8"), true);
check("virtual8/canada", supportsResend("canada", "virtual8"), true);
check("virtual8/england", supportsResend("england", "virtual8"), false);
check("virtual12/canada", supportsResend("canada", "virtual12"), true);
check("virtual12/usa", supportsResend("usa", "virtual12"), false);

// Pools carrying real traffic that are NOT on the list.
for (const op of ["virtual63", "virtual66", "virtual60", "virtual59",
                  "virtual61", "virtual65", "virtual4", "virtual28"]) {
  check(`${op}/usa is ineligible`, supportsResend("usa", op), false);
}

// Fails closed.
check("null operator", supportsResend("usa", null), false);
check("undefined operator", supportsResend("usa", undefined), false);
check("empty operator", supportsResend("usa", ""), false);
check("null country", supportsResend(null, "virtual51"), false);
check("unpinned", supportsResend("usa", "any"), false);
check("unknown pool", supportsResend("usa", "virtual999"), false);

// Case and whitespace are provider data, not user data, but normalise anyway.
check("uppercase", supportsResend("USA", "VIRTUAL51"), true);
check("padded", supportsResend(" usa ", " virtual51 "), true);

console.log(`${pass} passed, ${fail} failed`);
if (fail > 0) Deno.exit(1);
```

- [ ] **Step 2: Run it to verify it fails**

```bash
deno run --allow-read scripts/verify-resend-eligibility.ts
```

Expected: fails to compile — `The requested module '../supabase/functions/_shared/fivesim.ts' does not provide an export named 'supportsResend'`.

- [ ] **Step 3: Write the implementation**

Append to `supabase/functions/_shared/fivesim.ts`:

```ts
/** Pools 5sim says will deliver MORE THAN ONE SMS on the same activation.
 *
 *  Source: 5sim's own FAQ, "How do I receive verification message again?" —
 *  read 2026-09-08. Their first sentence is the other half of this and is why
 *  `finish` must be deferred rather than called on arrival:
 *
 *    "If you finish an order, then there is no way to request and receive SMS
 *     using the same number again."
 *
 *  ⚠️ THIS IS 5SIM'S CLAIM, NOT OUR MEASUREMENT. Nothing here has been proven
 *  by a second code actually arriving. The first one that does is the probe —
 *  see the `resend_promoted` log line in poll-active-orders. If second codes
 *  never land on a pool named here, this list is wrong, not the caller.
 *
 *  Deliberately NOT sourced from the route table: it is provider knowledge
 *  that changes when 5sim changes it, and a stale row would silently hold an
 *  activation open for nothing.
 */
const RESEND_POOLS_ANY_COUNTRY: ReadonlySet<string> = new Set([
  "virtual2", "virtual21", "virtual26", "virtual34", "virtual36", "virtual38",
  "virtual40", "virtual47", "virtual49", "virtual51", "virtual52", "virtual53",
  "virtual54", "virtual58",
]);

/** Pools the FAQ scopes to particular countries. `virtual8` is listed for USA
 *  and Canada, `virtual12` for Canada alone — so an England fill on virtual8
 *  is NOT covered, and treating it as covered would hold a number open for a
 *  message that never comes. */
const RESEND_POOLS_BY_COUNTRY: ReadonlyMap<string, ReadonlySet<string>> = new Map([
  ["virtual8", new Set(["usa", "canada"])],
  ["virtual12", new Set(["canada"])],
]);

/** Can this (country, pool) take a SECOND SMS on the same activation?
 *
 *  Fails CLOSED on anything unrecognised — a null operator (`operator_used` is
 *  nullable and means "not recorded", which is not the same as "eligible"),
 *  the unpinned sentinel "any", or a pool 5sim has not named. The cost of a
 *  false positive is a real one: we defer `finish`, hold the number, and the
 *  user is shown a countdown for a second code that cannot arrive.
 */
export function supportsResend(
  country: string | null | undefined,
  operator: string | null | undefined,
): boolean {
  const op = (operator ?? "").trim().toLowerCase();
  const cty = (country ?? "").trim().toLowerCase();
  if (!op || !cty || op === "any") return false;
  if (RESEND_POOLS_ANY_COUNTRY.has(op)) return true;
  return RESEND_POOLS_BY_COUNTRY.get(op)?.has(cty) ?? false;
}

/** How long we hold a delivered activation open waiting for another SMS.
 *
 *  5sim closes the order themselves 5 minutes after the LAST message, and the
 *  clock restarts on each one — so this is a per-message window, never a total
 *  budget. Matching their number exactly means our sweep and their auto-close
 *  agree; going longer would only produce a countdown that outlives the
 *  activation it describes. */
export const RESEND_WINDOW_MS = 5 * 60 * 1000;
```

- [ ] **Step 4: Run it to verify it passes**

```bash
deno run --allow-read scripts/verify-resend-eligibility.ts
```

Expected: `48 passed, 0 failed`, exit 0.

- [ ] **Step 5: Type-check the adapter**

```bash
deno check supabase/functions/_shared/fivesim.ts
```

Expected: `Check …/fivesim.ts` with no errors. (Three `Cannot find name 'EdgeRuntime'` errors elsewhere in the tree are a known benign Supabase global.)

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_shared/fivesim.ts scripts/verify-resend-eligibility.ts
git commit -m "5sim: name the pools that take a second SMS on one activation"
```

---

### Task 2: Migration — the two columns

**Files:**
- Create: `supabase/migrations/<version>_order_resend_window.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `orders.resend_watch_until timestamptz` (nullable), `orders.otp_history jsonb` (nullable). Both read by Tasks 3–5 and 7.

- [ ] **Step 1: Pick the version from the database, not the clock**

```bash
supabase db query --linked --file /dev/stdin <<'SQL'
select max(version) as max_version from supabase_migrations.schema_migrations;
SQL
```

Take the result and add one minute (e.g. `20260908220000` → `20260908230000`). Two sessions work on this repo per day and `on conflict (version) do nothing` silently swallows a collision, leaving a migration applied but unrecorded.

- [ ] **Step 2: Write the migration**

Create `supabase/migrations/<version>_order_resend_window.sql`:

```sql
-- A delivered activation is held open for a SECOND SMS instead of being
-- finished immediately.
--
-- 5sim's FAQ: "If you finish an order, then there is no way to request and
-- receive SMS using the same number again." We were calling finish() on code
-- arrival — 25 seconds, in the support case that prompted this — which
-- destroyed the only mechanism that can deliver a re-sent code to the number
-- the user's account is actually registered on.
--
-- 🔴 NO NEW `order_status` VALUE, DELIBERATELY. The iOS OrderStatus enum is a
-- plain String enum with no unknown case, so a status it does not recognise
-- throws on decode and takes the Orders tab down for every shipped build. The
-- order still flips to 'received'; the window lives in a nullable column, the
-- same shape `late_watch_until` already uses for the late-code rescue.

alter table public.orders
  add column if not exists resend_watch_until timestamptz,
  add column if not exists otp_history jsonb;

comment on column public.orders.resend_watch_until is
  'While > now(), poll-active-orders keeps re-polling this delivered order for '
  'another SMS and has NOT yet called markSuccess. Null means either the pool '
  'is ineligible or the window closed and finish() has been made. Reset to '
  'now() + 5 min on every new code — 5sim''s clock restarts per message.';

comment on column public.orders.otp_history is
  'Every code seen on this activation, oldest first: [{code, text, at}]. '
  '`otp` always holds the NEWEST. Shipped builds render `otp` alone, which is '
  'what lets a second code reach them with no release.';

-- Partial: the sweep only ever wants open windows, and they are a handful of
-- rows against the whole order history.
create index if not exists orders_resend_watch_idx
  on public.orders (resend_watch_until)
  where resend_watch_until is not null;
```

- [ ] **Step 3: Apply it**

```bash
supabase db query --linked --file supabase/migrations/<version>_order_resend_window.sql
```

- [ ] **Step 4: Record it, then SELECT it back**

```bash
supabase db query --linked --file /dev/stdin <<'SQL'
insert into supabase_migrations.schema_migrations (version, name)
values ('<version>','order_resend_window') on conflict (version) do nothing;
select version, name from supabase_migrations.schema_migrations
where version = '<version>';
SQL
```

Expected: exactly one row. **An empty result means the version was already taken by another session** — pick a new one and redo Steps 2–4. Do not assume the insert landed.

- [ ] **Step 5: Verify the columns exist**

```bash
supabase db query --linked --file /dev/stdin <<'SQL'
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema='public' and table_name='orders'
  and column_name in ('resend_watch_until','otp_history')
order by column_name;
SQL
```

Expected: two rows, both `is_nullable = YES`, types `timestamp with time zone` and `jsonb`.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/<version>_order_resend_window.sql
git commit -m "orders: resend_watch_until + otp_history for the second-code window"
```

---

### Task 3: Defer `finish` when the first code arrives

**Files:**
- Modify: `supabase/functions/poll-active-orders/index.ts` — the pending select (~line 698) and the received branch (~lines 723–755)

**Interfaces:**
- Consumes: `supportsResend`, `RESEND_WINDOW_MS` from Task 1; the columns from Task 2.
- Produces: rows carrying `resend_watch_until` for Task 4 to sweep.

- [ ] **Step 1: Add the import**

At the top of `supabase/functions/poll-active-orders/index.ts`, alongside the existing `_shared` imports:

```ts
import { RESEND_WINDOW_MS, supportsResend } from "../_shared/fivesim.ts";
```

- [ ] **Step 2: Select the two columns eligibility needs**

The pending query currently reads:

```ts
    .select(`
      id, user_id, provider, smspva_id, cost_credits,
      service:service_id ( id, name )
    `)
```

Replace with:

```ts
    .select(`
      id, user_id, provider, smspva_id, cost_credits,
      country_id, operator_used,
      service:service_id ( id, name )
    `)
```

`operator_used` is the pool that actually filled the order and is nullable — `supportsResend` treats null as ineligible, which is the correct reading of "not recorded".

- [ ] **Step 3: Hold the activation open instead of finishing it**

In the `result.state === "received" && result.code` branch, the update currently is:

```ts
        .update({
          status: "received",
          otp: result.code,
          raw_message: result.fullText ?? null,
          arrived_at: new Date().toISOString(),
          closed_at: new Date().toISOString(),
        })
```

Replace the whole claim-and-finish sequence with:

```ts
      // 🔴 `finish` IS WHAT FORECLOSES A SECOND CODE, so on a pool 5sim says
      // takes more than one SMS we do not call it yet. Their FAQ: "If you
      // finish an order, then there is no way to request and receive SMS using
      // the same number again." We were calling it 25 seconds after arrival.
      //
      // The activation stays open for RESEND_WINDOW_MS and the resend sweep at
      // the top of this handler makes the deferred markSuccess call when the
      // window lapses. If that sweep never runs, 5sim closes the activation
      // itself after five minutes — we lose a little account rating, never
      // money and never a code.
      const canResend = (o.provider ?? "smspva") === "5sim" &&
        supportsResend(o.country_id as string | null, o.operator_used as string | null);
      const nowMs = Date.now();
      const arrivedIso = new Date(nowMs).toISOString();

      const { data: claimed, error: uErr } = await sb
        .from("orders")
        .update({
          status: "received",
          otp: result.code,
          raw_message: result.fullText ?? null,
          arrived_at: arrivedIso,
          closed_at: arrivedIso,
          otp_history: [{ code: result.code, text: result.fullText ?? null, at: arrivedIso }],
          resend_watch_until: canResend
            ? new Date(nowMs + RESEND_WINDOW_MS).toISOString()
            : null,
        })
        .eq("id", o.id)
        .eq("status", "waiting")
        .select("id");
```

Then, further down the same branch, guard the `markSuccess` call:

```ts
      // Tell the provider the activation succeeded — best-effort karma hygiene.
      // DEFERRED while a resend window is open; the sweep makes this call when
      // the window closes. Calling it here is exactly the bug this feature fixes.
      if (!canResend) {
        await markSuccess((o.provider ?? "smspva") as OrderProvider, o.smspva_id);
      } else {
        console.log(JSON.stringify({
          event: "resend_window_opened", order: o.id,
          country: o.country_id, operator: o.operator_used,
          until: new Date(nowMs + RESEND_WINDOW_MS).toISOString(),
        }));
      }
```

- [ ] **Step 4: Type-check**

```bash
deno check supabase/functions/poll-active-orders/index.ts
```

Expected: clean (ignore `Cannot find name 'EdgeRuntime'`).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/poll-active-orders/index.ts
git commit -m "poll: hold an eligible 5sim activation open instead of finishing it"
```

---

### Task 4: The resend sweep

**Files:**
- Modify: `supabase/functions/poll-active-orders/index.ts` — insert immediately **before** the `// ── Poll the still-waiting orders for their SMS.` comment (~line 697)

**Interfaces:**
- Consumes: `RESEND_WINDOW_MS` (Task 1), the columns (Task 2), rows opened by Task 3.
- Produces: `resend_promoted` / `resend_window_closed` log lines; `resent` and `resendClosed` counters for the handler's JSON response.

- [ ] **Step 1: Write the sweep**

```ts
  // ── Orders holding a resend window: re-poll for ANOTHER code, and make the
  // deferred markSuccess call once the window lapses.
  //
  // Placed BEFORE the pending-orders loop deliberately, exactly as the
  // late-watch sweep above is. The worker dies at ~150s wall clock, so the last
  // thing in the handler is the first thing dropped under load — and a dropped
  // run here means the window expires with the code never promoted AND the
  // activation never finished.
  //
  // Capped at 25 (against 50 for each of the other two loops) because this
  // sweep is pure additional provider round-trips on a budget that was already
  // near its limit. A held order that misses a run is picked up the next
  // minute, well inside a five-minute window.
  let resent = 0, resendClosed = 0;
  const { data: resendWatch, error: resendErr } = await sb
    .from("orders")
    .select("id, user_id, provider, smspva_id, otp, otp_history, resend_watch_until, service:service_id ( name )")
    .not("resend_watch_until", "is", null)
    .order("resend_watch_until", { ascending: true })
    .limit(25);
  if (resendErr) console.error("poll: resend-watch select failed", resendErr);

  for (const o of resendWatch ?? []) {
    try {
      if (!o.smspva_id) {
        await sb.from("orders").update({ resend_watch_until: null }).eq("id", o.id);
        continue;
      }

      // Window lapsed: make the call Task 3 deferred, then leave the sweep.
      // markSuccess before the clear, matching the late-watch sweep's ordering
      // rationale — but with no attempt counter, because markSuccess is
      // idempotent hygiene rather than a number release, and 5sim will have
      // closed the activation itself by now anyway.
      if (new Date(o.resend_watch_until as string).getTime() <= Date.now()) {
        await markSuccess((o.provider ?? "smspva") as OrderProvider, o.smspva_id);
        const { error: clearErr } = await sb
          .from("orders").update({ resend_watch_until: null }).eq("id", o.id);
        if (clearErr) {
          console.error(JSON.stringify({
            alert: "resend_clear_failed", order: o.id, detail: clearErr.message,
          }));
          continue;   // retried next run; markSuccess is safe to repeat
        }
        resendClosed++;
        console.log(JSON.stringify({ event: "resend_window_closed", order: o.id }));
        continue;
      }

      const res = await poll((o.provider ?? "smspva") as OrderProvider, o.smspva_id);

      // 5sim closed it under us (their 5-minute auto-close, or the activation
      // window ran out). Nothing more can arrive — stop watching.
      if (res.state === "expired" || res.state === "canceled") {
        await sb.from("orders").update({ resend_watch_until: null }).eq("id", o.id);
        resendClosed++;
        continue;
      }

      // fivesim.poll() already walks sms[] BACKWARDS, so `res.code` is the
      // NEWEST message on the activation. Equal to `otp` means nothing new.
      if (res.state !== "received" || !res.code || res.code === o.otp) continue;

      const atIso = new Date().toISOString();
      const history = Array.isArray(o.otp_history) ? o.otp_history as unknown[] : [];

      // The claim is `.eq("otp", o.otp)` — the code we polled against. Two
      // overlapping runs cannot both promote the same new code, so the history
      // cannot double-append and the user cannot be pushed twice.
      const { data: promoted, error: promErr } = await sb
        .from("orders")
        .update({
          otp: res.code,
          raw_message: res.fullText ?? null,
          otp_history: [...history, { code: res.code, text: res.fullText ?? null, at: atIso }],
          resend_watch_until: new Date(Date.now() + RESEND_WINDOW_MS).toISOString(),
        })
        .eq("id", o.id)
        .eq("otp", o.otp)
        .select("id");

      if (promErr) {
        console.error(JSON.stringify({
          alert: "resend_promote_failed", order: o.id, detail: promErr.message,
        }));
        continue;   // window still open; retried next run
      }
      if (!promoted || promoted.length === 0) continue;   // another run won

      resent++;
      // 🔴 THE FIRST OF THESE EVER LOGGED IS THE PROOF THE FEATURE WORKS.
      // Until one appears, 5sim's multi-SMS pool list is an unverified claim.
      console.log(JSON.stringify({ event: "resend_promoted", order: o.id }));

      // Same payload shape shipped builds already route on: PushManager keys on
      // orderId, opens the OTP screen, and that screen renders `orders.otp` —
      // which now holds the newer code. This is what delivers the feature to
      // 2.2-2.11 with no release.
      const rsvc = o.service as { name: string } | null;
      pushSent += await notify(
        o.user_id,
        `New ${rsvc?.name ?? "verification"} code`,
        `Your new code is ${res.code}`,
        { orderId: o.id, otp: res.code, event: "resend" },
      );
    } catch (e) {
      console.error("resend-watch failed for order", o.id, e);
    }
  }
```

- [ ] **Step 2: Report the counters**

Find the handler's final `return json({...})` and add `resent` and `resendClosed` alongside the existing counters (`polled`, `arrived`, `rescued`, `lateReleased`, `pushSent`, …). Without them the sweep is invisible in the function logs.

- [ ] **Step 3: Type-check**

```bash
deno check supabase/functions/poll-active-orders/index.ts
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/poll-active-orders/index.ts
git commit -m "poll: sweep held activations and promote a second code"
```

---

### Task 5: The same deferral in `check-order`

**Files:**
- Modify: `supabase/functions/check-order/index.ts` — the received branch, lines 64–95

**Interfaces:**
- Consumes: `supportsResend`, `RESEND_WINDOW_MS` (Task 1); the columns (Task 2).
- Produces: nothing new — the same window Task 4 sweeps.

Without this, a user who taps "Check now" gets their code through a path that finishes the activation immediately and silently loses the window the cron path would have kept.

- [ ] **Step 1: Add the import**

```ts
import { RESEND_WINDOW_MS, supportsResend } from "../_shared/fivesim.ts";
```

- [ ] **Step 2: Confirm the handler already has the order's country and operator**

```bash
grep -n 'select(' supabase/functions/check-order/index.ts | head
```

If the order row is fetched with an explicit column list, add `country_id` and `operator_used` to it. If it uses `*`, no change is needed.

- [ ] **Step 3: Mirror Task 3's branch**

Replace the update and the `markSuccess` call with:

```ts
    const canResend = (order.provider ?? "smspva") === "5sim" &&
      supportsResend(order.country_id as string | null,
                     (order as { operator_used?: string | null }).operator_used ?? null);
    const nowMs = Date.now();
    const arrivedIso = new Date(nowMs).toISOString();

    const { data: rows, error: uErr } = await sb
      .from("orders")
      .update({
        status: "received",
        otp: result.code,
        raw_message: result.fullText ?? null,
        arrived_at: arrivedIso,
        closed_at: arrivedIso,
        otp_history: [{ code: result.code, text: result.fullText ?? null, at: arrivedIso }],
        resend_watch_until: canResend
          ? new Date(nowMs + RESEND_WINDOW_MS).toISOString()
          : null,
      })
      .eq("id", order.id)
      .eq("status", "waiting")
      .select("*");
    if (uErr) return json({ error: "update_failed", detail: uErr.message }, { status: 500 });

    if (rows && rows.length > 0) {
      // DEFERRED on an eligible pool — poll-active-orders' resend sweep makes
      // this call when the window closes. See fivesim.supportsResend.
      if (!canResend) {
        await markSuccess((order.provider ?? "smspva") as OrderProvider, order.smspva_id!);
      }
      return json({ order: rows[0], arrived: true });
    }
```

- [ ] **Step 4: Type-check**

```bash
deno check supabase/functions/check-order/index.ts
```

Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/check-order/index.ts
git commit -m "check-order: defer finish on an eligible pool, like the poller"
```

---

### Task 6: Behavioural verification + deploy

**Files:**
- Create: `scripts/verify-resend-window.sql`

**Interfaces:**
- Consumes: everything above.
- Produces: a rolled-back behavioural check, and the deployed functions.

A structural check cannot catch this class — the columns can exist and be correct while nothing reads them. The repo's precedents are `scripts/verify-line-lifecycle.sql` and `scripts/verify-call-settlement.sql`.

- [ ] **Step 1: Write the checks**

Create `scripts/verify-resend-window.sql`:

```sql
-- Behavioural checks for the second-code resend window. Everything happens
-- inside a transaction that ROLLS BACK — this runs against production.
--
--   supabase db query --linked --file scripts/verify-resend-window.sql
begin;

do $$
declare
  v_user uuid;
  v_open uuid;
  v_lapsed uuid;
  v_none uuid;
  n int;
begin
  select id into v_user from auth.users limit 1;
  if v_user is null then raise exception 'no users to test against'; end if;

  -- An eligible pool, window open.
  insert into public.orders
    (user_id, service_id, country_id, provider, operator_used, status, otp,
     smspva_number, smspva_id, cost_credits, expires_at, resend_watch_until,
     otp_history)
  values
    (v_user, 'whatnot', 'us', '5sim', 'virtual51', 'received', '111111',
     '+15550000001', 'test-open', 1, now() + interval '8 minutes',
     now() + interval '5 minutes',
     '[{"code":"111111","text":null,"at":"2026-09-08T00:00:00Z"}]'::jsonb)
  returning id into v_open;

  -- An eligible pool whose window has already lapsed.
  insert into public.orders
    (user_id, service_id, country_id, provider, operator_used, status, otp,
     smspva_number, smspva_id, cost_credits, expires_at, resend_watch_until)
  values
    (v_user, 'whatnot', 'us', '5sim', 'virtual51', 'received', '222222',
     '+15550000002', 'test-lapsed', 1, now() + interval '8 minutes',
     now() - interval '1 minute')
  returning id into v_lapsed;

  -- An INELIGIBLE pool: must carry no window at all.
  insert into public.orders
    (user_id, service_id, country_id, provider, operator_used, status, otp,
     smspva_number, smspva_id, cost_credits, expires_at, resend_watch_until)
  values
    (v_user, 'whatnot', 'us', '5sim', 'virtual63', 'received', '333333',
     '+15550000003', 'test-ineligible', 1, now() + interval '8 minutes', null)
  returning id into v_none;

  -- 1. The sweep's own selector picks up exactly the two windowed rows.
  select count(*) into n from public.orders
   where id in (v_open, v_lapsed, v_none) and resend_watch_until is not null;
  if n <> 2 then raise exception '1. expected 2 windowed rows, got %', n; end if;

  -- 2. The lapsed row is the one the sweep must close.
  select count(*) into n from public.orders
   where id in (v_open, v_lapsed) and resend_watch_until <= now();
  if n <> 1 then raise exception '2. expected 1 lapsed row, got %', n; end if;

  -- 3. The promotion claim is `.eq(otp, <polled value>)`. Against the CURRENT
  --    otp it matches once — this is the winning run.
  update public.orders
     set otp = '444444',
         otp_history = coalesce(otp_history, '[]'::jsonb) ||
                       jsonb_build_object('code','444444','text',null,'at',now()),
         resend_watch_until = now() + interval '5 minutes'
   where id = v_open and otp = '111111';
  get diagnostics n = row_count;
  if n <> 1 then raise exception '3. promotion should match once, matched %', n; end if;

  -- 4. A second run polling the SAME old code matches nothing — no double
  --    append, no double push. This is the property the claim exists for.
  update public.orders
     set otp = '444444',
         otp_history = coalesce(otp_history, '[]'::jsonb) ||
                       jsonb_build_object('code','444444','text',null,'at',now())
   where id = v_open and otp = '111111';
  get diagnostics n = row_count;
  if n <> 0 then raise exception '4. double promotion should match 0, matched %', n; end if;

  -- 5. History accumulated rather than replaced, and otp holds the NEWEST.
  select jsonb_array_length(otp_history) into n from public.orders where id = v_open;
  if n <> 2 then raise exception '5. expected 2 history entries, got %', n; end if;
  perform 1 from public.orders where id = v_open and otp = '444444';
  if not found then raise exception '5. otp should hold the newest code'; end if;

  -- 6. Closing the window nulls it, so the row leaves the sweep for good.
  update public.orders set resend_watch_until = null where id = v_lapsed;
  select count(*) into n from public.orders
   where id = v_lapsed and resend_watch_until is not null;
  if n <> 0 then raise exception '6. lapsed row should have left the sweep'; end if;

  -- 7. Status never changed. A new order_status value would break the Orders
  --    tab on every shipped build.
  select count(*) into n from public.orders
   where id in (v_open, v_lapsed, v_none) and status <> 'received';
  if n <> 0 then raise exception '7. status must stay received, % rows differ', n; end if;

  raise notice 'all 7 resend-window checks passed';
end $$;

rollback;
```

- [ ] **Step 2: Run it**

```bash
supabase db query --linked --file scripts/verify-resend-window.sql
```

Expected: `NOTICE: all 7 resend-window checks passed`, and — because of the `rollback` — no new rows afterwards. Confirm:

```bash
supabase db query --linked --file /dev/stdin <<'SQL'
select count(*) from public.orders where smspva_id like 'test-%';
SQL
```

Expected: `0`.

- [ ] **Step 3: Deploy — every consumer of the changed `_shared` file**

`_shared/*` is bundled per function at deploy time, so a stale bundle keeps the old copy with no signal anywhere. `fivesim.ts` changed, so redeploy its consumers:

```bash
supabase functions deploy create-order check-order cancel-order
supabase functions deploy poll-active-orders sync-5sim --no-verify-jwt
```

- [ ] **Step 4: Verify the deploy from DB state, not the deploy log**

Wait for one minutely poller run, then:

```bash
supabase db query --linked --file /dev/stdin <<'SQL'
select id, service_id, country_id, operator_used, otp,
       resend_watch_until, jsonb_array_length(otp_history) as codes
from public.orders
where resend_watch_until is not null
   or otp_history is not null
order by created_at desc limit 10;
SQL
```

Expected: nothing until the next real delivered order on an eligible pool. The first such order must show a `resend_watch_until` about five minutes ahead and one history entry.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-resend-window.sql
git commit -m "verify: behavioural checks for the resend window"
```

---

### Task 7: Client — decode the two new columns

**Files:**
- Modify: `VirtualSIM/Networking/OrdersAPI.swift:3-27` (`ServerOrder`) and `:42-47` (`columns`)
- Modify: `VirtualSIM/Models/Order.swift`

**Interfaces:**
- Consumes: the columns from Task 2.
- Produces: `ServerOrder.resendWatchUntil: Date?`, `ServerOrder.otpHistory: [OrderCode]?`, `Order.resendWatchUntil`, `Order.otpHistory`, `struct OrderCode: Codable, Hashable { let code: String; let text: String?; let at: Date }`.

- [ ] **Step 1: Add the model fields**

In `VirtualSIM/Networking/OrdersAPI.swift`, above `ServerOrder`:

```swift
/// One code seen on an activation. `orders.otp_history` is an array of these,
/// oldest first; `orders.otp` always holds the newest.
struct OrderCode: Codable, Hashable {
    let code: String
    let text: String?
    let at: Date
}
```

Add to `ServerOrder`, after `provider`:

```swift
    /// While this is in the future, the activation is still open and another
    /// code can arrive on the SAME number. Null on pools that cannot take a
    /// second SMS, and after the window closes.
    ///
    /// Optional because rows written before this shipped do not carry it, and
    /// a required field that is occasionally absent throws on decode and takes
    /// the whole Orders tab down.
    let resendWatchUntil: Date?
    /// Every code on this activation, oldest first. Optional for the same
    /// reason as above.
    let otpHistory: [OrderCode]?
```

- [ ] **Step 2: Add the columns to the fetch list**

`columns` must stay exactly `ServerOrder`'s stored properties — a column dropped from it silently nils an optional and throws on a non-optional:

```swift
    private static let columns = [
        "id", "user_id", "service_id", "country_id", "smspva_id",
        "smspva_number", "cost_credits", "status", "otp", "raw_message",
        "created_at", "expires_at", "arrived_at", "closed_at", "tier",
        "provider", "resend_watch_until", "otp_history",
    ].joined(separator: ",")
```

- [ ] **Step 3: Surface them on `Order`**

In `VirtualSIM/Models/Order.swift`, beside the other passthroughs:

```swift
    /// Non-nil and in the future ⇒ another code can still arrive on this
    /// number, and the UI may say so. Never derive this from the pool or the
    /// country on the client — the server decides eligibility.
    var resendWatchUntil: Date? { server.resendWatchUntil }
    /// Newest first, for display. `otp` is the newest and is always element 0.
    var codeHistory: [OrderCode] { (server.otpHistory ?? []).reversed() }
```

- [ ] **Step 4: Build**

```bash
cp /Users/adyl/Desktop/IOS_APPS/VirtualSIM/VirtualSIM/Networking/Secrets.swift \
   VirtualSIM/Networking/Secrets.swift 2>/dev/null || true
xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 \
  | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10
```

Expected: `** BUILD SUCCEEDED **`. (`Secrets.swift` is gitignored; a worktree without it fails with `cannot find 'Secrets' in scope`, which looks like your edit and is not.)

- [ ] **Step 5: Commit**

```bash
git add VirtualSIM/Networking/OrdersAPI.swift VirtualSIM/Models/Order.swift
git commit -m "client: decode resend_watch_until and otp_history"
```

---

### Task 8: Client — the countdown and the code history

**Files:**
- Modify: `VirtualSIM/Screens/OtpScreen.swift`
- Modify: `VirtualSIM/Localizable.xcstrings`

**Interfaces:**
- Consumes: `Order.resendWatchUntil`, `Order.codeHistory` (Task 7); `OrdersAPI.fetch(orderId:)`.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Hold a live copy of the order**

`OtpScreen` takes `order: Order` by value, so a promoted code never reaches it without a refresh. Add near the other `@State`:

```swift
    /// The order as last read from the server. `order` is a snapshot taken when
    /// the cover was presented, so a second code promoted while this screen is
    /// open would never appear without re-reading it.
    @State private var live: Order?
    private var current: Order { live ?? order }
```

Then change `otpValue` to read through it:

```swift
    private var otpValue: String { current.otp ?? "" }
```

- [ ] **Step 2: Refresh while the window is open**

Add to the `ZStack`, next to `.onAppear(perform: arrive)`:

```swift
        .task(id: order.id) {
            // Only while a window is actually open — an ineligible pool must
            // never generate polling traffic. Ten seconds against a five-minute
            // window is ~30 reads worst case, and it stops the moment the
            // window lapses.
            while !Task.isCancelled,
                  let until = current.resendWatchUntil, until > Date() {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                guard let fresh = try? await OrdersAPI(client: api).fetch(orderId: order.id)
                else { continue }
                live = Order(server: fresh, service: order.service, country: order.country)
            }
        }
```

- [ ] **Step 3: Render the countdown**

Add a view, and place `resendNotice` in the `VStack` directly after `codeCard`:

```swift
    /// Tells the user, in the only terms that are true, how long the number can
    /// still receive another code.
    ///
    /// 🔴 THE CLOCK RESTARTS ON EVERY MESSAGE — it is five minutes from the LAST
    /// SMS, not a budget from the first. So this always renders the time left
    /// from the CURRENT deadline and never a fraction of a fixed total.
    ///
    /// Absent entirely when `resendWatchUntil` is nil: that means the pool
    /// cannot take a second SMS, and advertising one would be a promise the
    /// provider has not made.
    @ViewBuilder private var resendNotice: some View {
        if let until = current.resendWatchUntil, until > now {
            let left = Int(until.timeIntervalSince(now))
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Need another code?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("You have \(timeLeft(left)) to get one on this number. Ask \(current.service.name) to resend — it arrives here.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text2)
                }
            }
        }
    }

    /// mm:ss. Deliberately not RelativeDateTimeFormatter: "in 4 minutes" reads
    /// as an estimate, and this is a hard provider deadline.
    private func timeLeft(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
```

Drive `now` with the existing timer if the screen has one; otherwise add:

```swift
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
```

and `.onReceive(tick) { now = $0 }` on the `ZStack`.

- [ ] **Step 4: Show earlier codes once there is more than one**

Place after `resendNotice`:

```swift
    /// Only when a second code has actually arrived. One code needs no list —
    /// it is already the thing filling the screen.
    @ViewBuilder private var earlierCodes: some View {
        let history = current.codeHistory
        if history.count > 1 {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Earlier codes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text2)
                    ForEach(Array(history.dropFirst()), id: \.at) { entry in
                        MonoText(entry.code, size: 15, color: theme.text2)
                    }
                }
            }
        }
    }
```

- [ ] **Step 5: Localize all three strings**

```bash
xcodebuild -exportLocalizations -project VirtualSIM.xcodeproj -localizationPath /tmp/vsms-loc
```

SwiftUI compiles interpolated literals into forms you will not guess — the second string becomes positional (`%1$@ … %2$@`). Take the exact keys from the export and add all six locales to `VirtualSIM/Localizable.xcstrings`. Then confirm the specifier multiset matches per locale:

```bash
python3 scripts/audit-xcstrings.py
```

Expected: no mismatches. A reordered translation is legal only in positional form; a reordered non-positional one is a runtime crash.

- [ ] **Step 6: Build**

```bash
xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 \
  | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add VirtualSIM/Screens/OtpScreen.swift VirtualSIM/Localizable.xcstrings
git commit -m "otp: countdown for a second code, and the earlier-codes list"
```

---

### Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** none.

CLAUDE.md is loaded into every future session as fact. A stale line there turns a documentation error into a decision error.

- [ ] **Step 1: Extend the 5sim reuse bullet**

It currently ends by recording that reuse is refused after both a cancel and a finish. Add, in the same bullet, that the supported mechanism is holding the activation open — the pool list, the 5-minute rolling window, and that `finish` is what forecloses it. Point at `fivesim.supportsResend`.

- [ ] **Step 2: Add a note under the poller**

State that `markSuccess` is now **deferred** for eligible 5sim orders, that the resend sweep makes the call when the window lapses, and that the failure mode is safe because 5sim auto-closes after five minutes. Name the two new columns and say plainly that no `order_status` value was added and why.

- [ ] **Step 3: Record what is still unproven**

Under Known-open: 5sim's eligible-pool list is their published claim, so the ~58% coverage figure is unverified until a `resend_promoted` line appears in the poller logs. Also record HeroSMS's caller-less `STATUS_RETRY` wrapper (`_shared/herosms.ts:645`, wrapper at 677) as a known-open opportunity.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: the resend window, and what about it is still unproven"
```

---

## Self-Review

**Spec coverage.** §1 eligibility → Task 1. §2 schema → Task 2. §3a defer → Task 3; §3b sweep → Task 4; §3c check-order → Task 5. §4 push → Task 4 Step 1 (the `notify` call). §5 client → Tasks 7 and 8. §6 deliberately-unchanged → held as Global Constraints and asserted by check 7 in Task 6. Risks §1 → the `resend_promoted` log and Task 9 Step 3. Verification → Task 6. Documentation → Task 9. No gaps.

**Placeholders.** None: `<version>` in Task 2 is derived by a command in Step 1, and every code step carries real code.

**Type consistency.** `supportsResend(country, operator)` and `RESEND_WINDOW_MS` are defined in Task 1 and used with that exact signature in Tasks 3, 4 and 5. `OrderCode` is defined in Task 7 Step 1 and consumed in Task 8 Step 4. `resendWatchUntil` / `otpHistory` are named consistently across Swift, and map to `resend_watch_until` / `otp_history` through the decoder's `convertFromSnakeCase`.

**One risk the plan cannot remove:** Task 6 Step 4 can only confirm the *absence* of a window until a real order lands on an eligible pool. The feature is unproven until a `resend_promoted` line appears — that is stated in the spec, in the code comment, and in Task 9.
