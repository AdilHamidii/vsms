-- Temporary EMAIL addresses — the third product line.
--
-- HeroSMS sells temp mailboxes on real consumer domains through a REST API that
-- is entirely separate from its SMS protocol (see `_shared/heromail.ts`). We
-- resell four: gmail.com and icloud.com at 1 credit, outlook.com and
-- hotmail.com free.
--
-- ── Why `status` is OUR enum and not the vendor's ───────────────────────────
-- The vendor's status vocabulary is NOT documented and is not discoverable:
-- its OpenAPI spec is not served at any conventional path and appears in none
-- of the 50 JS chunks of its docs SPA. Probing live on 2026-07-30 yielded only
-- `WAIT` (fresh) and `CANCEL` (after DELETE). The value meaning "a code
-- arrived" is still unknown.
--
-- Guessing it into a Postgres enum is precisely the mistake that already cost
-- real money here: `create-esim-order` wrote the literal 'canceled', which is a
-- member of `order_status` but NOT of `esim_status`; PostgREST rejected the
-- UPDATE with 22P02, the code discarded the error, and **every failed eSIM
-- purchase silently kept the user's money**.
--
-- So this enum is ours, mirrors `order_status` semantics, and can never be
-- invalidated by a vendor value we have not seen. The raw vendor string is kept
-- verbatim in `provider_status` for diagnosis, and the edge function maps
-- vendor -> ours with an explicit allowlist, logging loudly on anything new and
-- falling back to 'waiting' (safe: it keeps polling rather than closing an
-- order that may still deliver).
--
-- ── `code is not null` is the authority for "a code arrived" ────────────────
-- NOT `status = 'received'`. This is the same rule the SMS side had to learn:
-- a rescued late code lives on a `canceled` row, so five SQL functions that
-- keyed on the status scored a delivered code as a failure. Every consumer of
-- email outcomes must test `code is not null`.

-- ── 1. Our status vocabulary ───────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_type where typname = 'email_status') then
    create type public.email_status as enum (
      'waiting',    -- live, no code yet
      'received',   -- a code arrived (code is not null)
      'canceled',   -- released by the user; refunded if it was paid
      'expired',    -- window closed with no code; refunded if it was paid
      'failed'      -- never got an address out of the provider
    );
  end if;
end $$;

-- ── 2. The orders table ────────────────────────────────────────────────────
create table if not exists public.email_orders (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  provider          text not null default 'herosms',
  -- HeroSMS activation id. Text, not bigint: every other provider id in this
  -- schema is text and the poller treats them uniformly.
  provider_id       text,
  -- The target the address will be used on, from `services.domain`. REQUIRED by
  -- the provider, and both price and stock vary by it.
  site              text not null,
  domain            text not null,
  email             text,
  -- 0 for the free tier. `esim_orders` has `check (cost_credits > 0)` and that
  -- would make every free activation impossible here.
  cost_credits      integer not null default 0 check (cost_credits >= 0),
  actual_cost_cents integer,
  status            public.email_status not null default 'waiting',
  -- Raw vendor status, never interpreted by SQL. Diagnosis only.
  provider_status   text,
  code              text,
  raw_message       text,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz,
  closed_at         timestamptz,
  updated_at        timestamptz not null default now()
);

create index if not exists email_orders_user_idx
  on public.email_orders (user_id, created_at desc);
-- The poller sweeps live rows only.
create index if not exists email_orders_live_idx
  on public.email_orders (status, created_at)
  where status = 'waiting';
-- One provider activation can back at most one row.
create unique index if not exists email_orders_provider_id_key
  on public.email_orders (provider_id)
  where provider_id is not null;
-- Drives the free-tier daily cap without a sequential scan.
create index if not exists email_orders_free_daily_idx
  on public.email_orders (user_id, created_at)
  where cost_credits = 0;

alter table public.email_orders enable row level security;

drop policy if exists "email_orders: self read" on public.email_orders;
create policy "email_orders: self read" on public.email_orders
  for select to authenticated
  using (user_id = (select auth.uid()));

-- No insert/update/delete policy at all: every write goes through the service
-- role or a SECURITY DEFINER function. RLS is row-level and cannot restrict
-- columns, so a table-wide write grant would let a client set its own
-- `cost_credits` or `status`.
revoke insert, update, delete, truncate on public.email_orders
  from anon, authenticated;

-- ── 3. Ledger link ─────────────────────────────────────────────────────────
-- `wallet_transactions.order_id` FKs public.orders and cannot hold an email id;
-- eSIM already needed the same sibling treatment. A third column is the honest
-- minimum here — a polymorphic redesign is a separate job.
alter table public.wallet_transactions
  add column if not exists email_order_id uuid
  references public.email_orders(id) on delete set null;

create index if not exists wallet_transactions_email_order_idx
  on public.wallet_transactions (email_order_id)
  where email_order_id is not null;

