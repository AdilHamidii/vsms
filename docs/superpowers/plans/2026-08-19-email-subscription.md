# Temp-e-mail subscription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the temp-e-mail line into a subscription product — one free address per account for life, then $2.99/month or $29.99/year (3-day trial) for unlimited addresses on the free domains.

**Architecture:** A second App Store subscription group with its own `email_subscriptions` table, mirroring the existing `line_subscriptions` machinery rather than generalising it. Entitlement is decided in SQL inside `begin_email_order`; the device never settles it. Apple notifications for both groups arrive at the one existing `apple-notifications` endpoint, so a product-family dispatch splits them.

**Tech Stack:** Postgres (Supabase) + Deno edge functions + SwiftUI/StoreKit 2. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-19-email-subscription-design.md`

## Global Constraints

- **Product ids:** `com.anthersystems.VirtualSIM.mail.monthly` ($2.99/mo, no trial), `com.anthersystems.VirtualSIM.mail.yearly` ($29.99/yr, 3-day trial).
- **A mail product id must NEVER appear in `PRODUCT_TO_CREDITS`** — one entry pays wallet credits on every renewal, forever.
- **Free domains only** (`outlook.com`, `hotmail.com`). `gmail.com` stays 1 credit for everyone, subscriber or not.
- **Free allowance is LIFETIME and RETROACTIVE**: existing `email_orders` rows count. Allowance read live from `app_config.email_free_lifetime_grants`, default **1**, clamped **0–50**.
- **Subscriber daily sanity cap:** `app_config.email_sub_daily_cap`, default **25**.
- **Every new SQL function** gets `revoke execute ... from public, anon, authenticated`. A revoke from `anon, authenticated` alone is a **no-op** while PUBLIC holds the grant — assert with `has_function_privilege`.
- **Every `{ error: "..." }` literal added to an edge function gets its `APIError` case in the same commit.**
- **iOS deployment target is 18.0.** Anything behind `if #available(iOS 26, *)` needs a working 18.0 path.
- **Verify iOS with `xcodebuild` only.** `swiftc -typecheck` is retired (it cannot resolve the SwiftPM graph).
- **Copy rule:** never name or allude to a supplier in user-facing text. Never promise "unlimited e-mails" flatly — name the two domains.
- **Deploy after committing, never before.** A bundle deployed mid-edit and committed afterwards is this repo's most repeated silent bug.
- **Migration versions:** pick from `select max(version) from supabase_migrations.schema_migrations`, never from the clock — more than one session works this repo per day. After recording a migration, `select` it back **by name**; `on conflict (version) do nothing` silently swallows a collision.

---

### Task 1: Subscription product families in `_shared/iap.ts`

Splits the one overloaded predicate. Nothing behaves differently yet — this task exists on its own so the dangerous change can be reviewed in isolation.

**Files:**
- Modify: `supabase/functions/_shared/iap.ts` (around the `LINE_SUBSCRIPTION_PRODUCT_IDS` block, ~line 417-471)
- Create: `scripts/verify-subscription-families.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `export type SubscriptionFamily = "line" | "mail"`
  - `export const MAIL_SUBSCRIPTION_PRODUCT_IDS: readonly string[]`
  - `export function subscriptionFamily(productId: string): SubscriptionFamily | null`
  - `export function isSubscriptionProduct(productId: string): boolean` (unchanged signature)
  - `export function mailPlanLabel(tx: AppleTransactionPayload): string`

- [ ] **Step 1: Write the failing check**

Create `scripts/verify-subscription-families.ts`:

```ts
// Behavioural checks for the subscription family split.
// Run: deno run --allow-read scripts/verify-subscription-families.ts
import {
  subscriptionFamily, isSubscriptionProduct,
  LINE_SUBSCRIPTION_PRODUCT_IDS, MAIL_SUBSCRIPTION_PRODUCT_IDS,
  PRODUCT_TO_CREDITS,
} from "../supabase/functions/_shared/iap.ts";

let failures = 0;
function check(name: string, ok: boolean) {
  console.log(`${ok ? "ok  " : "FAIL"}  ${name}`);
  if (!ok) failures++;
}

check("line monthly is family line",
  subscriptionFamily("com.anthersystems.VirtualSIM.line.monthly") === "line");
check("line yearly is family line",
  subscriptionFamily("com.anthersystems.VirtualSIM.line.yearly") === "line");
check("mail monthly is family mail",
  subscriptionFamily("com.anthersystems.VirtualSIM.mail.monthly") === "mail");
check("mail yearly is family mail",
  subscriptionFamily("com.anthersystems.VirtualSIM.mail.yearly") === "mail");
check("a credit pack has no family",
  subscriptionFamily("credits.12") === null);
check("an unknown id has no family",
  subscriptionFamily("com.anthersystems.VirtualSIM.nonsense") === null);

// The iap-verify contract: every subscription, both families, must be covered
// or a legitimate purchase 400s as unknown_product and pages the owner.
for (const id of [...LINE_SUBSCRIPTION_PRODUCT_IDS, ...MAIL_SUBSCRIPTION_PRODUCT_IDS]) {
  check(`isSubscriptionProduct covers ${id}`, isSubscriptionProduct(id));
}
check("isSubscriptionProduct rejects a credit pack",
  !isSubscriptionProduct("credits.12"));

// 🔴 The money invariant: a subscription in PRODUCT_TO_CREDITS pays credits on
// every renewal forever.
for (const id of [...LINE_SUBSCRIPTION_PRODUCT_IDS, ...MAIL_SUBSCRIPTION_PRODUCT_IDS]) {
  check(`${id} is NOT in PRODUCT_TO_CREDITS`,
    !Object.prototype.hasOwnProperty.call(PRODUCT_TO_CREDITS, id));
}

// The two families must be disjoint — an id in both would make dispatch
// order-dependent.
const overlap = MAIL_SUBSCRIPTION_PRODUCT_IDS
  .filter((id) => LINE_SUBSCRIPTION_PRODUCT_IDS.includes(id));
check("families are disjoint", overlap.length === 0);

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILED`);
if (failures > 0) Deno.exit(1);
```

- [ ] **Step 2: Run it to verify it fails**

Run: `deno run --allow-read scripts/verify-subscription-families.ts`
Expected: FAIL — `The requested module '../supabase/functions/_shared/iap.ts' does not provide an export named 'subscriptionFamily'`

- [ ] **Step 3: Implement the split**

In `supabase/functions/_shared/iap.ts`, directly after the existing
`LINE_SUBSCRIPTION_PRODUCT_IDS` declaration, add:

```ts
/** EVERY product in the MAIL subscription group.
 *
 * A SEPARATE App Store subscription group from the line, and that is not an
 * implementation detail: Apple allows one active subscription per group with
 * no quantity on iOS, so a mail product inside the line group would make a
 * $2.99 mail purchase REPLACE a subscriber's $9.99 phone number.
 *
 * Because the groups are separate, a user may legitimately hold a line AND a
 * mail subscription at once. Nothing may assume otherwise.
 */
export const MAIL_SUBSCRIPTION_PRODUCT_IDS: readonly string[] = [
  "com.anthersystems.VirtualSIM.mail.monthly",
  "com.anthersystems.VirtualSIM.mail.yearly",
];

/** Which product family a subscription belongs to, or null for anything that
 *  is not one of our subscriptions (a credit pack, or an id we do not know).
 *
 * 🔴 THIS EXISTS BECAUSE `isSubscriptionProduct` MEANT TWO OPPOSITE THINGS.
 *
 *  - `iap-verify` asks "is this NOT a credit pack?" so it does not 400 a real
 *    purchase and page the owner. Mail products must be INCLUDED there.
 *  - `apple-notifications` asked the same function "is this a line?" and every
 *    branch after that guard UPDATEs `line_subscriptions` and drives the
 *    phone-number lapse machine. Mail products must be EXCLUDED there, or a
 *    cancelled $2.99 mail plan suspends and releases somebody's rented number.
 *
 *  Callers that act on a subscription must dispatch on the FAMILY. Callers that
 *  only need "is this a subscription at all" keep using
 *  `isSubscriptionProduct`.
 */
export type SubscriptionFamily = "line" | "mail";

export function subscriptionFamily(productId: string): SubscriptionFamily | null {
  if (LINE_SUBSCRIPTION_PRODUCT_IDS.includes(productId)) return "line";
  if (MAIL_SUBSCRIPTION_PRODUCT_IDS.includes(productId)) return "mail";
  return null;
}

/** Ops label for a mail subscription transaction. Display only — nothing may
 *  gate on it, for the same reason `linePlanLabel` may not: a trial subscriber
 *  is entitled to the product they are trialling. */
export function mailPlanLabel(tx: AppleTransactionPayload): string {
  const id = tx.productId ?? "";
  const plan = id.endsWith(".mail.monthly") ? "monthly"
    : id.endsWith(".mail.yearly") ? "yearly"
    : id;
  return isFreeTrial(tx) ? `${plan} · free trial` : plan;
}
```

Then replace the body of the existing `isSubscriptionProduct` (leave its
doc comment, and append the added note):

```ts
export function isSubscriptionProduct(productId: string): boolean {
  return subscriptionFamily(productId) !== null;
}
```

- [ ] **Step 4: Run the check to verify it passes**

Run: `deno run --allow-read scripts/verify-subscription-families.ts`
Expected: `ALL PASS`

- [ ] **Step 5: Type-check the consumers**

