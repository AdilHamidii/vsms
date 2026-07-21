-- Premium real-SIM tier for SMSPVA numbers.
--
-- SMSPVA fills un-pinned orders from whichever pool it likes ("the operator
-- will be selected randomly"), and its catalog splits cleanly into REAL
-- carriers (KPN_NL, Vodafone_UK, EE_UK, ATT_US, ...) and anonymized donor
-- pools (DonorAlpha_*, DonorEcho_*, ... — NATO-phonetic pseudo-operators,
-- probed live 2026-07-21). Donor/VoIP-style numbers are exactly what
-- strict-risk platforms reject: our 30-day data shows instagram 1 delivered
-- vs ~6 genuine fails and whatsapp/us 0-for-4, while leboncoin (no VoIP
-- screening) delivers fine. The activation API accepts an optional operator
-- path segment, so the fix is to sell the choice:
--
--   standard = today's behavior (random pool, price unchanged)
--   premium  = pinned to a real carrier, priced from that carrier's own
--              per-operator price (sync-smspva-operators), fail-fast if dry
--
-- Owner decisions 2026-07-21: two-tier product (NOT silent repricing of the
-- standard tier), and premium never silently downgrades to a random fill.

-- ── Routes: the chosen carrier + its price + the premium retail price ────
alter table public.routes add column if not exists smspva_operator text;
alter table public.routes add column if not exists smspva_operator_cents integer;
alter table public.routes add column if not exists premium_credits integer;

comment on column public.routes.smspva_operator is
  'Real-SIM SMSPVA operator the premium tier pins (e.g. Vodafone_UK). '
  'null = no premium tier for this combo. Written by sync-smspva-operators.';
comment on column public.routes.smspva_operator_cents is
  'Wholesale price of smspva_operator in cents, from the per-operator (po) '
  'price map. Used as the premium margin reference at order time.';
comment on column public.routes.premium_credits is
  'Retail price of the premium tier. null = premium hidden in the app.';

-- ── Orders: which tier was bought ─────────────────────────────────────────
-- Existing rows backfill to 'standard' via the default.
alter table public.orders add column if not exists tier text not null default 'standard';
alter table public.orders drop constraint if exists orders_tier_check;
alter table public.orders add constraint orders_tier_check
  check (tier in ('standard', 'premium'));

comment on column public.orders.smspool_pool is
  'Generic filled-pool attribution, not SMSPool-specific: SMSPool pool id for '
  'smspool orders, pinned SMSPVA operator for premium smspva orders.';

-- ── begin_order learns the tier ───────────────────────────────────────────
-- Drop first: CREATE OR REPLACE with a new parameter list would OVERLOAD the
-- function, and a named-argument RPC call omitting p_tier would then be
-- ambiguous between the two versions.
drop function if exists public.begin_order(uuid, text, text, integer, integer);

create or replace function public.begin_order(
  p_user uuid,
  p_service text,
  p_country text,
  p_credits integer,
  p_dedupe_seconds integer default 15,
  p_tier text default 'standard'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existing uuid;
  v_id uuid;
  v_ok boolean;
begin
  -- Serialize per user for the rest of this transaction (see 20260721094313).
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  -- Dedupe within the same tier only: standard-then-premium in quick
  -- succession is a deliberate upgrade attempt, not a double-tap.
  select id into v_existing
  from public.orders
  where user_id = p_user
    and service_id = p_service
    and country_id = p_country
    and status = 'waiting'
    and tier = p_tier
    and created_at >= now() - make_interval(secs => p_dedupe_seconds)
  order by created_at desc
  limit 1;

  if v_existing is not null then
    return jsonb_build_object('status', 'duplicate', 'order_id', v_existing);
  end if;

  insert into public.orders (user_id, service_id, country_id, cost_credits, status, tier)
  values (p_user, p_service, p_country, p_credits, 'waiting', p_tier)
  returning id into v_id;

  select public.wallet_spend(p_user, p_credits, 'spend', v_id) into v_ok;

  if not coalesce(v_ok, false) then
    delete from public.orders where id = v_id;
    return jsonb_build_object('status', 'insufficient_credits');
  end if;

  return jsonb_build_object('status', 'ok', 'order_id', v_id);
end;
$function$;

revoke execute on function public.begin_order(uuid, text, text, integer, integer, text)
  from public, anon, authenticated;

-- ── Keep the feedback loop tier-honest ────────────────────────────────────
-- Route hiding, success badges and service ranking all describe what the
-- DEFAULT (standard) purchase delivers. Premium outcomes must not unhide a
-- dead standard route, inflate its badge, or — worse — a failing premium
-- experiment must not hide a route whose standard tier works. Premium
-- delivery is analyzed separately (orders.tier = 'premium').

create or replace function public.refresh_route_observed_success(
  p_lookback interval default '3 days',
  p_min_sample integer default 3,
  p_provider text default null
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_hidden integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
begin
  update public.routes set success_rate = null where provider = v_provider;

  with classified as (
    select o.service_id, o.country_id,
      (o.status = 'received') as is_code,
      (
        o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from public.orders n
              where n.user_id = o.user_id
                and n.service_id = o.service_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from public.orders o
    where o.provider = v_provider
      and o.tier = 'standard'
      and o.created_at >= now() - p_lookback
      and o.closed_at is not null
  ),
  obs as (
    select service_id, country_id,
      count(*) filter (where is_conclusive) as closed,
      count(*) filter (where is_code)       as received
    from classified
    group by service_id, country_id
    having count(*) filter (where is_conclusive) >= p_min_sample
  ),
  upd as (
    update public.routes r
    set success_rate = round(100.0 * obs.received / obs.closed)::int,
        status = case when obs.received = 0 then 'hidden' else r.status end
    from obs
    where r.service_id = obs.service_id
      and r.country_id = obs.country_id
      and r.provider = v_provider
    returning (obs.received = 0) as was_hidden
  )
  select count(*) filter (where was_hidden) into v_hidden from upd;
  return v_hidden;
end;
$function$;

revoke execute on function public.refresh_route_observed_success(interval, integer, text)
  from public, anon, authenticated;

create or replace function public.refresh_service_delivery(
  p_lookback interval default '30 days',
  p_provider text default null
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_updated integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
begin
  update public.services
  set observed_attempts = null, observed_codes = null
  where observed_attempts is not null;

  with classified as (
    select o.service_id,
      (o.status = 'received') as is_code,
      (
        o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from public.orders n
              where n.user_id = o.user_id
                and n.service_id = o.service_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from public.orders o
    where o.created_at >= now() - p_lookback
      and o.closed_at is not null
      and o.provider = v_provider
      and o.tier = 'standard'
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
  ),
  agg as (
    select service_id,
           count(*) filter (where is_conclusive) as attempts,
           count(*) filter (where is_code)       as codes
    from classified group by service_id
  ),
  upd as (
    update public.services s
    set observed_attempts = agg.attempts,
        observed_codes    = agg.codes
    from agg where s.id = agg.service_id
    returning 1
  )
  select count(*) into v_updated from upd;
  return v_updated;
end;
$function$;

revoke execute on function public.refresh_service_delivery(interval, text)
  from public, anon, authenticated;

-- ── Schedule the operator discovery pass ──────────────────────────────────
-- Hourly, offset from relay-sync-prices (:17). Each run handles a bounded,
-- cursor-resumable batch of countries (SMSPVA asks for 4-5s between calls),
-- so a full catalog pass completes over a few hours and then keeps cycling.
select cron.schedule(
    'relay-sync-smspva-operators',
    '37 * * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-smspva-operators',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $cmd$
);
