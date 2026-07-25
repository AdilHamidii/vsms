-- Security hardening. (The daily-credit loop follows in 20260725170500 — the
-- new `wallet_reason` value added here cannot be USED in the same transaction
-- that adds it, so the two are deliberately split.)
--
-- ─────────────────────────────────────────────────────────────────────────
-- 1) run_watchdog() was executable by PUBLIC.
--
-- Its two migrations revoked from `anon, authenticated`, which does NOT remove
-- a PUBLIC grant — so the revoke was a no-op from day one and the ACL still
-- read `{=X/postgres,...}`. Anyone holding the publishable key (which ships
-- inside the app) could POST /rest/v1/rpc/run_watchdog and read failing[]
-- verbatim: "<N>% delivery over <N> conclusive orders in 24h", provider
-- heartbeat timestamps, which jobs are down. That is the delivery figure we
-- treat as competitor-sensitive, served unauthenticated — and being SECURITY
-- DEFINER it also WROTE app_config.watchdog as postgres.
-- The correct incantation is `from public`; re-issue it after any
-- `create or replace` on a DEFINER function.
revoke execute on function public.run_watchdog() from public;
revoke execute on function public.run_watchdog() from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) wallet_credit silently succeeded when the wallet row was missing.
--
-- It UPDATEd then unconditionally inserted the ledger row with no row-count
-- check (wallet_spend already has one), so a missing wallet would record a
-- refund or an IAP grant that moved no money — and iap-verify's rollback
-- depends on this reporting failure. Latent today (0 users lack a wallet), but
-- every refund and every purchase funnels through here.
--
-- Signature preserved EXACTLY (wallet_reason enum, p_receipt, returns void):
-- changing it would create an overload rather than a replacement.
create or replace function public.wallet_credit(
  p_user uuid,
  p_amount integer,
  p_reason wallet_reason,
  p_order uuid default null,
  p_receipt bigint default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n integer;
begin
    if p_amount <= 0 then
        raise exception 'wallet_credit: amount must be positive, got %', p_amount;
    end if;

    update public.wallets
    set balance = balance + p_amount, updated_at = now()
    where user_id = p_user;

    get diagnostics v_n = row_count;
    if v_n = 0 then
        raise exception 'wallet_credit: no wallet row for user %', p_user;
    end if;

    insert into public.wallet_transactions (user_id, delta, reason, order_id, iap_receipt_id)
    values (p_user, p_amount, p_reason, p_order, p_receipt);
end;
$function$;

revoke execute on function public.wallet_credit(uuid, integer, wallet_reason, uuid, bigint)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) redeem_referral paid the invitee bonus without checking the claim landed.
--
-- Two concurrent calls both pass the `exists` guard; the second blocks on the
-- row lock, matches 0 rows on the UPDATE, and STILL credits 2 credits and
-- returns 'ok'. Farmable per concurrent request — the same shape as the
-- create-order refund hole: an unconditional credit after an unverified claim.
-- Adds the advisory lock begin_order uses, plus a row-count check.
create or replace function public.redeem_referral(p_referee uuid, p_code text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_referrer uuid;
    v_n integer;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return 'invalid_code';
    end if;

    -- Serialise per invitee so two concurrent redemptions cannot both pay.
    perform pg_advisory_xact_lock(hashtext(p_referee::text));

    if exists (select 1 from public.profiles where user_id = p_referee and referred_by is not null) then
        return 'already_referred';
    end if;
    select user_id into v_referrer
        from public.profiles
        where upper(referral_code) = upper(trim(p_code));
    if v_referrer is null then return 'invalid_code'; end if;
    if v_referrer = p_referee then return 'self'; end if;

    update public.profiles
        set referred_by = v_referrer
        where user_id = p_referee and referred_by is null;

    -- Only pay if THIS call is the one that claimed the referral.
    get diagnostics v_n = row_count;
    if v_n = 0 then return 'already_referred'; end if;

    perform public.wallet_credit(p_referee, 2, 'referral_invitee', null, null);
    return 'ok';
end;
$function$;

revoke execute on function public.redeem_referral(uuid, text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) Analytics must exclude the dev account.
--
-- refresh_route_observed_success was the ONLY one of the four analytics
-- functions not excluding it (refresh_service_delivery, refresh_arrival_timing
-- and ops_snapshot all do). Proven consequence: leboncoin/pt showed "measured
-- 0%" to real buyers off exactly two orders, BOTH the dev account. At
-- p_min_sample = 3, three test orders auto-hide a route from everyone.
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
  c_min_negative constant integer := 2;
  c_dev_user constant uuid := '825688de-6117-4251-9f90-93b83b41b572';
begin
  update public.routes
  set success_rate = null, rate_source = null, success_sample = null
  where provider = v_provider and rate_source = 'measured';

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
      and o.user_id <> c_dev_user
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

revoke execute on function public.refresh_route_observed_success(interval, integer, text)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) eSIM orders never expired.
--
-- Nothing wrote 'expired' to esim_orders, so orders sat at 'active' days past
-- expires_at and the app rendered "Valid until 23 Jul" under an Active pill —
-- a wrong claim the user acts on abroad. The enum already has the value and
-- EsimModels.swift already decodes it, so this needs no app release.
create or replace function public.expire_esim_orders()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n integer;
begin
  update public.esim_orders
     set status = 'expired', updated_at = now()
   where expires_at is not null
     and expires_at < now()
     and status in ('active','installed','provisioning');
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

revoke execute on function public.expire_esim_orders() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) Migration bookkeeping: two applied migrations were unrecorded.
--
-- Worse than an accounting gap — 20260724120100 contains an OLDER
-- `create or replace` of refresh_route_observed_success WITHOUT the asymmetric
-- gate. The day `db push` is repaired it would replay that body after the
-- 07-25 fix and silently revert the demotion logic (and refresh_service_delivery
-- with it). Recording them now makes the replay impossible.
insert into supabase_migrations.schema_migrations (version, name) values
  ('20260724120000','measured_arrival_timing'),
  ('20260724120100','blunt_delivery_warnings')
on conflict (version) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 7) New wallet_reason for the daily credit (USED in 20260725170500).
alter type wallet_reason add value if not exists 'daily_bonus';
