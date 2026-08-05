-- Rentable second phone numbers — the FOURTH product line.
--
-- A number the user KEEPS: rented monthly, used to send and receive both SMS
-- and voice calls inside the app. Provider is Telnyx. See CLAUDE.md.
--
-- Four properties of this line differ from the other three, and every one of
-- them is deliberate:
--
-- ── 1. It never touches the credit wallet ──────────────────────────────────
-- Billing is an auto-renewable StoreKit subscription with a HARD-STOP monthly
-- allowance — no per-message charge, no overage, no refund path. So there are
-- no `wallet_*` calls, no ledger FK column, and no new `wallet_reason` value.
-- That deletes the surface this codebase has got wrong more than any other:
-- "a status claim and its refund must be ONE transaction", which seven paths
-- violated across 2026-07-31 and 08-02. Money here is 100% Apple's.
-- KEEP IT THAT WAY. If overage credits are ever added, they need a ledger FK
-- plus a partial unique index on `reason='refund'`, exactly like email/eSIM.
--
-- ── 2. ONE live line per user, enforced by an index ────────────────────────
-- Apple permits one active subscription per subscription group and
-- auto-renewables have no quantity on iOS. The subscription IS the line.
-- `phone_lines_one_live_per_user` is that product constraint made physical.
-- The schema stays multi-line-ready (a table, not a column on `profiles`);
-- the future path is TIERS inside the one group, never a second group.
--
-- ── 3. `line_subscriptions` has NO foreign key to auth.users ───────────────
-- This is the fourth grant, and CLAUDE.md's most-repeated money bug applies
-- with teeth. Everything user-scoped cascades on Delete Account — which Apple
-- MANDATES — so without a cascade-free tombstone the replay is:
--   subscribe -> get number -> delete account -> sign in again ->
--   Transaction.currentEntitlements still returns the live subscription ->
--   we provision a SECOND Telnyx number while the first bills us forever with
--   no row pointing at it.
-- Unlike the three credit grants, the loss here is RECURRING and invisible
-- until the invoice. `original_transaction_id` as a PK on a cascade-free
-- table is the tombstone; `line_renewals` is the same idea per renewal.
--
-- ── 4. Every status enum gets an `unknown` fallback in Swift ───────────────
-- iOS `OrderStatus` is a plain String enum with no unknown case, so a new PG
-- value throws on decode and breaks the whole tab for every shipped build —
-- which is why `begin_order` had to write a semantically wrong 'waiting'.
-- The Swift mirrors of the enums below MUST ship a custom `init(from:)` with
-- an `unknown` case in the first client commit, or this line inherits the
-- same client-first-schema-second release ordering forever.
--
-- ── `code`/`otp`-style authority rule, restated for this line ──────────────
-- A message exists when there is a row, not when a vendor status says so.
-- `line_messages.provider_message_id` is the idempotency key: Telnyx RETRIES
-- webhooks, and without the unique index a retry duplicates the message in
-- the user's thread.

-- ── 1. Enums ───────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_type where typname = 'line_status') then
    create type public.line_status as enum (
      'provisioning', -- row exists, Telnyx number order not yet complete
      'active',       -- paid and fully usable
      'grace',        -- Apple billing grace; service stays FULLY live
      'past_due',     -- billing retry, no grace; receive-only
      'suspended',    -- grace/retry over; held for `hold_until` before release
      'releasing',    -- claimed by the reclaim sweep, Telnyx DELETE pending
      'released',     -- number handed back; history stays readable
      'failed'        -- never got a number out of the provider
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'line_msg_direction') then
    create type public.line_msg_direction as enum ('inbound', 'outbound');
  end if;

  if not exists (select 1 from pg_type where typname = 'line_msg_status') then
    create type public.line_msg_status as enum (
      'queued', 'sending', 'sent', 'delivered', 'failed', 'received');
  end if;

  if not exists (select 1 from pg_type where typname = 'line_call_direction') then
    create type public.line_call_direction as enum ('inbound', 'outbound');
  end if;

  if not exists (select 1 from pg_type where typname = 'line_call_status') then
    create type public.line_call_status as enum (
      'ringing', 'answered', 'completed', 'missed', 'busy', 'failed', 'canceled');
  end if;

  if not exists (select 1 from pg_type where typname = 'line_sub_state') then
    create type public.line_sub_state as enum (
      'active', 'grace', 'billing_retry', 'expired', 'revoked', 'canceled_pending');
  end if;
end $$;