Run: `deno check supabase/functions/iap-verify/index.ts supabase/functions/apple-notifications/index.ts supabase/functions/verify-line-subscription/index.ts`
Expected: no new errors. Three pre-existing `Cannot find name 'EdgeRuntime'` errors are a Supabase runtime global Deno does not type — benign, ignore them.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_shared/iap.ts scripts/verify-subscription-families.ts
git commit -m "feat(iap): split subscription products into line and mail families

isSubscriptionProduct meant two opposite things: 'not a credit pack' in
iap-verify, where mail products must be included, and 'this is a line' in
apple-notifications, where they must be excluded or a mail cancellation
releases a rented phone number. subscriptionFamily() is what callers that
ACT on a subscription now dispatch on."
```

---

### Task 2: `email_subscriptions` schema and the entitlement gate

**Files:**
- Create: `supabase/migrations/<version>_email_subscriptions.sql`
- Create: `scripts/verify-email-subscription.sql`

**Interfaces:**
- Consumes: nothing from Task 1 (independent; SQL only).
- Produces:
  - table `public.email_subscriptions`
  - `public.record_email_subscription(text, uuid, text, public.line_sub_state, boolean, text, timestamptz, text, text, text, bigint, text) returns jsonb` → `{ok:true}` or `{ok:false, reason:'subscription_bound'|'bad_request'}`
  - `public.has_email_subscription(p_user uuid) returns boolean`
  - `public.begin_email_order(uuid, text, text, text, integer) returns jsonb` — gains reasons `subscription_required` and `daily_cap_reached` (the latter carries `cap`)

- [ ] **Step 1: Pick the migration version**

Run:
```bash
supabase db query --linked "select max(version) from supabase_migrations.schema_migrations;"
```
Use the returned value + 1 second, formatted `YYYYMMDDHHMMSS`. Do **not** derive it from the clock — a parallel session may already hold that timestamp, and `on conflict (version) do nothing` swallows the collision silently.

- [ ] **Step 2: Write the failing behavioural check**

Create `scripts/verify-email-subscription.sql`. Every check runs inside a
transaction that is **rolled back**, so it is safe against production:

```sql
-- Behavioural checks for the e-mail subscription entitlement.
-- Run: supabase db query --linked --file scripts/verify-email-subscription.sql
-- Everything happens inside a transaction that is rolled back at the end.
begin;

do $$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000e1';
  v_res  jsonb;
  v_cap  integer;
