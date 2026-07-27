-- Four fixes: two un-backported evidence bugs, irreversible auto-hide, and a
-- farmable signup bonus.

-- ── 1. recent_sms_delivery_rate never received the numberless filter.
--
-- 20260727120000 added `smspva_number is not null` to
-- refresh_route_observed_success, and 20260727150000 added it to
-- refresh_service_delivery — this third consumer was missed. Orders that die
-- inside create-order (margin ceiling, stockout, provider fault) never got a
-- number and say nothing about delivery, but were counted as failures here.
--
-- It matters because this function gates stranded_credit_candidates at >= 40:
-- a run of price-ceiling rejections could suppress the winback cohort entirely.
-- Also brought onto the otp-aware code predicate so a rescued code counts.
create or replace function public.recent_sms_delivery_rate(
  p_window interval default '48:00:00'::interval,
  p_min_sample integer default 5)
returns numeric
language sql stable security definer set search_path to 'public'
as $function$
  with c as (
    select (o.otp is not null or o.status = 'received') as is_code
    from public.orders o
    where o.provider = public.active_sms_provider()
      and o.tier = 'standard'
      and o.created_at >= now() - p_window
      and o.closed_at is not null
      and o.smspva_number is not null
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
      and (o.otp is not null
           or o.status in ('received', 'expired')
           or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds'))
  )
  select case when count(*) >= p_min_sample
              then round(100.0 * count(*) filter (where is_code) / count(*))
              else null end
  from c;
$function$;

revoke execute on function public.recent_sms_delivery_rate(interval, integer)
  from public, anon, authenticated;

-- ── 2 + 3. refresh_route_observed_success: UN-HIDE when evidence ages out.
--
-- Auto-hide was one-way. The function clears a measured rate once the lookback
-- no longer covers it, but never restored `status`, so a route hidden on (say)
-- two bad orders stayed invisible forever — and being invisible, it could never
-- earn evidence to the contrary. A self-sealing catalog that only ever shrinks.
--
-- Un-hiding is safe because it is not the only gate: sync-prices re-evaluates
-- `hide = blocked_routes OR cents > MAX_WHOLESALE_CENTS` every hour and will
-- immediately re-hide anything genuinely unsellable. This only returns routes
-- whose sole reason for hiding was stale delivery evidence.
create or replace function public.refresh_route_observed_success(
  p_lookback interval default '30 days'::interval,
  p_min_sample integer default 3,
  p_provider text default null::text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_hidden integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
  c_min_negative constant integer := 2;
  c_dev_user constant uuid := '825688de-6117-4251-9f90-93b83b41b572';
begin
  -- Evidence has aged out of the window: drop the measured rate AND give the
  -- route its shelf space back, so it can be re-measured.
  update public.routes r
  set success_rate = null,
      rate_source = null,
      success_sample = null,
      status = case when r.status = 'hidden' and r.retail_credits is not null
                    then 'active' else r.status end
  where r.provider = v_provider
    and r.rate_source = 'measured'
    and not exists (
      select 1 from public.orders o
      where o.service_id = r.service_id
        and o.country_id = r.country_id
        and o.provider = v_provider
        and o.created_at >= now() - p_lookback
        and o.closed_at is not null
        and o.smspva_number is not null
    );

  with classified as (
    select o.service_id, o.country_id,
      (o.otp is not null) as is_code,
      (
        o.otp is not null
        or o.status = 'received'
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
      and o.user_id <> c_dev_user
      and o.created_at >= now() - p_lookback
      and o.closed_at is not null
      and o.smspva_number is not null
  ),
  obs as (
    select service_id, country_id,
      count(*) filter (where is_conclusive) as closed,
      count(*) filter (where is_code)       as received
    from classified
    group by service_id, country_id
    having count(*) filter (where is_conclusive) >= p_min_sample
        or (count(*) filter (where is_code) = 0
            and count(*) filter (where is_conclusive) >= c_min_negative)
  ),
  upd as (
    update public.routes r
    set success_rate = round(100.0 * obs.received / obs.closed)::int,
        rate_source = 'measured',
        success_sample = obs.closed,
        status = case
                   when obs.received = 0 and obs.closed >= p_min_sample then 'hidden'
                   -- Recovered: a route that starts delivering again comes back.
                   when obs.received > 0 and r.status = 'hidden'
                        and r.retail_credits is not null then 'active'
                   else r.status
                 end
    from obs
    where r.service_id = obs.service_id
      and r.country_id = obs.country_id
      and r.provider = v_provider
    returning (obs.received = 0 and obs.closed >= p_min_sample) as was_hidden
  )
  select count(*) filter (where was_hidden) into v_hidden from upd;
  return v_hidden;
end;
$function$;

-- ── 4. refresh_service_delivery's wipe is unconditional across ALL services.
--
-- Same class as the bug fixed for routes: it nulls every service's counters
-- first, so any service the (provider, tier, numbered) filter no longer covers
-- keeps NULL evidence until it earns new orders — and `apply_measured_service_
-- ranking` requires `observed_attempts >= 8`, so a service that goes quiet is
-- frozen at whatever sort_order it last had, unable to be re-evaluated. Scope
-- the wipe to services the current provider actually has evidence for.
create or replace function public.refresh_service_delivery(
  p_lookback interval default '30 days'::interval,
  p_provider text default null::text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_updated integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
begin
  update public.services s
  set observed_attempts = null, observed_codes = null, observed_orders = null
  where (s.observed_attempts is not null or s.observed_orders is not null)
    and not exists (
      select 1 from public.orders o
      where o.service_id = s.id
        and o.provider = v_provider
        and o.tier = 'standard'
        and o.created_at >= now() - p_lookback
        and o.closed_at is not null
        and o.smspva_number is not null
        and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
    );

  with classified as (
    select o.service_id,
      (o.otp is not null) as is_code,
      (
        o.otp is not null
        or o.status = 'received'
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
      and o.smspva_number is not null
  ),
  agg as (
    select service_id,
           count(*) filter (where is_conclusive) as attempts,
           count(*) filter (where is_code)       as codes,
           count(*)                              as orders
    from classified group by service_id
  ),
  upd as (
    update public.services s
    set observed_attempts = agg.attempts,
        observed_codes    = agg.codes,
        observed_orders   = agg.orders
    from agg where s.id = agg.service_id
    returning 1
  )
  select count(*) into v_updated from upd;
  return v_updated;
end;
$function$;

-- ── 5. Signup bonus was farmable: delete-account → sign in again → +3 credits,
-- repeatable, plus a fresh +2 from redeem_referral because referred_by resets.
--
-- Everything user-scoped cascades from auth.users, so the tombstone must live
-- outside that graph. Keyed on a HASH of the email — Apple's private-relay
-- address is stable per (user, app), so it survives deletion and re-signup while
-- storing no address.
create table if not exists public.signup_grants (
  email_hash    text primary key,
  first_granted_at timestamptz not null default now(),
  grant_count   integer not null default 1
);
alter table public.signup_grants enable row level security;
revoke all on public.signup_grants from anon, authenticated;

comment on table public.signup_grants is
  'Tombstone of email hashes that have already received a signup bonus. Lives '
  'OUTSIDE the auth.users cascade on purpose: deleting an account frees the '
  'wallet, the profile and the referral state, so without this a user could '
  'delete and re-signup for +3 (and a fresh +2 referral) indefinitely.';

-- Backfill from existing users so today's accounts can't re-farm.
insert into public.signup_grants (email_hash, first_granted_at)
select distinct on (md5(lower(u.email))) md5(lower(u.email)), min(u.created_at)
from auth.users u
where u.email is not null
group by md5(lower(u.email))
on conflict (email_hash) do nothing;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_hash  text := case when new.email is null then null else md5(lower(new.email)) end;
  v_seen  boolean := false;
  v_bonus integer := 3;
begin
    insert into public.profiles (user_id, display_name, referral_code)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
        public.gen_referral_code()
    );

    -- Has this identity been paid a signup bonus before? A null email cannot be
    -- deduped, so it still gets the grant — failing OPEN is correct here: a
    -- missed grant on a legitimate signup costs more than a rare duplicate.
    if v_hash is not null then
      select true into v_seen from public.signup_grants where email_hash = v_hash;
      if v_seen then
        v_bonus := 0;
      else
        insert into public.signup_grants (email_hash) values (v_hash)
        on conflict (email_hash) do update
          set grant_count = public.signup_grants.grant_count + 1;
      end if;
    end if;

    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, v_bonus, now());

    if v_bonus > 0 then
      insert into public.wallet_transactions (user_id, delta, reason)
      values (new.id, v_bonus, 'signup_bonus');
    end if;

    return new;
end;
$function$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;