-- ── 2. phone_lines — the rented line ───────────────────────────────────────
create table if not exists public.phone_lines (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references auth.users(id) on delete cascade,
  provider                  text not null default 'telnyx',

  -- Telnyx identifiers. Per-line connection/profile isolation is the whole
  -- point: inbound to a DID rings only registrations on THAT DID's connection,
  -- so user A can never be rung for user B's number.
  provider_number_id        text,
  provider_order_id         text,   -- number_orders id; the buy is ASYNCHRONOUS
  provider_connection_id    text,
  provider_msg_profile_id   text,
  provider_voice_profile_id text,
  provider_credential_id    text,   -- on-demand telephony credential; DELETE on lapse

  e164                      text,
  country_code              text not null,
  number_type               text not null default 'toll_free'
                              check (number_type in ('local', 'toll_free')),
  status                    public.line_status not null default 'provisioning',

  -- The join to Apple. Not a FK — line_subscriptions is deliberately
  -- cascade-free (see header).
  original_transaction_id   text,

  monthly_cost_cents        integer,   -- what TELNYX charges US. Never client-visible.
  current_period_start      timestamptz,
  current_period_end        timestamptz,
  grace_until               timestamptz,
  hold_until                timestamptz,  -- reclaim deadline once suspended

  -- Hard-stop allowance. Reset by apply_line_renewal, NEVER on a calendar
  -- boundary — a calendar reset hands a mid-month subscriber a free extra
  -- allowance every time they subscribe near the end of a month.
  sms_allowance             integer not null default 200 check (sms_allowance >= 0),
  sms_used                  integer not null default 0 check (sms_used >= 0),
  voice_allowance_seconds   integer not null default 6000 check (voice_allowance_seconds >= 0),
  voice_used_seconds        integer not null default 0 check (voice_used_seconds >= 0),
  allowance_period_start    timestamptz not null default now(),

  -- Emergency calling is DISABLED and disclosed. Blocked client-side, in
  -- place-line-call, and on the outbound voice profile. A column rather than a
  -- constant so enabling it later (with a user address, E911 registration and
  -- a privacy-policy change) is per-line rather than global.
  emergency_disabled        boolean not null default true,

  created_at                timestamptz not null default now(),
  activated_at              timestamptz,
  released_at               timestamptz,
  updated_at                timestamptz not null default now()
);

-- THE product constraint from the header, made physical. 'released' and
-- 'failed' are excluded so a user can rent again after a lapse.
create unique index if not exists phone_lines_one_live_per_user
  on public.phone_lines (user_id)
  where status in ('provisioning','active','grace','past_due','suspended','releasing');

-- One live line per number, and one row per Telnyx number ever.
create unique index if not exists phone_lines_e164_live_key
  on public.phone_lines (e164)
  where e164 is not null and status not in ('released', 'failed');
create unique index if not exists phone_lines_provider_number_key
  on public.phone_lines (provider_number_id)
  where provider_number_id is not null;

-- Drives reconcile-subscriptions (renewal window) and the reclaim sweep.
create index if not exists phone_lines_renewal_idx
  on public.phone_lines (status, current_period_end);
create index if not exists phone_lines_hold_idx
  on public.phone_lines (status, hold_until)
  where status in ('suspended', 'releasing');
-- ASSN arrives keyed on the Apple transaction, never on our line id.
create index if not exists phone_lines_original_tx_idx
  on public.phone_lines (original_transaction_id)
  where original_transaction_id is not null;

alter table public.phone_lines enable row level security;

-- NO policy, and SELECT revoked outright: clients read `my_line` instead.
-- RLS is row-level and cannot restrict COLUMNS, and this table holds
-- `monthly_cost_cents` plus every Telnyx internal id. An explicit `select=`
-- list in LineAPI is a convention, not enforcement — CLAUDE.md documents
-- `select=*` leaking the wholesale cost book on `routes` and `esim_plans`,
-- both of which are still outstanding precisely because the client shipped
-- first. Do not repeat that here.
--
-- NOTE the ALTER DEFAULT PRIVILEGES gotcha: new tables are granted SELECT to
-- anon/authenticated automatically, so this revoke is load-bearing, not
-- decorative.
revoke all on public.phone_lines from anon, authenticated;

-- ── 3. my_line — the ONLY client-facing projection ─────────────────────────
-- Deliberately NOT `security_invoker = true`. An invoker-rights view would
-- need the caller to hold SELECT on phone_lines, which is exactly what we just
-- revoked to hide the cost columns. This view runs with owner rights (the PG15
-- default), so its WHERE clause IS the security boundary — which is why it is
-- written against `(select auth.uid())` and must never be widened.
drop view if exists public.my_line;
create view public.my_line as
  select id, e164, country_code, number_type, status,
         current_period_start, current_period_end, grace_until, hold_until,
         sms_allowance, sms_used, voice_allowance_seconds, voice_used_seconds,
         allowance_period_start, emergency_disabled,
         created_at, activated_at, released_at
    from public.phone_lines
   where user_id = (select auth.uid());

grant select on public.my_line to authenticated;
revoke all on public.my_line from anon;