begin
  -- A wallet is required by begin_email_order's paid path; the free path never
  -- touches it, but the row keeps the fixture honest.
  insert into public.wallets (user_id, balance) values (v_user, 0)
    on conflict (user_id) do nothing;

  -- 1. No prior free orders, no subscription → the first free address is allowed.
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'outlook.com', 0);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'CHECK 1 FAILED: first free address refused: %', v_res;
  end if;
  raise notice 'ok  1. first free address allowed';

  -- 2. One prior free order, still no subscription → refused, and the reason
  --    must be subscription_required (NOT free_limit_reached, which the client
  --    renders as "try again tomorrow" and would be a lie).
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'hotmail.com', 0);
  if v_res->>'reason' is distinct from 'subscription_required' then
    raise exception 'CHECK 2 FAILED: expected subscription_required, got %', v_res;
  end if;
  raise notice 'ok  2. second free address refused with subscription_required';

  -- 3. gmail is NOT part of the subscription and must stay purchasable with
  --    credits even while the free allowance is exhausted.
  update public.wallets set balance = 5 where user_id = v_user;
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'gmail.com', 1);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'CHECK 3 FAILED: paid gmail refused: %', v_res;
  end if;
  raise notice 'ok  3. gmail still purchasable with credits';

  -- 4. An ACTIVE subscription lifts the wall.
  perform public.record_email_subscription(
    'tx-fixture-1', v_user, 'com.anthersystems.VirtualSIM.mail.monthly',
    'active'::public.line_sub_state, true, 'Production',
    now() + interval '30 days', 'tx-fixture-1-last', null, null, null, null);
  if public.has_email_subscription(v_user) is not true then
    raise exception 'CHECK 4 FAILED: active subscription not entitled';
  end if;
  v_res := public.begin_email_order(v_user, 'discord', 'discord.com', 'outlook.com', 0);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'CHECK 4 FAILED: subscriber refused: %', v_res;
  end if;
  raise notice 'ok  4. active subscription lifts the wall';

  -- 5. An EXPIRED subscription does not.
  update public.email_subscriptions
     set state = 'expired'::public.line_sub_state, expires_at = now() - interval '1 day'
   where original_transaction_id = 'tx-fixture-1';
  if public.has_email_subscription(v_user) is not false then
    raise exception 'CHECK 5 FAILED: expired subscription still entitled';
  end if;
  raise notice 'ok  5. expired subscription is not entitled';

  -- 6. A GRACE subscription IS entitled — Apple is still trying to bill, and
  --    cutting service off during billing retry loses a customer we still have.
  update public.email_subscriptions
     set state = 'grace'::public.line_sub_state,
         grace_expires_at = now() + interval '10 days'
   where original_transaction_id = 'tx-fixture-1';
  if public.has_email_subscription(v_user) is not true then
    raise exception 'CHECK 6 FAILED: grace subscription not entitled';
  end if;
  raise notice 'ok  6. grace period is entitled';

  -- 7. The subscriber daily sanity cap is a HARD stop and reports the cap.
  update public.email_subscriptions
     set state = 'active'::public.line_sub_state, expires_at = now() + interval '30 days'
   where original_transaction_id = 'tx-fixture-1';
  select coalesce((value #>> '{}')::integer, 25) into v_cap
    from public.app_config where key = 'email_sub_daily_cap';
  insert into public.email_orders (user_id, service_id, site, domain, cost_credits, status)
  select v_user, 'google', 'google.com', 'outlook.com', 0, 'waiting'
    from generate_series(1, v_cap);
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'outlook.com', 0);
  if v_res->>'reason' is distinct from 'daily_cap_reached' then
    raise exception 'CHECK 7 FAILED: expected daily_cap_reached, got %', v_res;
  end if;
  if (v_res->>'cap')::integer is distinct from v_cap then
    raise exception 'CHECK 7 FAILED: cap not reported: %', v_res;
  end if;
  raise notice 'ok  7. subscriber daily cap is a hard stop and reports the cap';

  -- 8. Replay: the same Apple transaction presented by a SECOND user is
  --    refused. This is the delete-account replay, and rebinding it would hand
  --    a new account an entitlement the old one is still paying for.
  v_res := public.record_email_subscription(
    'tx-fixture-1', '00000000-0000-0000-0000-0000000000e2',
    'com.anthersystems.VirtualSIM.mail.monthly',
    'active'::public.line_sub_state, true, 'Production',
    now() + interval '30 days', 'tx-fixture-1-last', null, null, null, null);
  if v_res->>'reason' is distinct from 'subscription_bound' then
    raise exception 'CHECK 8 FAILED: expected subscription_bound, got %', v_res;
  end if;
  raise notice 'ok  8. replay by a second account is refused';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
```

- [ ] **Step 3: Run it to verify it fails**

Run: `supabase db query --linked --file scripts/verify-email-subscription.sql`
Expected: FAIL — `function public.record_email_subscription(...) does not exist`

(Use `--file`, never inline SQL beginning with `--`: `db query` parses a leading SQL comment as a CLI flag.)

- [ ] **Step 4: Write the migration**

Create `supabase/migrations/<version>_email_subscriptions.sql`:

```sql
-- The temp-e-mail line becomes a subscription product.
--
-- One free address per account for LIFE (retroactive over existing rows), then
-- an auto-renewable subscription grants unlimited addresses on the FREE
-- domains. gmail.com stays a 1-credit purchase for everyone.
--
-- The table mirrors line_subscriptions rather than generalising it: that table
-- carries live paying subscribers and a lapse backstop, and restructuring live
-- money code to add a second product is the wrong order of risk.

create table if not exists public.email_subscriptions (
  original_transaction_id   text primary key,
  -- Deliberately NOT `references auth.users`. A FK here is exactly what would
  -- delete our record along with the account: delete-account → re-signin →
  -- StoreKit still reports the entitlement, and we would grant it twice while
  -- Apple bills once. `subscription_bound` is the replay catch.
  user_id                   uuid not null,
  product_id                text not null,
  -- Reuses the existing enum rather than declaring a second identical one:
  -- these values describe APPLE's subscription lifecycle, which is not
  -- line-specific. The `line_` prefix is therefore now a misnomer; renaming a
  -- live enum is not worth a migration, and this comment is the record that it
  -- is shared on purpose.
  state                     public.line_sub_state not null,
  auto_renew                boolean not null default true,
  environment               text not null,
  expires_at                timestamptz,
  grace_expires_at          timestamptz,
  last_transaction_id       text,
  -- Raw JWS of the latest transaction, so revenue work can decode the REAL
  -- billed price/currency/storefront with the existing jws_payload(). A
  -- hardcoded USD ladder mis-states revenue across storefronts.
  latest_signed_transaction text,
  revocation_date           timestamptz,
  revocation_reason         integer,
  storefront                text,
  price_milli               bigint,
  currency                  text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create index if not exists email_subscriptions_user_idx
  on public.email_subscriptions (user_id);
create index if not exists email_subscriptions_expiry_idx
  on public.email_subscriptions (state, expires_at);

alter table public.email_subscriptions enable row level security;
revoke all on public.email_subscriptions from anon, authenticated;

-- Config. Both are read live so the numbers move without a deploy.
insert into public.app_config (key, value)
values ('email_free_lifetime_grants', '1'::jsonb)
on conflict (key) do nothing;

insert into public.app_config (key, value)
values ('email_sub_daily_cap', '25'::jsonb)
on conflict (key) do nothing;

-- `telegram_events.kind` is a CHECK constraint, not free text. The mail alerts
-- claim rows on new kinds, and an unlisted value raises 23514 — which would
-- make the alert path throw INSIDE the notification handler and hand Apple a
-- 500 for a subscription we recorded correctly.
alter table public.telegram_events drop constraint if exists telegram_events_kind_check;
alter table public.telegram_events add constraint telegram_events_kind_check
  check (kind = any (array[
    'signup', 'purchase', 'esim', 'email', 'line', 'line_refund',
    'line_orphan', 'line_provision_failed', 'iap_unknown', 'line_event',
    'mail_sub', 'mail_sub_event'
  ]));

-- ── The only creator of rows ─────────────────────────────────────────────────
create or replace function public.record_email_subscription(
  p_original_tx  text,
  p_user         uuid,
  p_product      text,
  p_state        public.line_sub_state,
  p_auto_renew   boolean,
  p_environment  text,
  p_expires_at   timestamptz,
  p_last_tx      text,
  p_signed_tx    text default null,
  p_storefront   text default null,
  p_price_milli  bigint default null,
  p_currency     text default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_bound uuid;
begin
  if p_original_tx is null or p_user is null or p_product is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- THE replay check. A subscription already bound to a DIFFERENT user means
  -- the same Apple entitlement is being presented by a second account, which
  -- is what deleting and re-creating an account produces.
  select user_id into v_bound from public.email_subscriptions
   where original_transaction_id = p_original_tx;
  if v_bound is not null and v_bound <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'subscription_bound');
  end if;

  insert into public.email_subscriptions (
    original_transaction_id, user_id, product_id, state, auto_renew,
    environment, expires_at, last_transaction_id, latest_signed_transaction,
    storefront, price_milli, currency)
  values (
    p_original_tx, p_user, p_product, p_state, coalesce(p_auto_renew, true),
    coalesce(p_environment, 'Production'), p_expires_at, p_last_tx, p_signed_tx,
    p_storefront, p_price_milli, p_currency)
  on conflict (original_transaction_id) do update
    set state       = excluded.state,
        auto_renew  = excluded.auto_renew,
        expires_at  = excluded.expires_at,
        product_id  = excluded.product_id,
        -- coalesce so a notification that omits these does not WIPE what the
        -- purchase recorded: ASSN payloads legitimately carry less than the
        -- original transaction did.
        last_transaction_id       = coalesce(excluded.last_transaction_id,
                                             email_subscriptions.last_transaction_id),
        latest_signed_transaction = coalesce(excluded.latest_signed_transaction,
                                             email_subscriptions.latest_signed_transaction),
        storefront   = coalesce(excluded.storefront, email_subscriptions.storefront),
        price_milli  = coalesce(excluded.price_milli, email_subscriptions.price_milli),
        currency     = coalesce(excluded.currency, email_subscriptions.currency),
        updated_at   = now();

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ── The entitlement ─────────────────────────────────────────────────────────
-- `grace` counts as entitled: Apple is still trying to bill, and cutting
-- service off mid-retry loses a customer we still have.
create or replace function public.has_email_subscription(p_user uuid)
returns boolean
language sql stable security definer set search_path to 'public' as $fn$
  select exists (
    select 1 from public.email_subscriptions
     where user_id = p_user
       and state in ('active', 'grace')
       and coalesce(grace_expires_at, expires_at) > now()
  );
$fn$;

-- ── The gate ────────────────────────────────────────────────────────────────
-- Replaces the per-UTC-day free cap with: one free address for LIFE, or a
-- subscription. The paid (gmail) path is byte-identical to what it was.
create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text, p_credits integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existing uuid; v_order uuid; v_ok boolean;
  v_free_ever integer; v_grants integer;
  v_today integer; v_cap integer;
begin
  if p_credits is null or p_credits < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id into v_existing from public.email_orders
   where user_id = p_user and site = p_site and domain = p_domain
     and status = 'waiting' and created_at > now() - interval '2 minutes'
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  if p_credits = 0 then
    if public.has_email_subscription(p_user) then
      -- Subscribed. Free domains cost us nothing, but the inventory is scarce
      -- and SHARED — one looping subscriber could drain it for every user. A
      -- stated hard stop, not a throttle.
      select greatest(0, least(10000, coalesce((value #>> '{}')::integer, 25)))
        into v_cap from public.app_config where key = 'email_sub_daily_cap';
      v_cap := coalesce(v_cap, 25);
      select count(*) into v_today from public.email_orders
       where user_id = p_user and cost_credits = 0
         and status <> 'failed'
         and created_at >= date_trunc('day', now() at time zone 'utc');
      if v_today >= v_cap then
        return jsonb_build_object('ok', false, 'reason', 'daily_cap_reached',
                                  'cap', v_cap);
      end if;
    else
      -- Not subscribed: a LIFETIME allowance, counted over all history.
      -- `status <> 'failed'` is retained from the old daily rule — an order
      -- that never provisioned a mailbox is not a grant.
      select greatest(0, least(50, coalesce((value #>> '{}')::integer, 1)))
        into v_grants from public.app_config
       where key = 'email_free_lifetime_grants';
      v_grants := coalesce(v_grants, 1);
      select count(*) into v_free_ever from public.email_orders
       where user_id = p_user and cost_credits = 0 and status <> 'failed';
      if v_free_ever >= v_grants then
        return jsonb_build_object('ok', false, 'reason', 'subscription_required',
                                  'used', v_free_ever, 'grants', v_grants);
      end if;
    end if;
  end if;

  insert into public.email_orders (user_id, service_id, site, domain, cost_credits, status)
  values (p_user, p_service, p_site, p_domain, p_credits, 'waiting')
  returning id into v_order;

  if p_credits > 0 then
    select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
    if not coalesce(v_ok, false) then
      delete from public.email_orders where id = v_order;
      return jsonb_build_object('ok', false, 'reason', 'insufficient');
    end if;
    update public.wallet_transactions set email_order_id = v_order
     where id = (select id from public.wallet_transactions
                  where user_id = p_user and reason = 'spend' and email_order_id is null
                  order by created_at desc, id desc limit 1);
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order);
end;
$function$;

-- ── Privileges ──────────────────────────────────────────────────────────────
-- The `public` half is the one that matters: CREATE FUNCTION grants EXECUTE to
-- PUBLIC by default and anon/authenticated are members, so revoking only those
-- two changes nothing at all.
revoke execute on function public.record_email_subscription(
  text, uuid, text, public.line_sub_state, boolean, text, timestamptz, text,
  text, text, bigint, text) from public, anon, authenticated;
revoke execute on function public.has_email_subscription(uuid)
  from public, anon, authenticated;
revoke execute on function public.begin_email_order(uuid, text, text, text, integer)
  from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.has_email_subscription(uuid)', 'execute') then
    raise exception 'has_email_subscription is callable by anon';
  end if;
  if has_function_privilege('anon', 'public.record_email_subscription(text, uuid, text,'
       || ' public.line_sub_state, boolean, text, timestamptz, text, text, text,'
       || ' bigint, text)', 'execute') then
    raise exception 'record_email_subscription is callable by anon';
  end if;
  if has_function_privilege('anon',
       'public.begin_email_order(uuid, text, text, text, integer)', 'execute') then
    raise exception 'begin_email_order is callable by anon';
  end if;
end $$;
```

- [ ] **Step 5: Apply the migration**

`supabase db push` is broken in this repo (43 remote versions have no local file). Apply and record by hand:

```bash
supabase db query --linked --file supabase/migrations/<version>_email_subscriptions.sql
supabase db query --linked "insert into supabase_migrations.schema_migrations (version, name) values ('<version>','email_subscriptions') on conflict (version) do nothing;"
supabase db query --linked "select version, name from supabase_migrations.schema_migrations where name = 'email_subscriptions';"
```

The third command is not optional: `on conflict do nothing` silently swallows a version collision with a parallel session, leaving SQL applied and unrecorded.

- [ ] **Step 6: Verify the functions exist**

Run:
```bash
supabase db query --linked "select proname from pg_proc where pronamespace = 'public'::regnamespace and proname in ('record_email_subscription','has_email_subscription','begin_email_order') order by 1;"
```
Expected: three rows. A migration that is missing while something calls it is a live bug wearing no symptom — check `pg_proc`, not just `schema_migrations`.

- [ ] **Step 7: Run the behavioural checks to verify they pass**

Run: `supabase db query --linked --file scripts/verify-email-subscription.sql`
Expected: eight `ok` notices then `ALL CHECKS PASSED`, and the transaction rolls back.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/<version>_email_subscriptions.sql scripts/verify-email-subscription.sql
git commit -m "feat(email): lifetime free allowance plus a subscription entitlement

One free address per account for life (retroactive), then an active or
grace-period mail subscription. gmail stays a 1-credit purchase. Adds a
stated 25/day hard stop for subscribers because free-domain inventory is
scarce and shared, so a loop would drain it for everyone.

Verified behaviourally in a rolled-back transaction: 8 checks covering
first-free, the wall, gmail unaffected, active/grace/expired entitlement,
the daily cap, and the delete-account replay."
```

---

### Task 3: `verify-email-subscription` edge function

**Files:**
- Create: `supabase/functions/verify-email-subscription/index.ts`
- Modify: `supabase/functions/create-email-order/index.ts` (the refusal mapping, ~line 148-152)
- Modify: `supabase/config.toml` — **no entry**; this function keeps JWT verification (it is called by a signed-in client)

**Interfaces:**
- Consumes: `subscriptionFamily` (Task 1), `record_email_subscription` (Task 2).
- Produces: `POST /verify-email-subscription` with body `{ signed_transaction: string }` → `{ ok: true, entitled: true }`, or `{ error }` with status 400/401/409/500.

- [ ] **Step 1: Write the function**

Create `supabase/functions/verify-email-subscription/index.ts`:

```ts
// Turn a verified StoreKit mail subscription into a server-side entitlement.
//
// Much simpler than `verify-line-subscription`, and the difference is the
// whole point: a line provisions a PHYSICAL resource that bills us monthly, so
// its ordering (tombstone → row → provider → activate) exists to make a
// stranded number impossible. A mail subscription provisions nothing. The row
// IS the entitlement, so there is one write and nothing to strand.
//
// ⚠️ This function does not charge and cannot refund — Apple already has the
// money when it runs. There is nothing here that may legitimately refuse
// except a failed verification or an entitlement bound to another account.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  verifyTransactionJWS, subscriptionFamily, IapVerificationError, mailPlanLabel,
} from "../_shared/iap.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { signed_transaction?: string } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const jws = body.signed_transaction ?? "";
  if (!jws) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  // Chain-verified to Apple's PINNED root. Never decode-and-trust.
  let tx;
  try {
    tx = await verifyTransactionJWS(jws);
  } catch (e) {
    const code = e instanceof IapVerificationError ? e.code : "verification_failed";
    console.error(JSON.stringify({ alert: "mail_verify_failed", code }));
    return json({ error: "verification_failed" }, { status: 400 });
  }

  // A line subscription or a credit pack arriving here is a client routing bug,
  // and accepting it would grant the wrong entitlement.
  if (subscriptionFamily(tx.productId) !== "mail") {
    return json({ error: "unknown_product" }, { status: 400 });
  }

  // Sandbox is ACCEPTED here, deliberately and unlike `iap-verify`.
  //
  // The App Store reviewer subscribes in Sandbox. `iap-verify` gates credits on
  // Production because a Sandbox receipt is genuinely Apple-signed and costs
  // $0, so anyone could mint credits. There is no equivalent exposure here: the
  // entitlement grants addresses on domains that cost us NOTHING, and it is
  // still bounded by the subscriber daily cap. Refusing Sandbox would mean the
  // reviewer subscribes, gets nothing, and rejects the build.
  const periodEnd = tx.expiresDate ? new Date(tx.expiresDate).toISOString() : null;

  const { data: res, error } = await sb.rpc("record_email_subscription", {
    p_original_tx: tx.originalTransactionId,
    p_user: userId,
    p_product: tx.productId,
    p_state: "active",
    p_auto_renew: true,
    p_environment: tx.environment,
    p_expires_at: periodEnd,
    p_last_tx: tx.transactionId,
    p_signed_tx: jws,
    p_storefront: tx.storefront ?? null,
    p_price_milli: tx.price ?? null,
    p_currency: tx.currency ?? null,
  });
  if (error) {
    console.error(JSON.stringify({ alert: "mail_sub_record_failed", detail: error.message }));
    return json({ error: "subscription_record_failed" }, { status: 500 });
  }
  if (res?.ok !== true) {
    // `subscription_bound` is the deletion-replay catch, and it is a REFUSAL
    // rather than an error: the entitlement belongs to another account.
    return json({ error: res?.reason ?? "subscription_record_failed" }, { status: 409 });
  }

  // Claimed on (kind='mail', ref=originalTransactionId) so this alert and the
  // ASSN SUBSCRIBED branch cannot both fire — whichever arrives first sends.
  const sandbox = tx.environment !== "Production"
    ? `\n<i>${esc(tx.environment ?? "?")}</i>` : "";
  await sendMessage(
    `📬 <b>New e-mail subscription</b>\n${esc(mailPlanLabel(tx))}${sandbox}`,
    sb, tx.originalTransactionId, "mail_sub",
  ).catch(() => { /* an alert must never fail an entitlement */ });

  return json({ ok: true, entitled: true });
});
```

**Before writing this, confirm `sendMessage`'s signature** in
`supabase/functions/_shared/telegram.ts` and match it — the claim-row arguments
(`ref`, `kind`) are what make the alert exactly-once, and `telegram_events`
constrains `kind` with a CHECK — Task 2's migration widens it to include
`mail_sub` and `mail_sub_event`, so those are the only two values usable here.

- [ ] **Step 2: Surface the new refusals in `create-email-order`**

In `supabase/functions/create-email-order/index.ts`, beside the existing
`free_limit_reached` mapping (~line 150), add:

```ts
  if (res?.reason === "subscription_required") {
    return json({
      error: "subscription_required",
      used: res.used ?? null,
      grants: res.grants ?? null,
    }, { status: 402 });
  }
  if (res?.reason === "daily_cap_reached") {
    return json({ error: "daily_cap_reached", cap: res.cap ?? 25 }, { status: 429 });
  }
```

Widen the response type on the same `const res = ... as` cast to include
`used?: number; grants?: number;`.

**402 for `subscription_required`, not 429.** 429 is "you are going too fast,
wait" — which shipped builds map to a retry message. This is "payment required
and waiting will not help".

**Leave the `free_limit_reached` branch in place.** SQL no longer returns it,
but shipped 2.1 builds still map it, and deleting it only removes a fallback.

- [ ] **Step 3: Deploy and verify auth is enforced**

Commit first (see step 5), then:

```bash
supabase functions deploy verify-email-subscription create-email-order
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://enugzltysdmjzavisloy.supabase.co/functions/v1/verify-email-subscription
```
Expected: **401**. Anything else means the function was deployed with
`--no-verify-jwt` or a `config.toml` entry it must not have.

- [ ] **Step 4: Verify it rejects a non-mail product**

Using a real signed transaction for a CREDIT PACK from `iap_receipts.raw_jws`:

```bash
supabase db query --linked "select raw_jws from public.iap_receipts where environment='Production' and raw_jws is not null limit 1;"
```

POST it as `{"signed_transaction":"<jws>"}` with a valid user JWT.
Expected: **400 `unknown_product`** — a credit pack must never grant an
entitlement.

- [ ] **Step 5: Commit, then deploy (in that order)**

```bash
git add supabase/functions/verify-email-subscription/index.ts supabase/functions/create-email-order/index.ts
git commit -m "feat(email): verify-email-subscription grants the entitlement

Accepts Sandbox deliberately (the reviewer subscribes there and the
entitlement costs us nothing, unlike credits), rejects any product that is
not family 'mail', and refuses a replay bound to another account with 409
subscription_bound. create-email-order surfaces subscription_required as
402 rather than 429 — waiting does not help."
```

- [ ] **Step 6: Add it to the deploy list in CLAUDE.md**

Add `verify-email-subscription` to the **first** (JWT) deploy list in
`CLAUDE.md`, and re-assert the exhaustiveness claim:

```bash
ls supabase/functions | grep -v _shared | wc -l
```
The two lists must sum to that number. Commit with the code — a function in
neither list is a function nobody redeploys after a `_shared` change.

---

### Task 4: Mail branch in `apple-notifications`

**Files:**
- Modify: `supabase/functions/apple-notifications/index.ts` (the guard at ~line 233, plus a new branch and a new row-ensure helper)

**Interfaces:**
- Consumes: `subscriptionFamily`, `mailPlanLabel` (Task 1); `record_email_subscription` (Task 2).
- Produces: no new exports. Behaviour: mail notifications update `email_subscriptions` and never touch `phone_lines` or `line_subscriptions`.

- [ ] **Step 1: Capture the "before" snapshot for the regression check**

This is the highest-risk change in the plan and **cannot be tested in a
rolled-back transaction** — `apple-notifications` is an edge function and
commits its own writes. Snapshot first:

```bash
supabase db query --linked "select md5(string_agg(t::text, '|' order by t::text)) as lines_digest from (select * from public.phone_lines) t;"
supabase db query --linked "select md5(string_agg(t::text, '|' order by t::text)) as subs_digest from (select * from public.line_subscriptions) t;"
```
Record both digests.

- [ ] **Step 2: Replace the family guard**

At `supabase/functions/apple-notifications/index.ts:233`, replace:

```ts
  if (!isSubscriptionProduct(tx.productId)) return;   // not our line
```

with:

```ts
  // 🔴 This guard used to be `isSubscriptionProduct`, which answers a DIFFERENT
  // question. Everything below drives the phone-number lapse machine, so a mail
  // product reaching it would suspend and release a rented number when someone
  // cancelled a $2.99 e-mail plan.
  const family = subscriptionFamily(tx.productId);
  if (family === null) return;                        // a credit pack
  if (family === "mail") {
    await handleMailNotification(sb, n, tx, txJws, periodEnd);
    return;
  }
  // family === "line" — everything below is unchanged.
```

Add `subscriptionFamily` and `mailPlanLabel` to the existing import from
`../_shared/iap.ts`. Leave `isSubscriptionProduct` imported — the
`CONSUMPTION_REQUEST` branch above still uses it, and there it means exactly
what it says.

`periodEnd` is computed a few lines below the guard today; move that
computation **above** the guard so the mail branch can use it.

- [ ] **Step 3: Add the mail handler**

Add near `ensureSubscriptionRow` (~line 466):

```ts
/** Apple notifications for the MAIL subscription group.
 *
 * Deliberately much smaller than the line handler. A mail subscription has no
 * allowance to reset, no number to suspend and no provider to call — the row
 * IS the entitlement, so every notification is a state write.
 *
 * ⚠️ Every branch is an UPDATE, and an UPDATE matching nothing is not an error.
 * `ensureMailSubscriptionRow` runs first for the same reason the line handler
 * ensures its row: a notification can beat our own purchase call, and without
 * it the whole state machine would run against a row that never existed —
 * silently, forever.
 */
async function handleMailNotification(
  sb: ReturnType<typeof admin>,
  n: { notificationType: string; subtype?: string | null; notificationUUID: string },
  tx: Awaited<ReturnType<typeof verifyTransactionJWS>>,
  txJws: string,
  periodEnd: string | null,
) {
  const originalTx = tx.originalTransactionId;
  await ensureMailSubscriptionRow(sb, originalTx, tx, periodEnd, txJws);

  const type = n.notificationType;
  const sub = n.subtype ?? "";

  // The state Apple's notification implies. Mapped in one place so a new
  // notification type cannot silently fall through to "still entitled".
  let state: string | null = null;
  switch (type) {
    case "SUBSCRIBED":
    case "DID_RENEW":
      state = "active"; break;
    case "DID_FAIL_TO_RENEW":
      state = sub === "GRACE_PERIOD" ? "grace" : "billing_retry"; break;
    case "EXPIRED":
      state = "expired"; break;
    case "REFUND":
    case "REVOKE":
      state = "revoked"; break;
    case "DID_CHANGE_RENEWAL_STATUS":
      // Auto-renew off is NOT a loss of entitlement — they keep it to the end
      // of the paid period. Only the flag moves.
      state = null; break;
    default:
      // Unknown type: record it and change nothing. Guessing a state here is
      // how an entitlement gets revoked by a notification nobody understood.
      console.log(JSON.stringify({ mail_assn_unhandled: type, subtype: sub }));
      return;
  }

  const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
  if (state) patch.state = state;
  if (periodEnd) patch.expires_at = periodEnd;
  if (type === "DID_CHANGE_RENEWAL_STATUS") patch.auto_renew = sub === "AUTO_RENEW_ENABLED";
  if (type === "DID_FAIL_TO_RENEW" && sub === "GRACE_PERIOD" && periodEnd) {
    patch.grace_expires_at = periodEnd;
  }
  if (type === "REFUND" || type === "REVOKE") {
    patch.revocation_date = tx.revocationDate
      ? new Date(tx.revocationDate).toISOString() : new Date().toISOString();
    patch.revocation_reason = tx.revocationReason ?? null;
  }

  const { error } = await sb.from("email_subscriptions")
    .update(patch).eq("original_transaction_id", originalTx);
  if (error) throw new Error(`mail_subscription_update: ${error.message}`);

  // 🔴 A mail REFUND/REVOKE revokes the ENTITLEMENT and nothing else. It must
  // never touch phone_lines, wallets or credits — those belong to other
  // products, and the whole reason this handler exists is that they used to
  // share one code path.
  const sandbox = tx.environment !== "Production"
    ? `\n<i>${esc(tx.environment ?? "?")}</i>` : "";
  if (type === "SUBSCRIBED") {
    await alertOwner(
      `📬 <b>New e-mail subscription</b>\n${esc(mailPlanLabel(tx))}${sandbox}`,
      sb, originalTx, "mail_sub");
  } else if (type === "REFUND" || type === "REVOKE") {
    await alertOwner(
      `↩️ <b>E-mail subscription refunded</b>\n${esc(mailPlanLabel(tx))}${sandbox}\n` +
      `<i>Entitlement revoked. No credits or numbers are affected.</i>`,
      sb, `mailrevoke:${tx.transactionId}`, "mail_sub_event");
  }
}

/** Create the row if this notification arrived before our own purchase call.
 *  Attribution comes from an EXISTING row only — there is no mail equivalent of
 *  `phone_lines` to look a user up from, so an unattributable notification is
 *  logged and dropped rather than bound to a guessed account. */
async function ensureMailSubscriptionRow(
  sb: ReturnType<typeof admin>,
  originalTx: string,
  tx: Awaited<ReturnType<typeof verifyTransactionJWS>>,
  periodEnd: string | null,
  txJws: string,
) {
  const { data: existing, error: readErr } = await sb.from("email_subscriptions")
    .select("original_transaction_id, user_id")
    .eq("original_transaction_id", originalTx).maybeSingle();
  if (readErr) {
    console.error(JSON.stringify({
      alert: "mail_assn_lookup_failed", detail: readErr.message,
    }));
    return;
  }
  if (existing) return;

  // Unattributable: the purchase call has not landed yet. Apple retries on a
  // ladder, so throwing gets this notification redelivered after the client
  // call completes — which is the outcome we want, and is what the line
  // handler's equivalent could not do because it had a second attribution
  // source.
  console.error(JSON.stringify({
    alert: "mail_assn_unattributable", tx: originalTx,
    detail: "no email_subscriptions row yet; asking Apple to retry",
  }));
  throw new Error(`mail_assn_unattributable: ${originalTx}`);
}
```

- [ ] **Step 4: Type-check**

Run: `deno check supabase/functions/apple-notifications/index.ts`
Expected: no new errors (the `EdgeRuntime` ones are pre-existing and benign).

Confirm `tx.revocationDate` / `tx.revocationReason` exist on
`AppleTransactionPayload` in `_shared/iap.ts`; if they are named differently
there, use the real names rather than adding fields.

- [ ] **Step 5: Commit, deploy, then run the regression check**

```bash
git add supabase/functions/apple-notifications/index.ts
git commit -m "feat(email): route mail subscription notifications away from the line

Every branch after the old guard UPDATEs line_subscriptions and drives the
phone-number lapse machine, so a cancelled mail plan would have suspended
and released a rented number. Dispatch is now on subscriptionFamily().
A mail REFUND/REVOKE revokes the entitlement only."
supabase functions deploy apple-notifications --no-verify-jwt
```

Then exercise the mail path and re-check the digests. Two ways, in order of
preference:

**(a) A real Sandbox mail subscription** (available once Task 5 and Task 6 are
done): subscribe in Sandbox, then cancel it in Settings → Sandbox Account so
Apple sends `DID_CHANGE_RENEWAL_STATUS` and later `EXPIRED`.

**(b) Apple's test notification** — proves the endpoint round-trips but carries
Apple's own test product id, so it exercises the `family === null` path, not the
mail branch:

```bash
# POST /inApps/v1/notifications/test  → returns a testNotificationToken
# then GET .../test/{token} for the sendAttemptResult (SUCCESS)
```

Either way, re-read both digests and compare with Step 1:

```bash
supabase db query --linked "select md5(string_agg(t::text, '|' order by t::text)) from (select * from public.phone_lines) t;"
supabase db query --linked "select md5(string_agg(t::text, '|' order by t::text)) from (select * from public.line_subscriptions) t;"
supabase db query --linked "select notification_type, subtype, processed_at, error from public.line_notifications order by created_at desc limit 5;"
```

Expected: **both digests identical to Step 1**, and the notification row
`processed_at` set with no error. If either digest moved, stop — a mail
notification reached the line machinery, which is the exact failure this task
exists to prevent.

---

### Task 5: App Store Connect products

**Files:**
- Modify: `VirtualSIM/Products.storekit` (local StoreKit test config)
- Use: `scripts/asc-equalize-subscription-prices.py`

No app code. Do this task **before** Task 6 — a `MISSING_METADATA` product is
not returned by StoreKit even in Sandbox, so the client cannot be tested
against a half-configured product, and it looks exactly like a client bug.

- [ ] **Step 1: Create the group and products**

In App Store Connect, create subscription group **"vSMS Mail"** with an en-US
group localization, then:

| product id | reference name | duration | price |
|---|---|---|---|
| `com.anthersystems.VirtualSIM.mail.monthly` | vSMS Mail Monthly | 1 month | $2.99 |
| `com.anthersystems.VirtualSIM.mail.yearly` | vSMS Mail Yearly | 1 year | $29.99 |

Add a 3-day **free trial** introductory offer to the yearly product only.

**Order matters: create `subscriptionAvailabilities` BEFORE setting a price.**
Setting a price first returns a 409 `ENTITY_ERROR.RELATIONSHIP.INVALID`
pointing at `/data/relationships/subscriptionPricePoint/id`, which reads as a
bad price point and is not.

- [ ] **Step 2: Set prices in every territory**

Base territory **USA**. The API does not propagate a base price to other
territories (the web UI does; the API does not — measured 2026-08-06, 32
territories available and 1 priced):

```bash
python3 scripts/asc-equalize-subscription-prices.py --dry   # inspect first
python3 scripts/asc-equalize-subscription-prices.py
```

Then set **USD and EUR manually** and confirm they are the same numeral. ASC
price equalization inverted this app's credit ladder once already ($4.99 vs
€5.99 on the top revenue product).

- [ ] **Step 3: Add localization, review notes and a review screenshot**

All three are required or the product sits in `MISSING_METADATA` and StoreKit
returns nothing. Use the `-screenshot` DEBUG harness for the screenshot, as
`credits.8` did.

- [ ] **Step 4: Verify the products are actually offered**

Read the state back over the ASC API (both products):

```bash
python3 - <<'EOF'
# Uses the same ASC auth the repo's other scripts use — see
# scripts/asc-equalize-subscription-prices.py for the token helper.
# GET /v1/subscriptionGroups/<mail group id>/subscriptions
#     ?fields[subscriptions]=name,productId,state
# Print productId + state for each.
EOF
```

Expected: both products **not** `MISSING_METADATA`.

If either is, **open it in the App Store Connect web UI** — the API exposes no
reasons array anywhere on the resource, and the web page flags the missing
field in red. That is the fastest diagnosis by a wide margin, and three
hypotheses were tested and disproved the slow way once already.

⚠️ Do **not** use `POST /v1/subscriptionSubmissions` as a diagnostic. If the
metadata is in fact complete it SUBMITS, and cancelling an IAP submission
leaves the version `DEVELOPER_REJECTED` and needs the web UI to recover.

- [ ] **Step 5: Mirror them into `Products.storekit`**

Local StoreKit testing does not read ASC, so add a matching subscription group
and both products, with **the same prices** ($2.99 / $29.99) and the 3-day
trial on the yearly. These are kept in step by hand.

- [ ] **Step 6: Commit**

```bash
git add VirtualSIM/Products.storekit
git commit -m "chore(iap): local StoreKit config for the mail subscription group"
```

---

### Task 6: Client — `MailSubscriptionStore` and purchase routing

**Files:**
- Create: `VirtualSIM/IAP/MailSubscriptionStore.swift`
- Modify: `VirtualSIM/IAP/IAPStore.swift:194-206` (dispatch)
- Modify: `VirtualSIM/Networking/APIError.swift` (~line 145)
- Modify: `VirtualSIM/Networking/` — add `verifyMailSubscription` to the e-mail API type

**Interfaces:**
- Consumes: `POST /verify-email-subscription` (Task 3).
- Produces:
  - `enum MailProduct { static let monthlyId, yearlyId: String; static let allIds: [String] }`
  - `enum MailPlan: String, CaseIterable, Identifiable { case monthly, yearly }`
  - `@MainActor @Observable final class MailSubscriptionStore` with
    `var selectedPlan: MailPlan`, `private(set) var isEntitled: Bool`,
    `var lastError: String?`, `func load() async`,
    `func purchase() async -> Bool`, `func restore() async -> Bool`

- [ ] **Step 1: Add the product ids and plan enum**

Create `VirtualSIM/IAP/MailSubscriptionStore.swift` beginning with:

```swift
import Foundation
import StoreKit

/// One product id, in one place.
///
/// ⚠️ These must NEVER appear in `PRODUCT_TO_CREDITS` server-side — one entry
/// there pays out wallet credits on every renewal, forever.
enum MailProduct {
    static let monthlyId = "com.anthersystems.VirtualSIM.mail.monthly"
    /// $29.99/year with a 3-day free trial.
    static let yearlyId = "com.anthersystems.VirtualSIM.mail.yearly"

    /// 🔴 EVERY product in the group. An id missing from here is routed to the
    /// CREDITS path by `IAPStore.handle`, which sends it to `iap-verify`, which
    /// 400s it as `unknown_product` and pages the owner — for a purchase the
    /// user genuinely made and Apple genuinely charged. The server's
    /// `MAIL_SUBSCRIPTION_PRODUCT_IDS` is the mirror of this list; they must
    /// move together.
    static let allIds = [monthlyId, yearlyId]
}

/// Which plan the paywall is offering.
///
/// A SEPARATE App Store subscription group from the line. Apple allows one
/// active subscription per group, so putting these in the line group would make
/// buying e-mail replace a subscriber's phone number — and a user may
/// legitimately hold both a line and a mail subscription.
enum MailPlan: String, CaseIterable, Identifiable {
    case monthly
    case yearly

    var id: String { rawValue }
}
```

- [ ] **Step 2: Add the store**

Append to the same file:

```swift
/// The e-mail subscription: unlimited addresses on the free domains.
///
/// ── Server state is the authority ────────────────────────────────────────
///
/// `Transaction.currentEntitlements` drives UI hints only. Whether an order is
/// allowed is decided by `begin_email_order` in SQL — the device can be
/// offline, restored from a backup, or simply wrong, and an entitlement the
/// device asserts is an entitlement an attacker can assert.
///
/// ── There is still exactly ONE `Transaction.updates` listener ────────────
///
/// `IAPStore.init` claims that stream and `Transaction.updates` is not
/// multicast, so a second `for await` would split it and each listener would
/// see roughly half the transactions. This store registers a handler with
/// `IAPStore` and never opens its own.
@Observable
@MainActor
final class MailSubscriptionStore {
    /// Monthly by default: the lower commitment. Defaulting to the expensive
    /// option is a dark pattern.
    var selectedPlan: MailPlan = .monthly

    private(set) var products: [Product] = []
    /// A UI hint only — never a gate. The server decides.
    private(set) var isEntitled = false
    private(set) var isPurchasing = false
    var lastError: String?

    private var apiClient: APIClient?

    func attach(api: APIClient) { self.apiClient = api }

    func product(for plan: MailPlan) -> Product? {
        let id = plan == .monthly ? MailProduct.monthlyId : MailProduct.yearlyId
        return products.first { $0.id == id }
    }

    func load() async {
        do {
            products = try await Product.products(for: MailProduct.allIds)
        } catch {
            // A load failure is not "you are not subscribed" — leave the hint
            // untouched and let the paywall say the store is unreachable.
            lastError = String(localized: "The App Store isn't reachable right now.")
        }
        await refreshEntitlement()
    }

    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, MailProduct.allIds.contains(tx.productID) {
                isEntitled = true
                return
            }
        }
        isEntitled = false
    }

    func purchase() async -> Bool {
        guard !isPurchasing, let product = product(for: selectedPlan) else { return false }
        isPurchasing = true
        defer { isPurchasing = false }
        lastError = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                return await submit(verification)
            case .userCancelled:
                return false
            case .pending:
                lastError = String(localized: "That purchase is waiting for approval.")
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = String(localized: "That purchase didn't go through.")
            return false
        }
    }

    /// Send the signed transaction to the server, which is what actually grants
    /// the entitlement. `finish()` only after the server has recorded it —
    /// finishing first retires the transaction forever and a failed record
    /// would leave a paying user with nothing.
    func submit(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let tx) = result, let api = apiClient else { return false }
        guard let jws = jwsRepresentation(of: result) else { return false }
        do {
            try await EmailAPI(client: api).verifyMailSubscription(signedTransaction: jws)
            await tx.finish()
            isEntitled = true
            return true
        } catch {
            lastError = (error as? APIError)?.userMessage
                ?? String(localized: "Your subscription went through but we couldn't switch it on. It'll retry automatically.")
            return false
        }
    }

    private func jwsRepresentation(of result: VerificationResult<Transaction>) -> String? {
        if case .verified = result { return result.jwsRepresentation }
        return nil
    }

    func restore() async -> Bool {
        try? await AppStore.sync()
        await refreshEntitlement()
        return isEntitled
    }
}
```

- [ ] **Step 3: Route mail purchases in `IAPStore`**

In `VirtualSIM/IAP/IAPStore.swift`, beside the existing line-subscription hook
(~line 194 and 204):

```swift
    var onMailSubscription: ((VerificationResult<Transaction>) async -> Bool)?
```

and in `handle(_:)`, immediately after the existing `LineProduct.allIds` branch:

```swift
        if case .verified(let tx) = result, MailProduct.allIds.contains(tx.productID) {
            return await onMailSubscription?(result) ?? false
        }
```

**Order matters only in that both must precede the credits path.** A
subscription reaching the credits path is sent to `iap-verify`, 400s as
`unknown_product`, and pages the owner for a purchase Apple charged.

- [ ] **Step 4: Add the API call**

In the e-mail API type (`VirtualSIM/Networking/EmailAPI.swift`), add:

```swift
    /// Grants the e-mail subscription entitlement server-side.
    ///
    /// Decodes `Ack` rather than a rich response deliberately: a
    /// fire-and-forget endpoint with no client-side contract cannot break on a
    /// field rename. A struct declaring `thread_id` where the server sends
    /// `threadId` once reported "couldn't reach the server" to the user for a
    /// request that had fully succeeded — `JSONDecoder.relay` uses
    /// `.convertFromSnakeCase`, so a snake_case property name is a decode
    /// FAILURE, not a no-op.
    func verifyMailSubscription(signedTransaction: String) async throws {
        struct Body: Encodable { let signed_transaction: String }
        struct Ack: Decodable { let ok: Bool? }
        let _: Ack = try await client.request(
            .post, path: "functions/v1/verify-email-subscription",
            body: Body(signed_transaction: signedTransaction)
        )
    }
```

This matches the shape every other call in `EmailAPI` uses
(`client.request(.post, path: "functions/v1/<fn>", body: Body(...))` with a
nested `Body: Encodable`). Do not invent a different one.

- [ ] **Step 5: Add the error cases**

In `VirtualSIM/Networking/APIError.swift`, beside `free_limit_reached` (~line 145):

```swift
                case "subscription_required":
                    return String(localized: "You've used your free address. Subscribe for unlimited addresses on Outlook and Hotmail.")
                case "daily_cap_reached":
                    return String(localized: "You've hit today's limit on addresses. It resets at midnight UTC.")
```

Both strings name what is included rather than promising "unlimited e-mails" —
gmail is not part of the subscription, and free-domain stock can run dry.

- [ ] **Step 6: Build**

Run:
```bash
xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 \
  | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10
```
Expected: `** BUILD SUCCEEDED **`, no warnings.

If it fails with `cannot find 'Secrets' in scope`, this is a worktree without
the gitignored `Secrets.swift`. Copy it in — that is not your edit breaking:
```bash
cp /Users/adyl/Desktop/IOS_APPS/VirtualSIM/VirtualSIM/Networking/Secrets.swift VirtualSIM/Networking/Secrets.swift
```

- [ ] **Step 7: Commit**

```bash
git add VirtualSIM/IAP/MailSubscriptionStore.swift VirtualSIM/IAP/IAPStore.swift VirtualSIM/Networking/EmailAPI.swift VirtualSIM/Networking/APIError.swift
git commit -m "feat(email): StoreKit store for the mail subscription

Routed through IAPStore's single Transaction.updates listener rather than
opening a second one (the stream is not multicast). finish() only after the
server records the entitlement — finishing first retires the transaction
forever and a failed record would leave a paying user with nothing."
```

---

### Task 7: Client — the paywall and the order flow

**Files:**
- Create: `VirtualSIM/Screens/MailPaywallScreen.swift`
- Modify: `VirtualSIM/State/AppState.swift` — `PurchaseIntent`, the e-mail order path, `flow`'s `didSet`
- Modify: `VirtualSIM/ContentView.swift` — present the paywall, add the store to `EnvBundle`
- Modify: `VirtualSIM/Sheets/EmailDomainSheet.swift` — copy

**Interfaces:**
- Consumes: `MailSubscriptionStore` (Task 6), `subscription_required` / `daily_cap_reached` (Task 3).
- Produces: `AppState.PurchaseIntent.mailSubscription`; `AppState.showMailPaywall: Bool`.

- [ ] **Step 1: Add the intent case and its clear**

In `VirtualSIM/State/AppState.swift`, add `case mailSubscription` to
`PurchaseIntent`, and clear it in **both** places that already clear intent:

```swift
    // 🔴 The FOURTH product line, and the first three each shipped this bug:
    // the checkout draft, `checkoutEsimPlan`, and `emailMode`. An intent set at
    // `flow == nil` is never cleared by `flow`'s didSet, so it answers "how
    // many credits does this user need?" for the wrong product for the rest of
    // the session. The clear ships in the same commit as the intent.
```

Clear it in `flow`'s `didSet` alongside `checkoutEsimPlan`, **and** in
`ContentView`'s `.onChange(of: state.emailMode)` `else` branch, which is where
the `emailMode` instance of this bug was fixed.

Declare the paywall flag on `AppState` in the same edit:

```swift
    /// Raised when `create-email-order` refuses with `subscription_required`.
    /// Not a `FlowStage`: the paywall can be reached at `flow == nil` (from the
    /// domain sheet) and making it a stage would destroy an in-progress draft.
    var showMailPaywall = false
```

- [ ] **Step 2: Surface the refusal as the paywall**

In the e-mail ordering path in `AppState`, catch the new error and raise the
paywall instead of an error banner:

```swift
        } catch let err as APIError {
            if case .http(_, let body) = err,
               (body ?? "").contains("subscription_required") {
                intent = .mailSubscription
                showMailPaywall = true
                return
            }
            emailError = err.userMessage
        }
```

Match the existing catch structure in that function rather than replacing it —
`daily_cap_reached` must fall through to `userMessage`, because a subscriber
who hit the cap does **not** need a paywall.

- [ ] **Step 3: Build the paywall screen**

Create `VirtualSIM/Screens/MailPaywallScreen.swift`. Requirements, each of
which is a rule this repo has already paid for:

- **State the two domains** (`outlook.com`, `hotmail.com`) and that gmail stays
  1 credit. Never a bare "unlimited e-mails".
- **Never name the supplier.**
- Monthly preselected; show the yearly saving computed from the **live**
  `Product.displayPrice` values, not a hardcoded percentage.
- The trial is on yearly only — say "3 days free, then $29.99/year" using the
  live price string.
- Required by App Store review 3.1.2: **"Terms of Use (EULA)"** linking to
  `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` and
  **"Privacy Policy"**, link-tinted, one per line. The 2.0 rejection was
  exactly this: bare "Terms"/"Privacy" labels tinted like muted text.
- A **Restore purchases** control calling `store.restore()`.
- Handle the empty-products case explicitly — if `Product.products(for:)`
  returned nothing the product is likely `MISSING_METADATA` in ASC, and the
  screen must say the store is unavailable rather than rendering a live-looking
  disabled button.
- Use `RMotion` for animation and `.glassPanel` only if the surface floats over
  content; a sheet does not.

Skeleton — fill the body using the app's existing components (`PrimaryButton`,
`SheetHeader`, `RFont`, `theme`), not raw SwiftUI defaults:

```swift
import StoreKit
import SwiftUI

struct MailPaywallScreen: View {
    @Environment(AppState.self) private var state
    @Environment(MailSubscriptionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            SheetHeader(title: "Unlimited addresses") { dismiss() }

            // Names the domains. NEVER a bare "unlimited e-mails" — gmail is
            // not included and free-domain stock can run dry.
            Text("Create as many Outlook and Hotmail addresses as you need. Gmail stays 1 credit.")
                .font(RFont.text(15))
                .foregroundStyle(theme.sub)
                .multilineTextAlignment(.center)

            if store.products.isEmpty {
                // An empty product list almost always means MISSING_METADATA in
                // App Store Connect, not a client bug. Say the store is
                // unavailable rather than rendering a live-looking button.
                Text("The App Store isn't offering this right now. Please try again later.")
                    .font(RFont.text(14))
                    .foregroundStyle(theme.sub)
            } else {
                ForEach(MailPlan.allCases) { plan in
                    planRow(plan)
                }
                PrimaryButton(label: ctaLabel, isLoading: store.isPurchasing) {
                    Task { if await store.purchase() { dismiss() } }
                }
            }

            Button("Restore purchases") { Task { _ = await store.restore() } }
                .font(RFont.text(14))

            // Required by App Store review 3.1.2(c). The 2.0 rejection was
            // exactly this: bare "Terms"/"Privacy" labels tinted like muted
            // text. Full names, link-tinted, one per line.
            VStack(spacing: 6) {
                Link("Terms of Use (EULA)",
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy Policy",
                     destination: URL(string: "https://vsmsapp.com/privacy")!)
            }
            .font(RFont.text(13))
            .tint(theme.ink)
        }
        .padding(20)
        .task { await store.load() }
    }

    /// Computed from the LIVE prices, never hardcoded — a percentage that
    /// disagrees with the store is a claim we cannot keep.
    private var yearlySavingsPercent: Int? {
        guard let m = store.product(for: .monthly)?.price,
              let y = store.product(for: .yearly)?.price, m > 0 else { return nil }
        let full = m * 12
        guard full > y else { return nil }
        return Int((((full - y) / full) as NSDecimalNumber).doubleValue * 100)
    }

    private var ctaLabel: String {
        guard let p = store.product(for: store.selectedPlan) else {
            return String(localized: "Subscribe")
        }
        // The trial is on the YEARLY plan only — saying "3 days free" on the
        // monthly would be false.
        if store.selectedPlan == .yearly, p.subscription?.introductoryOffer != nil {
            return String(localized: "Start 3 days free, then \(p.displayPrice)/year")
        }
        return String(localized: "Subscribe — \(p.displayPrice)")
    }

    @ViewBuilder
    private func planRow(_ plan: MailPlan) -> some View {
        // Selectable row: plan name, live displayPrice, and the saving badge on
        // yearly when `yearlySavingsPercent` is non-nil.
        EmptyView()   // replace with the app's card treatment
    }
}
```

`planRow` is the only part left to design freehand; everything above it is
load-bearing and should be kept as written. Confirm `theme.sub` / `theme.ink`
and `PrimaryButton`'s real parameter labels against the existing sheets before
building — match them rather than adding new ones.

- [ ] **Step 4: Present it**

In `ContentView.swift`, present `MailPaywallScreen` on `state.showMailPaywall`,
and add `MailSubscriptionStore` to the **`EnvBundle`** modifier. Cover and sheet
content does **not** inherit `@Observable` environment objects from the
presenter — without `EnvBundle` the paywall crashes or renders empty.

Wire the store up where `SubscriptionStore` is wired: `store.attach(api:)`, and
`iapStore.onMailSubscription = { [weak store] in await store?.submit($0) ?? false }`.

- [ ] **Step 5: Update the domain sheet copy**

In `EmailDomainSheet`, the free domains must no longer imply a daily allowance.
Show the entitlement state: subscribed → "Included", not subscribed with the
free address unused → "Free", used → "Subscription". Keep gmail's "1 credit"
unchanged for everyone.

- [ ] **Step 6: Build**

Run the `xcodebuild` command from Task 6 Step 6.
Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 7: Verify the flow in the simulator**

Launch with the local StoreKit configuration (scheme → Options → StoreKit
Configuration → `Products.storekit`), then:

1. Order a free address → succeeds, code screen appears.
2. Order a second free address → the **paywall** appears, not an error banner.
3. Purchase monthly in the local StoreKit sheet → the order retries and succeeds.
4. Force-quit, relaunch, order again → still allowed (server state, not device).

Step 4 is the one that matters: it is the only step that proves the entitlement
is server-side.

- [ ] **Step 8: Commit**

```bash
git add VirtualSIM/Screens/MailPaywallScreen.swift VirtualSIM/State/AppState.swift VirtualSIM/ContentView.swift VirtualSIM/Sheets/EmailDomainSheet.swift
git commit -m "feat(email): paywall after the free address is used

The offer appears on the SECOND free-address attempt, never over the code —
the user sees the product work before being asked to pay. PurchaseIntent
gains .mailSubscription with its clear in the same commit, because the
previous three product lines each shipped that bug."
```

---

### Task 8: Move the review prompt off the code screen

Independent of every other task — it can ship alone.

**Files:**
- Modify: `VirtualSIM/Screens/OtpScreen.swift:96-103`
- Modify: `VirtualSIM/Screens/EmailCodeScreen.swift:82-87`
- Modify: `VirtualSIM/State/AppState.swift` — `reviewableRecentDelivery()` (~line 693)
- Modify: `VirtualSIM/ContentView.swift:322-329`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppState.suppressReviewThisSession: Bool`.

- [ ] **Step 1: Remove the on-screen prompts**

In `OtpScreen.swift`, delete the `guard state.shouldRequestReview(...)` block
and its `requestReview()` call, and the now-unused
`@Environment(\.requestReview)`. Do the same in `EmailCodeScreen.swift`
(including the 900ms sleep that existed only to delay it).

Leave `shouldRequestReview` itself untouched — every gate (once per app
version, per-order dedupe, `ScreenshotMode`) lives there and
`reviewableRecentDelivery` calls it.

- [ ] **Step 2: Add the same-session suppression**

In `AppState`:

```swift
    /// A review prompt and the subscription paywall must never appear in the
    /// same session. Both are interruptions asking for something; stacking them
    /// spends Apple's ~3-prompts-per-year quota on a user who was just told
    /// they have to pay, which is the worst possible moment to ask for five
    /// stars. Whichever fires first suppresses the other until the next cold
    /// launch. Deliberately NOT persisted — "session" means this launch.
    var suppressReviewThisSession = false
```

Set it to `true` where `showMailPaywall` is set (Task 7 Step 2), and check it
first in `reviewableRecentDelivery()`:

```swift
    func reviewableRecentDelivery() -> Bool {
        guard !suppressReviewThisSession else { return false }
        // ... existing body unchanged
```

- [ ] **Step 3: Confirm the foreground path is the only one left**

Run:
```bash
grep -rn "requestReview()" VirtualSIM | grep -v Binary
```
Expected: exactly **one** call site, in `ContentView.swift`'s foreground
handler. Any other result means a prompt was left behind.

- [ ] **Step 4: Build**

Run the `xcodebuild` command from Task 6 Step 6.
Expected: `** BUILD SUCCEEDED **`, no warnings — including no
"unused variable" warning from a leftover `@Environment(\.requestReview)`.

- [ ] **Step 5: Commit**

```bash
git add VirtualSIM/Screens/OtpScreen.swift VirtualSIM/Screens/EmailCodeScreen.swift VirtualSIM/State/AppState.swift VirtualSIM/ContentView.swift
git commit -m "fix(review): prompt on the next foreground, not over the code

Firing ~0.9s after the code renders is precisely when the user is leaving to
paste it somewhere else — a near-guaranteed dismissal that also burns one of
Apple's ~3 prompts per user per year. The foreground path already existed for
lock-screen readers and is now the only one. A review prompt and the paywall
never appear in the same session."
```

---

### Task 9: Ops visibility and documentation

**Files:**
- Modify: `supabase/functions/_shared/opsFormat.ts` — `/subs` formatter
- Create: `supabase/migrations/<version>_ops_subs_mail.sql` — extend `ops_subs()`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `email_subscriptions` (Task 2).
- Produces: `ops_subs()` gains a `mail` key.

- [ ] **Step 1: Extend `ops_subs()`**

Add to the returned JSONB, alongside the existing line keys:

```sql
    'mail', jsonb_build_object(
      'total',    (select count(*) from public.email_subscriptions),
      'active',   (select count(*) from public.email_subscriptions
                    where state in ('active','grace')
                      and coalesce(grace_expires_at, expires_at) > now()),
      'by_state', (select coalesce(jsonb_agg(jsonb_build_object('state', state, 'n', n)), '[]'::jsonb)
                     from (select state, count(*) n from public.email_subscriptions
                            group by 1 order by 2 desc) s),
      'auto_renew_on', (select count(*) from public.email_subscriptions
                         where auto_renew and state in ('active','grace'))
    )
```

Regenerate the function from `pg_get_functiondef` and **diff it clause by
clause** before applying. Rebuilding a function from a dump has silently
dropped a whole branch in this repo once (`run_watchdog`), and the dump is
truncated by most tooling.

- [ ] **Step 2: Render it in `/subs`**

In `_shared/opsFormat.ts`, add a mail block to the `/subs` formatter mirroring
the line block, including the **disagreement warning** — for mail that is
"entitled subscribers vs active subscriptions", which should be equal.

- [ ] **Step 3: Verify**

```bash
supabase db query --linked "select jsonb_pretty(public.ops_subs()->'mail');"
```
Expected: the four keys, `total: 0` before any purchase.

Then `/subs` in Telegram: expected to render the mail block without altering
the line block.

- [ ] **Step 4: Update CLAUDE.md**

In the same commit, add:

- A **"Temp-e-mail subscription"** section under the e-mail line: the two
  products, the lifetime-and-retroactive free rule, `email_free_lifetime_grants`
  / `email_sub_daily_cap`, and that gmail is excluded.
- The `subscriptionFamily` trap in **Non-obvious gotchas**: `isSubscriptionProduct`
  means "not a credit pack" to `iap-verify` and meant "this is a line" to
  `apple-notifications`, and mail products must be included in one and excluded
  from the other.
- **A second subscription group is mandatory** — one active subscription per
  group, so mail in the line group would replace a $9.99 number.
- `verify-email-subscription` in the JWT deploy list, with the totals
  re-asserted against `ls supabase/functions | grep -v _shared | wc -l`.
- Under **Known-open**: the accepted risk that a retroactive lifetime wall ends
  the app's highest-volume surface (177 orders / 54 users / 158 free in the 14
  days to 2026-08-19), and the two reversal levers — the *number* is live config,
  the *per-day rule* is a migration.
- Under **Known-open**: "unlimited" depends on free-domain stock, which runs dry,
  and gmail is excluded — undecided whether subscribers get a gmail fallback.
- Under **Known-open**: `revenue_snapshot` counts credit packs only — it already
  omits LINE subscription revenue, and now omits mail subscription revenue too.
  Pre-existing and deliberately out of scope here, recorded so it is not
  silently inherited: `/revenue` and `/profit` understate by every subscription
  dollar.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/<version>_ops_subs_mail.sql supabase/functions/_shared/opsFormat.ts CLAUDE.md
git commit -m "feat(ops): mail subscriptions in /subs, and document the line

Docs ship with the code: a stale CLAUDE.md is read as current and turns a
documentation error into a decision error."
```

- [ ] **Step 6: Redeploy every consumer of the changed `_shared` files**

`_shared/*` is bundled **per function** at deploy time, so a fix is not in
production until every consumer is redeployed — a bundle diff once found three
functions running a pre-fix `providers.ts` weeks after the source was corrected.

`iap.ts` changed in Task 1 and `opsFormat.ts` in this task. Redeploy both
groups (idempotent, ~1 min):

```bash
supabase functions deploy create-order check-order cancel-order register-push iap-verify delete-account \
  create-esim-order check-esim-usage redeem-referral \
  create-email-order check-email-order email-domains support-send \
  search-line-numbers reserve-line-number verify-line-subscription rent-line-credits \
  send-line-message line-thread-action mint-line-token begin-line-call report-line-call \
  record-attribution verify-email-subscription

supabase functions deploy poll-active-orders sync-prices sync-5sim sync-herosms \
  sync-esim-plans sync-smspva-operators sync-smspva-conversions winback \
  telegram-notify telegram-webhook daily-credit telegram-setup goodwill-credit \
  broadcast-push telnyx-webhook apple-notifications release-lines sync-telnyx-cdr \
  sync-line-voice probe-telnyx-connection \
  --no-verify-jwt
```

Then assert the JWT flags landed:

```
telegram-webhook          unauthenticated POST -> 200   (its own silent rejection)
sync-herosms              no x-cron-secret     -> 403
verify-email-subscription no auth              -> 401
```

---

## Release checklist (after all tasks)

- [ ] `scripts/verify-subscription-families.ts` passes
- [ ] `scripts/verify-email-subscription.sql` passes (8 checks)
- [ ] `phone_lines` and `line_subscriptions` digests unchanged by a mail notification
- [ ] `xcodebuild` succeeds with no warnings
- [ ] Both ASC products out of `MISSING_METADATA`
- [ ] A Sandbox purchase of each plan grants the entitlement, and cancelling the
      yearly trial expires it via ASSN
- [ ] `CLAUDE.md` deploy lists sum to `ls supabase/functions | grep -v _shared | wc -l`
- [ ] Decide the open question: gmail fallback for subscribers when free stock
      is dry, or copy that never promises availability