-- Backstop, mirroring wallet_transactions_esim_refund_once_idx: a refund can
-- physically happen at most once per email order even if a claim gate regresses.
create unique index if not exists wallet_transactions_email_refund_once_idx
  on public.wallet_transactions (email_order_id)
  where email_order_id is not null and reason = 'refund';

-- ── 4. Refund mover ────────────────────────────────────────────────────────
-- Separate from wallet_credit so no existing caller changes shape, exactly as
-- wallet_move_esim was added for the second product line.
create or replace function public.wallet_move_email(
  p_user uuid, p_amount integer, p_reason public.wallet_reason, p_email_order uuid
) returns boolean
language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'wallet_move_email: amount must be positive, got %', p_amount;
  end if;

  update public.wallets set balance = balance + p_amount
   where user_id = p_user
  returning 1 into v_id;
  if v_id is null then
    raise exception 'wallet_move_email: no wallet for user %', p_user;
  end if;

  insert into public.wallet_transactions (user_id, delta, reason, email_order_id)
  values (p_user, p_amount, p_reason, p_email_order);
  return true;
end $$;

revoke execute on function public.wallet_move_email(uuid, integer, public.wallet_reason, uuid)
  from public, anon, authenticated;

-- ── 5. Telegram alert kind ─────────────────────────────────────────────────
-- `telegram_events` is the exactly-once claim row, written BEFORE sending. It
-- is CHECK-constrained, so a new kind cannot be claimed until the constraint
-- admits it — and the insert failing is exactly how an alert goes missing with
-- no trace.
alter table public.telegram_events drop constraint if exists telegram_events_kind_check;
alter table public.telegram_events add constraint telegram_events_kind_check
  check (kind = any (array['signup'::text, 'purchase'::text, 'esim'::text, 'email'::text]));

-- ── 6. begin_email_order — dedupe + cap + insert + charge, one transaction ──
--
-- Modelled on the LIVE begin_esim_order (20260727200000_money_integrity_backstops),
-- which supersedes the original and returns {ok, reason, order_id}. Pinning the
-- same shape matters: the first version returned {status:…}, the TS reads
-- `reason`, and the drift shipped broken.
create or replace function public.begin_email_order(
  p_user uuid, p_site text, p_domain text, p_credits integer
) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_balance integer;
  v_existing uuid;
  v_order uuid;
  v_ok boolean;
  v_free_today integer;
  v_cap integer;
begin
  if p_credits is null or p_credits < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- Serialise per user, exactly as begin_order and begin_esim_order do. The
  -- free-tier cap below is only meaningful under this lock.
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  -- Double-tap / client-retry guard. Narrow on purpose: this is not meant to
  -- stop a deliberate second address on the same site.
  select id into v_existing
    from public.email_orders
   where user_id = p_user and site = p_site and domain = p_domain
     and status = 'waiting'
     and created_at > now() - interval '2 minutes'
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  -- Free tier: the ONLY thing bounding spend, since there is no credit gate.
  -- Cheap per unit ($0.0034) but unbounded without this, and it also drains the
  -- scarcest stock we sell — outlook/hotmail measured as low as 2 available for
  -- a given site. Tunable from app_config without a migration.
  if p_credits = 0 then
    select coalesce((value #>> '{}')::integer, 3) into v_cap
      from public.app_config where key = 'email_free_daily_cap';
    v_cap := coalesce(v_cap, 3);

    select count(*) into v_free_today
      from public.email_orders
     where user_id = p_user
       and cost_credits = 0
       and created_at >= date_trunc('day', now() at time zone 'utc');

    if v_free_today >= v_cap then
      return jsonb_build_object('ok', false, 'reason', 'free_limit_reached',
                                'cap', v_cap);
    end if;
  end if;

  -- Row first, then money — the ordering begin_order was rewritten to use after
  -- 258 spends pointed at only 126 orders.
  insert into public.email_orders (user_id, site, domain, cost_credits, status)
  values (p_user, p_site, p_domain, p_credits, 'waiting')
  returning id into v_order;

  if p_credits > 0 then
    -- wallet_spend RAISES on a non-positive amount, so the free path must skip
    -- it entirely rather than call it with 0.
    select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
    if not coalesce(v_ok, false) then
      delete from public.email_orders where id = v_order;
      return jsonb_build_object('ok', false, 'reason', 'insufficient');
    end if;

    -- Back-stamp the ledger row so the spend reconciles against this order.
    update public.wallet_transactions
       set email_order_id = v_order
     where id = (
       select id from public.wallet_transactions
        where user_id = p_user and reason = 'spend' and email_order_id is null
        order by created_at desc, id desc limit 1
     );
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order);
end $$;

revoke execute on function public.begin_email_order(uuid, text, text, integer)
  from public, anon, authenticated;

comment on table public.email_orders is
  'Temporary email activations (HeroSMS /api/v1/emails). `code is not null` is '
  'the authority for "a code arrived", never status = ''received''.';