-- ── 4. line_subscriptions — Apple state, cascade-free by design ────────────
create table if not exists public.line_subscriptions (
  original_transaction_id   text primary key,
  -- Deliberately NOT `references auth.users`. See the header: a FK here is
  -- precisely what would delete the tombstone along with the account and
  -- re-open the double-provision replay.
  user_id                   uuid not null,
  product_id                text not null,
  state                     public.line_sub_state not null,
  auto_renew                boolean not null default true,
  environment               text not null,
  expires_at                timestamptz,
  grace_expires_at          timestamptz,
  last_transaction_id       text,
  -- Raw JWS of the latest transaction, so revenue_snapshot can decode the
  -- REAL billed price/currency/storefront with the existing jws_payload().
  -- A hardcoded USD ladder mis-states revenue; see 20260727230000.
  latest_signed_transaction text,
  revocation_date           timestamptz,
  revocation_reason         integer,
  storefront                text,
  price_milli               bigint,
  currency                  text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create index if not exists line_subscriptions_user_idx
  on public.line_subscriptions (user_id);
create index if not exists line_subscriptions_expiry_idx
  on public.line_subscriptions (state, expires_at);

alter table public.line_subscriptions enable row level security;
revoke all on public.line_subscriptions from anon, authenticated;

-- Renewal tombstone. Same cascade-free rule, same reason: an idempotency
-- record that disappears with the account is not an idempotency record.
create table if not exists public.line_renewals (
  transaction_id          text primary key,
  original_transaction_id text not null,
  applied_at              timestamptz not null default now()
);
alter table public.line_renewals enable row level security;
revoke all on public.line_renewals from anon, authenticated;

-- Raw ASSN payloads, keyed on Apple's notificationUUID and written BEFORE we
-- act on them: idempotency plus a forensic trail for when our state machine
-- and Apple's disagree.
create table if not exists public.line_notifications (
  notification_uuid text primary key,
  notification_type text,
  subtype           text,
  original_transaction_id text,
  raw_payload       text not null,
  processed_at      timestamptz,
  process_error     text,
  created_at        timestamptz not null default now()
);
create index if not exists line_notifications_unprocessed_idx
  on public.line_notifications (created_at)
  where processed_at is null;
alter table public.line_notifications enable row level security;
revoke all on public.line_notifications from anon, authenticated;

-- ── 5. Threads, messages, calls ────────────────────────────────────────────
create table if not exists public.line_threads (
  id              uuid primary key default gen_random_uuid(),
  line_id         uuid not null references public.phone_lines(id) on delete cascade,
  -- Denormalised so RLS is a single-column predicate with no join.
  user_id         uuid not null references auth.users(id) on delete cascade,
  peer_e164       text not null,
  last_message_at timestamptz,
  last_preview    text,
  unread_count    integer not null default 0 check (unread_count >= 0),
  -- App Review 1.2 requires block/report on any surface displaying content
  -- from arbitrary third parties. It also doubles as inbound-flood defence.
  blocked         boolean not null default false,
  created_at      timestamptz not null default now(),
  unique (line_id, peer_e164)
);
create index if not exists line_threads_user_idx
  on public.line_threads (user_id, last_message_at desc nulls last);

create table if not exists public.line_messages (
  id                  uuid primary key default gen_random_uuid(),
  thread_id           uuid not null references public.line_threads(id) on delete cascade,
  line_id             uuid not null references public.phone_lines(id) on delete cascade,
  user_id             uuid not null references auth.users(id) on delete cascade,
  direction           public.line_msg_direction not null,
  provider_message_id text,
  e164_from           text not null,
  e164_to             text not null,
  body                text,
  status              public.line_msg_status not null,
  segments            integer not null default 1 check (segments > 0),
  provider_cost_cents integer,
  error_code          text,
  sent_at             timestamptz,
  received_at         timestamptz,
  created_at          timestamptz not null default now()
);
-- THE inbound-webhook idempotency guard. Telnyx retries; without this a retry
-- duplicates the message in the user's thread and re-fires the push.
create unique index if not exists line_messages_provider_key
  on public.line_messages (provider_message_id)
  where provider_message_id is not null;
create index if not exists line_messages_thread_idx
  on public.line_messages (thread_id, created_at desc);
create index if not exists line_messages_line_idx
  on public.line_messages (line_id, created_at desc);

create table if not exists public.line_calls (
  id                       uuid primary key default gen_random_uuid(),
  line_id                  uuid not null references public.phone_lines(id) on delete cascade,
  user_id                  uuid not null references auth.users(id) on delete cascade,
  direction                public.line_call_direction not null,
  peer_e164                text not null,
  provider_call_session_id text,
  provider_call_leg_id     text,
  status                   public.line_call_status not null,
  started_at               timestamptz,
  answered_at              timestamptz,
  ended_at                 timestamptz,
  -- What the CLIENT reported. Advisory only, never the billing source: a
  -- client can be wrong, killed, or lying.
  duration_seconds         integer,
  -- What the CDR says. This is the billing truth, and it arrives minutes late.
  billed_seconds           integer,
  -- Allowance reserved at call start, so settle_line_allowance can adjust by
  -- the difference rather than double-counting.
  reserved_seconds         integer not null default 0,
  allowance_settled        boolean not null default false,
  provider_cost_cents      integer,
  hangup_cause             text,
  created_at               timestamptz not null default now()
);
create unique index if not exists line_calls_session_key
  on public.line_calls (provider_call_session_id)
  where provider_call_session_id is not null;
create index if not exists line_calls_user_idx
  on public.line_calls (user_id, created_at desc);
create index if not exists line_calls_unsettled_idx
  on public.line_calls (created_at)
  where allowance_settled = false;

-- RLS: self-read only, in the `(select auth.uid())` form that
-- 20260716000200_perf_rls_and_fk_indexes.sql standardised for the planner.
-- Every write goes through a SECURITY DEFINER function or the service role.
do $$
declare t text;
begin
  foreach t in array array['line_threads', 'line_messages', 'line_calls'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "%s: self read" on public.%I', t, t);
    execute format(
      'create policy "%s: self read" on public.%I for select to authenticated '
      'using (user_id = (select auth.uid()))', t, t);
    execute format(
      'revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- ── 6. Telegram alert kinds ────────────────────────────────────────────────
-- telegram_events is the exactly-once claim row, written BEFORE sending, and
-- it is CHECK-constrained — so a kind the constraint does not admit fails the
-- insert, and that is exactly how an alert goes missing with no trace.
alter table public.telegram_events drop constraint if exists telegram_events_kind_check;
alter table public.telegram_events add constraint telegram_events_kind_check
  check (kind = any (array[
    'signup'::text, 'purchase'::text, 'esim'::text, 'email'::text,
    'line'::text, 'line_refund'::text, 'line_orphan'::text,
    'line_provision_failed'::text]));

-- ── 7. Kill switch ─────────────────────────────────────────────────────────
-- Mirrors set_esim_paused (20260731050000). Pausing stops SALES only:
-- create-line-rental refuses independently so a cached client cannot bypass
-- it, while send-line-message, mint-line-token and the webhook keep serving
-- existing lines. That distinction is what made the eSIM pause safe, and it
-- matters more here because these people have an active recurring charge.
create or replace function public.set_lines_paused(p_paused boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_active integer;
begin
  insert into public.app_config (key, value)
  values ('lines_paused', to_jsonb(p_paused))
  on conflict (key) do update set value = excluded.value;

  select count(*) into v_active
    from public.phone_lines
   where status in ('active', 'grace', 'past_due');

  -- Returning the live count makes "resuming did nothing" visible rather than
  -- looking like success — the same reason set_esim_paused reports
  -- plans_active.
  return jsonb_build_object('paused', p_paused, 'active_lines', v_active);
end;
$fn$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC and anon/authenticated are members
-- of PUBLIC, so revoking from anon/authenticated alone is a NO-OP.
revoke execute on function public.set_lines_paused(boolean) from public, anon, authenticated;

insert into public.app_config (key, value)
values ('lines_paused', to_jsonb(true))
on conflict (key) do nothing;

-- The client reads this flag to render "unavailable" rather than an empty
-- screen. app_config's read policy is an explicit key WHITELIST and must
-- NEVER become `using (true)` — that would publish provider balances and the
-- watchdog verdict to anyone holding the publishable key.
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config
  for select to authenticated
  using (key = any (array['maintenance', 'announcement', 'esim_paused', 'lines_paused']));

-- ── 8. Allowance ───────────────────────────────────────────────────────────
-- The single place allowance is decided. Strict: refuses rather than
-- overshooting. Voice reserves at call start and settles from the CDR.
create or replace function public.consume_line_allowance(
  p_line uuid, p_kind text, p_units integer
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_used integer; v_allow integer; v_status public.line_status;
begin
  if p_units is null or p_units < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if p_kind not in ('sms', 'voice') then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select status,
         case when p_kind = 'sms' then sms_used  else voice_used_seconds      end,
         case when p_kind = 'sms' then sms_allowance else voice_allowance_seconds end
    into v_status, v_used, v_allow
    from public.phone_lines where id = p_line for update;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;
  -- 'grace' is fully live on purpose: Apple is still retrying the charge and
  -- cutting service during billing grace is how you turn a card expiry into
  -- a churned customer.
  if v_status not in ('active', 'grace') then
    return jsonb_build_object('ok', false, 'reason', 'line_suspended',
                              'status', v_status);
  end if;

  if v_used + p_units > v_allow then
    return jsonb_build_object('ok', false, 'reason', 'allowance_exhausted',
                              'used', v_used, 'allowance', v_allow,
                              'remaining', greatest(v_allow - v_used, 0));
  end if;

  if p_kind = 'sms' then
    update public.phone_lines
       set sms_used = sms_used + p_units, updated_at = now()
     where id = p_line;
  else
    update public.phone_lines
       set voice_used_seconds = voice_used_seconds + p_units, updated_at = now()
     where id = p_line;
  end if;

  return jsonb_build_object('ok', true,
                            'remaining', greatest(v_allow - v_used - p_units, 0));
end;
$fn$;
revoke execute on function public.consume_line_allowance(uuid, text, integer)
  from public, anon, authenticated;

-- Adjusts a reservation to the real figure once the CDR lands. Overshoot is
-- ALLOWED here and nowhere else: the CDR arrives minutes after the call, so a
-- single call can exceed the allowance. That is accepted deliberately — the
-- alternative is putting an edge function on the ring path.
create or replace function public.settle_line_allowance(
  p_line uuid, p_kind text, p_actual integer, p_reserved integer
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_delta integer;
begin
  v_delta := coalesce(p_actual, 0) - coalesce(p_reserved, 0);
  if v_delta = 0 then return true; end if;

  if p_kind = 'sms' then
    update public.phone_lines
       set sms_used = greatest(sms_used + v_delta, 0), updated_at = now()
     where id = p_line;
  else
    update public.phone_lines
       set voice_used_seconds = greatest(voice_used_seconds + v_delta, 0),
           updated_at = now()
     where id = p_line;
  end if;
  return found;
end;
$fn$;
revoke execute on function public.settle_line_allowance(uuid, text, integer, integer)
  from public, anon, authenticated;

-- ── 9. Rental lifecycle ────────────────────────────────────────────────────
-- Returns {ok, reason, ...} — NOT {status, ...}. begin_order returns the
-- latter and the drift already shipped as a bug; every function added since
-- pins this shape.
create or replace function public.begin_line_rental(
  p_user uuid, p_e164 text, p_country text, p_number_type text,
  p_original_tx text, p_product text
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_line uuid;
  v_existing uuid;
  v_bound uuid;
  v_paused boolean;
begin
  if p_user is null or p_e164 is null or p_country is null
     or p_original_tx is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select coalesce((value #>> '{}')::boolean, false) into v_paused
    from public.app_config where key = 'lines_paused';
  if coalesce(v_paused, false) then
    return jsonb_build_object('ok', false, 'reason', 'lines_paused');
  end if;

  -- Serialise per user, as begin_order / begin_esim_order / begin_email_order
  -- all do. The live-line check below is only meaningful under this lock.
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id into v_existing from public.phone_lines
   where user_id = p_user
     and status in ('provisioning','active','grace','past_due','suspended','releasing')
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'line_exists',
                              'line_id', v_existing);
  end if;

  -- THE account-deletion replay check. The subscription tombstone survives
  -- Delete Account, so a returning user presenting the same Apple entitlement
  -- is caught here instead of getting a second number billed to us forever.
  select user_id into v_bound from public.line_subscriptions
   where original_transaction_id = p_original_tx;
  if v_bound is not null and v_bound <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'subscription_bound');
  end if;

  -- Row BEFORE any provider call, so a Telnyx failure can never leave a
  -- purchased number with nothing pointing at it. This is the ordering
  -- begin_order was rewritten into after 258 spends pointed at 126 orders —
  -- and here the stranded resource is a recurring monthly charge.
  insert into public.phone_lines (
    user_id, e164, country_code, number_type, status, original_transaction_id)
  values (p_user, p_e164, p_country, coalesce(p_number_type, 'toll_free'),
          'provisioning', p_original_tx)
  returning id into v_line;

  return jsonb_build_object('ok', true, 'line_id', v_line);
end;
$fn$;
revoke execute on function public.begin_line_rental(uuid, text, text, text, text, text)
  from public, anon, authenticated;

create or replace function public.activate_line_claim(
  p_line uuid, p_number_id text, p_connection text, p_msg_profile text,
  p_voice_profile text, p_credential text, p_period_end timestamptz,
  p_monthly_cost_cents integer
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_status public.line_status;
begin
  select status into v_status from public.phone_lines where id = p_line for update;
  if not found or v_status <> 'provisioning' then return false; end if;

  update public.phone_lines
     set provider_number_id        = coalesce(p_number_id, provider_number_id),
         provider_connection_id    = coalesce(p_connection, provider_connection_id),
         provider_msg_profile_id   = coalesce(p_msg_profile, provider_msg_profile_id),
         provider_voice_profile_id = coalesce(p_voice_profile, provider_voice_profile_id),
         provider_credential_id    = coalesce(p_credential, provider_credential_id),
         monthly_cost_cents        = coalesce(p_monthly_cost_cents, monthly_cost_cents),
         current_period_start      = now(),
         current_period_end        = coalesce(p_period_end, current_period_end),
         allowance_period_start    = now(),
         sms_used = 0, voice_used_seconds = 0,
         status = 'active', activated_at = now(), updated_at = now()
   where id = p_line;
  return true;
end;
$fn$;
revoke execute on function public.activate_line_claim(
  uuid, text, text, text, text, text, timestamptz, integer)
  from public, anon, authenticated;

create or replace function public.fail_line_claim(p_line uuid, p_reason text)
returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_status public.line_status;
begin
  select status into v_status from public.phone_lines where id = p_line for update;
  -- Only a line that never became usable may be failed. An active line lapses
  -- through suspend/release instead, so this can never strand a paying user.
  if not found or v_status <> 'provisioning' then return false; end if;

  update public.phone_lines
     set status = 'failed', released_at = now(), updated_at = now()
   where id = p_line;

  -- No refund: Apple owns the money on this line. The edge function pages on
  -- a failed provision so a human can refund through ASC if warranted.
  return true;
end;
$fn$;
revoke execute on function public.fail_line_claim(uuid, text)
  from public, anon, authenticated;

-- Idempotent against line_renewals. Resets the allowance — which is why the
-- reset lives HERE and not on a calendar boundary.
create or replace function public.apply_line_renewal(
  p_original_tx text, p_transaction_id text, p_period_end timestamptz,
  p_price_milli bigint, p_currency text, p_storefront text,
  p_signed_transaction text default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_line uuid;
begin
  if p_original_tx is null or p_transaction_id is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- The tombstone IS the idempotency check. Apple retries notifications at
  -- 1h/12h/24h/48h/72h, and reconcile-subscriptions replays the same renewal
  -- from a different direction — without this, one renewal resets the
  -- allowance several times and hands out free capacity.
  insert into public.line_renewals (transaction_id, original_transaction_id)
  values (p_transaction_id, p_original_tx)
  on conflict (transaction_id) do nothing;
  if not found then
    return jsonb_build_object('ok', true, 'reason', 'already_applied');
  end if;

  update public.line_subscriptions
     set state = 'active', expires_at = p_period_end,
         last_transaction_id = p_transaction_id,
         latest_signed_transaction =
           coalesce(p_signed_transaction, latest_signed_transaction),
         price_milli = coalesce(p_price_milli, price_milli),
         currency = coalesce(p_currency, currency),
         storefront = coalesce(p_storefront, storefront),
         grace_expires_at = null, updated_at = now()
   where original_transaction_id = p_original_tx;

  update public.phone_lines
     set status = case when status in ('grace','past_due','suspended')
                       then 'active' else status end,
         current_period_start = now(),
         current_period_end = p_period_end,
         grace_until = null,
         hold_until = null,
         allowance_period_start = now(),
         sms_used = 0,
         voice_used_seconds = 0,
         updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('active','grace','past_due','suspended')
  returning id into v_line;

  return jsonb_build_object('ok', true, 'line_id', v_line);
end;
$fn$;
revoke execute on function public.apply_line_renewal(
  text, text, timestamptz, bigint, text, text, text)
  from public, anon, authenticated;

-- Grace: service stays FULLY live. Apple is still trying the card.
create or replace function public.enter_line_grace_claim(
  p_original_tx text, p_grace_until timestamptz
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.line_subscriptions
     set state = 'grace', grace_expires_at = p_grace_until, updated_at = now()
   where original_transaction_id = p_original_tx;

  update public.phone_lines
     set status = 'grace', grace_until = p_grace_until, updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('active', 'past_due');
  return found;
end;
$fn$;
revoke execute on function public.enter_line_grace_claim(text, timestamptz)
  from public, anon, authenticated;

-- Billing retry without grace: receive still works, send does not.
create or replace function public.mark_line_past_due_claim(p_original_tx text)
returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.line_subscriptions
     set state = 'billing_retry', updated_at = now()
   where original_transaction_id = p_original_tx;

  update public.phone_lines
     set status = 'past_due', updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('active', 'grace');
  return found;
end;
$fn$;
revoke execute on function public.mark_line_past_due_claim(text)
  from public, anon, authenticated;

-- Suspension starts the HOLD, it does not release. A DID costs cents for a
-- week and the hold is the difference between "fix your card and everything
-- is as you left it" and "your number is gone, and so is everyone who knew
-- it". The edge function separately revokes the telephony credential — that
-- is what makes suspension real rather than client-side theatre.
create or replace function public.suspend_line_claim(
  p_original_tx text, p_hold_until timestamptz
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.line_subscriptions
     set state = 'expired', updated_at = now()
   where original_transaction_id = p_original_tx;

  update public.phone_lines
     set status = 'suspended',
         hold_until = coalesce(p_hold_until, now() + interval '7 days'),
         updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('active', 'grace', 'past_due');
  return found;
end;
$fn$;
revoke execute on function public.suspend_line_claim(text, timestamptz)
  from public, anon, authenticated;

-- Refund / revoke: no hold. Apple took the money back, so we stop paying rent
-- immediately. The edge function releases the number and pages.
create or replace function public.revoke_line_claim(
  p_original_tx text, p_reason integer
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_line uuid;
begin
  update public.line_subscriptions
     set state = 'revoked', revocation_date = now(),
         revocation_reason = p_reason, updated_at = now()
   where original_transaction_id = p_original_tx;

  update public.phone_lines
     set status = 'releasing', hold_until = null, updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('provisioning','active','grace','past_due','suspended')
  returning id into v_line;

  return jsonb_build_object('ok', true, 'line_id', v_line);
end;
$fn$;
revoke execute on function public.revoke_line_claim(text, integer)
  from public, anon, authenticated;

create or replace function public.begin_release_line_claim(p_line uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_status public.line_status; v_number text;
begin
  select status, provider_number_id into v_status, v_number
    from public.phone_lines where id = p_line for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;
  if v_status in ('released', 'failed') then
    return jsonb_build_object('ok', false, 'reason', 'already_released');
  end if;

  update public.phone_lines
     set status = 'releasing', updated_at = now() where id = p_line;
  return jsonb_build_object('ok', true, 'line_id', p_line,
                            'provider_number_id', v_number);
end;
$fn$;
revoke execute on function public.begin_release_line_claim(uuid)
  from public, anon, authenticated;

create or replace function public.confirm_line_released(p_line uuid)
returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.phone_lines
     set status = 'released', released_at = now(),
         -- The credential is gone at the provider; drop our pointer so a
         -- stale id can never be handed to a client.
         provider_credential_id = null,
         updated_at = now()
   where id = p_line and status = 'releasing';
  return found;
end;
$fn$;
revoke execute on function public.confirm_line_released(uuid)
  from public, anon, authenticated;

-- ── 10. Reclaim sweep — PURE SQL, scheduled with no HTTP hop ───────────────
-- Deliberately split from the Telnyx DELETE. The CLAIM must survive the edge
-- layer being down (the same reason run_watchdog is pure SQL); the provider
-- call cannot, so `release-lines` picks up 'releasing' rows separately.
create or replace function public.reclaim_lapsed_lines()
returns integer
language plpgsql security definer set search_path to 'public' as $fn$
declare v_count integer;
begin
  update public.phone_lines
     set status = 'releasing', updated_at = now()
   where status = 'suspended'
     and hold_until is not null
     and hold_until < now();
  get diagnostics v_count = row_count;

  -- Heartbeat for run_watchdog. An absent heartbeat must fail LOUD, so the
  -- watchdog checks `is null or stale`, never `is not null and stale`.
  insert into public.app_config (key, value)
  values ('line_reclaim_heartbeat', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;

  return v_count;
end;
$fn$;
revoke execute on function public.reclaim_lapsed_lines()
  from public, anon, authenticated;

-- ── 11. Messaging ──────────────────────────────────────────────────────────
-- Inbound. Idempotent on provider_message_id: `was_new = false` tells the
-- webhook this is a Telnyx retry so it skips the push.
create or replace function public.record_inbound_message(
  p_line_id uuid, p_provider_id text, p_from text, p_to text,
  p_body text, p_segments integer, p_received_at timestamptz
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_user uuid; v_thread uuid; v_msg uuid; v_blocked boolean;
begin
  select user_id into v_user from public.phone_lines where id = p_line_id;
  if v_user is null then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;

  -- Serialise per user so two inbound messages from the same peer cannot race
  -- into two threads and trip the (line_id, peer_e164) unique constraint.
  perform pg_advisory_xact_lock(hashtext(v_user::text));

  insert into public.line_threads (line_id, user_id, peer_e164)
  values (p_line_id, v_user, p_from)
  on conflict (line_id, peer_e164) do update set peer_e164 = excluded.peer_e164
  returning id, blocked into v_thread, v_blocked;

  insert into public.line_messages (
    thread_id, line_id, user_id, direction, provider_message_id,
    e164_from, e164_to, body, status, segments, received_at)
  values (v_thread, p_line_id, v_user, 'inbound', p_provider_id,
          p_from, p_to, p_body, 'received', greatest(coalesce(p_segments, 1), 1),
          coalesce(p_received_at, now()))
  -- ⚠️ The `where` is REQUIRED, not decoration. line_messages_provider_key is a
  -- PARTIAL unique index, and Postgres will not infer a partial index as an
  -- ON CONFLICT arbiter unless the clause repeats its predicate — without it
  -- this raises 42P10 "no unique or exclusion constraint matching the ON
  -- CONFLICT specification" and every inbound webhook 500s. Caught by the
  -- behavioural test, not by any structural check: the index existed, it just
  -- was not reachable from here.
  on conflict (provider_message_id) where provider_message_id is not null
  do nothing
  returning id into v_msg;

  if v_msg is null then
    -- Telnyx retry. Everything below already happened on the first delivery.
    return jsonb_build_object('ok', true, 'was_new', false);
  end if;

  update public.line_threads
     set last_message_at = coalesce(p_received_at, now()),
         last_preview = left(coalesce(p_body, ''), 140),
         -- A blocked peer is stored but never announced: the row exists for
         -- report/appeal, the user is not disturbed by it.
         unread_count = case when v_blocked then unread_count else unread_count + 1 end
   where id = v_thread;

  return jsonb_build_object('ok', true, 'was_new', true, 'message_id', v_msg,
                            'thread_id', v_thread, 'user_id', v_user,
                            'blocked', coalesce(v_blocked, false));
end;
$fn$;
revoke execute on function public.record_inbound_message(
  uuid, text, text, text, text, integer, timestamptz)
  from public, anon, authenticated;

-- Outbound. Allowance is consumed and the row written BEFORE Telnyx is
-- called, so a provider failure can never leave a sent message unrecorded.
create or replace function public.begin_outbound_message(
  p_user uuid, p_line uuid, p_to text, p_body text, p_segments integer
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_line record; v_thread uuid; v_msg uuid; v_allow jsonb;
  v_segments integer;
begin
  if p_to is null or p_body is null or length(p_body) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  v_segments := greatest(coalesce(p_segments, 1), 1);

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id, user_id, e164, status into v_line
    from public.phone_lines where id = p_line;
  if not found or v_line.user_id <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;
  if v_line.status not in ('active', 'grace') then
    return jsonb_build_object('ok', false, 'reason', 'line_suspended',
                              'status', v_line.status);
  end if;

  select public.consume_line_allowance(p_line, 'sms', v_segments) into v_allow;
  if not coalesce((v_allow ->> 'ok')::boolean, false) then
    return v_allow;
  end if;

  insert into public.line_threads (line_id, user_id, peer_e164)
  values (p_line, p_user, p_to)
  on conflict (line_id, peer_e164) do update set peer_e164 = excluded.peer_e164
  returning id into v_thread;

  insert into public.line_messages (
    thread_id, line_id, user_id, direction, e164_from, e164_to,
    body, status, segments)
  values (v_thread, p_line, p_user, 'outbound', v_line.e164, p_to,
          p_body, 'queued', v_segments)
  returning id into v_msg;

  update public.line_threads
     set last_message_at = now(), last_preview = left(p_body, 140)
   where id = v_thread;

  return jsonb_build_object('ok', true, 'message_id', v_msg,
                            'thread_id', v_thread, 'from', v_line.e164,
                            'remaining', v_allow -> 'remaining');
end;
$fn$;
revoke execute on function public.begin_outbound_message(
  uuid, uuid, text, text, integer)
  from public, anon, authenticated;

-- Claim-gated settle. On a terminal failure the allowance is HANDED BACK —
-- this line has no money to refund, so the allowance is the only thing that
-- can be made whole, and failing to return it silently shrinks what the user
-- paid for.
create or replace function public.settle_outbound_message_claim(
  p_message uuid, p_provider_id text, p_status public.line_msg_status,
  p_cost_cents integer, p_error text
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_status public.line_msg_status; v_line uuid; v_segments integer;
begin
  select status, line_id, segments into v_status, v_line, v_segments
    from public.line_messages where id = p_message for update;
  if not found then return false; end if;
  -- Terminal states are final: a late DLR must never reopen a settled row.
  if v_status in ('delivered', 'failed') then return false; end if;

  update public.line_messages
     set status = p_status,
         provider_message_id = coalesce(p_provider_id, provider_message_id),
         provider_cost_cents = coalesce(p_cost_cents, provider_cost_cents),
         error_code = p_error,
         sent_at = case when p_status in ('sent','delivered')
                        then coalesce(sent_at, now()) else sent_at end
   where id = p_message;

  if p_status = 'failed' then
    perform public.settle_line_allowance(v_line, 'sms', 0, v_segments);
  end if;
  return true;
end;
$fn$;
revoke execute on function public.settle_outbound_message_claim(
  uuid, text, public.line_msg_status, integer, text)
  from public, anon, authenticated;

-- ── 12. Calls ──────────────────────────────────────────────────────────────
-- Idempotent on the provider session id, so the CDR poller and any client
-- report converge on one row.
create or replace function public.record_line_call(
  p_line uuid, p_direction public.line_call_direction, p_peer text,
  p_session_id text, p_status public.line_call_status, p_reserved_seconds integer
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_user uuid; v_call uuid;
begin
  select user_id into v_user from public.phone_lines where id = p_line;
  if v_user is null then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;

  insert into public.line_calls (
    line_id, user_id, direction, peer_e164, provider_call_session_id,
    status, started_at, reserved_seconds)
  values (p_line, v_user, p_direction, p_peer, p_session_id,
          p_status, now(), greatest(coalesce(p_reserved_seconds, 0), 0))
  -- Partial index arbiter — the `where` is required, same as in
  -- record_inbound_message. A NULL session id simply never conflicts, which is
  -- correct: a call we have no provider id for yet is genuinely a new row.
  on conflict (provider_call_session_id) where provider_call_session_id is not null
  do update set status = excluded.status
  returning id into v_call;

  return jsonb_build_object('ok', true, 'call_id', v_call, 'user_id', v_user);
end;
$fn$;
revoke execute on function public.record_line_call(
  uuid, public.line_call_direction, text, text, public.line_call_status, integer)
  from public, anon, authenticated;

-- Driven by the CDR poller. `billed_seconds` is the billing truth and arrives
-- minutes late; `duration_seconds` from the client is advisory only.
create or replace function public.settle_call_claim(
  p_call uuid, p_billed_seconds integer, p_cost_cents integer,
  p_status public.line_call_status, p_hangup_cause text
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_settled boolean; v_line uuid; v_reserved integer;
begin
  select allowance_settled, line_id, reserved_seconds
    into v_settled, v_line, v_reserved
    from public.line_calls where id = p_call for update;
  if not found or v_settled then return false; end if;

  update public.line_calls
     set billed_seconds = coalesce(p_billed_seconds, billed_seconds),
         provider_cost_cents = coalesce(p_cost_cents, provider_cost_cents),
         status = p_status,
         hangup_cause = coalesce(p_hangup_cause, hangup_cause),
         ended_at = coalesce(ended_at, now()),
         allowance_settled = true
   where id = p_call;

  perform public.settle_line_allowance(
    v_line, 'voice', coalesce(p_billed_seconds, 0), v_reserved);
  return true;
end;
$fn$;
revoke execute on function public.settle_call_claim(
  uuid, integer, integer, public.line_call_status, text)
  from public, anon, authenticated;

-- ── 13. Comments ───────────────────────────────────────────────────────────
comment on table public.phone_lines is
  'Rented second numbers (Telnyx). ONE live line per user, enforced by '
  'phone_lines_one_live_per_user. Clients read public.my_line, never this '
  'table — it holds monthly_cost_cents and provider ids.';
comment on table public.line_subscriptions is
  'Apple subscription state. Deliberately has NO foreign key to auth.users: it '
  'is the tombstone that survives Delete Account and stops the same '
  'entitlement provisioning a second number billed to us forever.';
comment on table public.line_messages is
  'provider_message_id is the webhook idempotency key. Telnyx retries; without '
  'the unique index a retry duplicates the message and re-fires the push.';
comment on function public.consume_line_allowance(uuid, text, integer) is
  'The single place allowance is decided. Strict — refuses rather than '
  'overshooting. Voice reserves here and settles from the CDR via '
  'settle_line_allowance, which is the only path allowed to overshoot.';
