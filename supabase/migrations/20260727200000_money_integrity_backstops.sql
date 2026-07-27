-- Money-integrity backstops.
--
-- An audit of every charge/refund path found no reachable double-charge or
-- double-refund today — but it also found that the SMS side survives its own
-- history purely because of ONE partial unique index, and that the equivalent
-- protection was never added for eSIM. These close that asymmetry and make the
-- next mistake an error rather than silent money movement.

-- 1. eSIM refunds can only happen once, mirroring
--    wallet_transactions_refund_once_idx on the SMS side. Today eSIM rests
--    entirely on failEsim's claim gate; if that ever regresses there is nothing
--    underneath it.
create unique index if not exists wallet_transactions_esim_refund_once_idx
  on public.wallet_transactions (esim_order_id)
  where reason = 'refund' and esim_order_id is not null;

-- 2. Link the eSIM SPEND to its order. 20260727160000's own header named
--    begin_esim_order as a violator of the "always pass the order" rule, but
--    only failEsim was fixed — so there are still 0 spend rows carrying an
--    esim_order_id, making eSIM double-charges undetectable from the ledger.
--    That is the unreconcilable state that produced "258 spends vs 126 orders"
--    on the SMS side, now on the higher-ticket product.
--
--    Also checks wallet_spend's boolean result, which begin_order checks and
--    this did not: a failed spend previously left the order row in place.
create or replace function public.begin_esim_order(
  p_user uuid, p_plan text, p_credits integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order uuid;
  v_ok    boolean;
begin
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  -- Same-plan dedupe: a double-tap must not buy two eSIMs.
  if exists (
    select 1 from public.esim_orders o
    where o.user_id = p_user and o.plan_id = p_plan
      and o.created_at >= now() - interval '2 minutes'
      and o.status in ('provisioning', 'installed', 'active')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  insert into public.esim_orders (user_id, plan_id, cost_credits, status)
  values (p_user, p_plan, p_credits, 'provisioning')
  returning id into v_order;

  select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
  if not coalesce(v_ok, false) then
    delete from public.esim_orders where id = v_order;
    return jsonb_build_object('ok', false, 'reason', 'insufficient');
  end if;

  -- Attach the spend to its order so the ledger reconciles. wallet_spend has no
  -- esim-aware overload, so stamp the row it just wrote.
  update public.wallet_transactions
     set esim_order_id = v_order
   where id = (
     select id from public.wallet_transactions
      where user_id = p_user and reason = 'spend' and esim_order_id is null
        and order_id is null
      order by created_at desc limit 1);

  return jsonb_build_object('ok', true, 'order_id', v_order);
end;
$function$;

revoke execute on function public.begin_esim_order(uuid, text, integer)
  from public, anon, authenticated;

-- 3. RESTORE the delivery-collapse check I weakened in 20260727190000.
--
-- That migration's header claimed only to add eSIM-expiry and APNs coverage. It
-- also silently rewrote this block: window 24h -> 6h, gate >=10 -> >=8, and it
-- DELETED the second branch entirely (>=20 conclusive at <10% delivery).
-- Measured over 30 days: the max conclusive orders in ANY 6h window is 8
-- against a gate of 8, where a 24h window reaches 15. So the check went from
-- "fires on a bad day" to "essentially cannot fire", and run_watchdog was left
-- with no delivery-outcome coverage at all — the exact blind spot 20260725140000
-- was written to close, on the outage it was verified against.
--
-- Restored to 24h / >=10 / the <10% branch, KEEPING the two genuine
-- improvements (smspva_number filter, dev-account exclusion) and the new
-- otp-aware code predicate.
create or replace function public.run_watchdog()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  fails jsonb := '[]'::jsonb;
  prev  jsonb;
  v_ts  timestamptz;
  bad_http int;
  bad_sample text;
  deliv_total int;
  deliv_ok    int;
  v_push_fail int;
begin
  select (value->>'checked_at')::timestamptz into v_ts
    from app_config where key = 'smspva_health';
  if v_ts is null or v_ts < now() - interval '10 minutes' then
    fails := fails || jsonb_build_object('check','poll-active-orders',
      'detail','balance heartbeat last written '||coalesce(v_ts::text,'never')||
               ' — OTP polling, expiry refunds and balance monitoring are down');
  end if;

  select max(last_checked_at) into v_ts from routes;
  if v_ts is null or v_ts < now() - interval '3 hours' then
    fails := fails || jsonb_build_object('check','sync-prices',
      'detail','newest route price is from '||coalesce(v_ts::text,'never'));
  end if;

  select max(last_checked_at) into v_ts from esim_plans;
  if v_ts is null or v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','sync-esim-plans',
      'detail','eSIM catalog last synced '||coalesce(v_ts::text,'never'));
  end if;

  select (value->>'last_digest_at')::timestamptz into v_ts
    from app_config where key = 'telegram_bot';
  if v_ts is null or v_ts < now() - interval '7 hours' then
    fails := fails || jsonb_build_object('check','telegram-digest',
      'detail','last digest '||coalesce(v_ts::text,'never'));
  end if;

  select updated_at into v_ts from app_config where key = 'smspva_operator_sync';
  if v_ts is null or v_ts < now() - interval '30 hours' then
    fails := fails || jsonb_build_object('check','sync-smspva-operators',
      'detail','operator cursor last moved '||coalesce(v_ts::text,'never'));
  end if;

  select updated_at into v_ts from app_config where key = 'smspva_conversions_sync';
  if v_ts is null or v_ts < now() - interval '24 hours' then
    fails := fails || jsonb_build_object('check','sync-smspva-conversions',
      'detail','conversions cursor last moved '||coalesce(v_ts::text,'never'));
  end if;

  select updated_at into v_ts from app_config where key = 'winback_heartbeat';
  if v_ts is not null and v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','winback',
      'detail','winback heartbeat last written '||v_ts::text);
  end if;

  select updated_at into v_ts from app_config where key = 'daily_credit_heartbeat';
  if v_ts is not null and v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','daily-credit',
      'detail','daily-credit nudge last ran '||v_ts::text);
  end if;

  select updated_at into v_ts from app_config where key = 'esim_expiry_heartbeat';
  if v_ts is not null and v_ts < now() - interval '2 hours' then
    fails := fails || jsonb_build_object('check','expire-esim-orders',
      'detail','eSIM expiry sweep last ran '||v_ts::text);
  end if;

  select coalesce((value->>'consecutive_failures')::int, 0) into v_push_fail
    from app_config where key = 'push_health';
  if v_push_fail >= 10 then
    fails := fails || jsonb_build_object('check','apns',
      'detail',v_push_fail||' consecutive push failures — code-arrived alerts are not reaching anyone');
  end if;

  select count(*), min(coalesce(status_code::text, error_msg, 'timeout'))
    into bad_http, bad_sample
    from net._http_response
   where created >= now() - interval '25 minutes'
     and (status_code is null or status_code < 200 or status_code >= 300
          or timed_out or error_msg is not null);
  if bad_http > 0 then
    fails := fails || jsonb_build_object('check','relay-http',
      'detail',bad_http||' non-2xx cron relay responses in 25 min (e.g. '||coalesce(bad_sample,'?')||')');
  end if;

  -- Delivery outcome. 24h window so it is actually reachable at ~10 orders/day.
  select count(*), count(*) filter (where o.otp is not null or o.status = 'received')
    into deliv_total, deliv_ok
    from orders o
   where o.closed_at >= now() - interval '24 hours'
     and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and o.smspva_number is not null
     and (o.status in ('received','expired')
          or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
          or (o.status = 'canceled' and exists (
                select 1 from orders n
                where n.user_id = o.user_id and n.service_id = o.service_id
                  and n.id <> o.id and n.created_at >= o.closed_at
                  and n.created_at < o.closed_at + interval '10 minutes')));
  if deliv_total >= 10 and deliv_ok = 0 then
    fails := fails || jsonb_build_object('check','delivery-collapse',
      'detail',deliv_total||' conclusive orders in 24h, ZERO codes delivered');
  elsif deliv_total >= 20 and deliv_ok::numeric / deliv_total < 0.10 then
    fails := fails || jsonb_build_object('check','delivery-degraded',
      'detail',deliv_ok||'/'||deliv_total||' delivered in 24h (<10%)');
  end if;

  select value into prev from app_config where key = 'watchdog';
  insert into app_config (key, value)
  values ('watchdog', jsonb_build_object(
    'checked_at', now(), 'failing', fails,
    'alerted', coalesce(prev->'alerted', '[]'::jsonb),
    'last_alert_at', prev->>'last_alert_at'))
  on conflict (key) do update set value = excluded.value;

  return fails;
end;
$function$;

revoke execute on function public.run_watchdog() from public;

-- 4. is_code consumers that still key on status='received'. A rescued order is
--    status='canceled' WITH an otp, so each of these scored a delivered code as
--    a failure. stranded_credit_candidates was the worst: it would tell a user
--    who HAD received their code that "every number that fails is refunded".
create or replace function public.stranded_credit_candidates(p_limit integer default 100)
returns table(user_id uuid, balance integer)
language sql stable security definer set search_path to 'public'
as $function$
  select w.user_id, w.balance
  from public.wallets w
  join lateral (
    select o.status, o.otp
    from public.orders o
    where o.user_id = w.user_id
    order by o.created_at desc
    limit 1
  ) last_order on true
  join public.profiles p on p.user_id = w.user_id
  where coalesce(public.recent_sms_delivery_rate(), 0) >= 40
    and w.balance > 0
    and last_order.status in ('expired', 'canceled')
    and last_order.otp is null          -- a rescued code is NOT a failure
    and p.stranded_nudge_sent_at is null
    and w.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
    and not exists (
      select 1 from public.orders o2
      where o2.user_id = w.user_id and o2.created_at >= now() - interval '24 hours')
    and exists (select 1 from public.push_devices d where d.user_id = w.user_id)
  limit p_limit;
$function$;

revoke execute on function public.stranded_credit_candidates(integer)
  from public, anon, authenticated;

-- 5. winback dormancy predicate was INVERTED: `exists (a device older than 3
--    days)` marks a user dormant even when another device was refreshed this
--    morning. register-push upserts on (user_id, token), so a rotated token
--    leaves the old row forever — making such a user permanently "dormant".
create or replace function public.winback_candidates(p_limit integer default 200)
returns table(user_id uuid, kind text)
language sql security definer set search_path to 'public'
as $function$
  select p.user_id,
         case when exists (select 1 from public.orders o where o.user_id = p.user_id)
              then 'tried_failed' else 'never_ordered' end as kind
    from public.profiles p
    join public.wallets w on w.user_id = p.user_id
   where p.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and w.balance > 0
     and p.winback_sent_count < 3
     and (p.winback_sent_at is null or p.winback_sent_at < now() - interval '14 days')
     and exists (select 1 from public.push_devices d where d.user_id = p.user_id)
     -- NOT EXISTS a *fresh* device — the inverse of "exists a stale one".
     and not exists (
           select 1 from public.push_devices d
            where d.user_id = p.user_id
              and d.updated_at >= now() - interval '3 days')
     and not exists (
           select 1 from public.orders o
            where o.user_id = p.user_id
              and (o.status = 'received' or o.otp is not null))
     and not exists (
           select 1 from public.orders o
            where o.user_id = p.user_id and o.created_at >= now() - interval '3 days')
   order by p.created_at asc
   limit p_limit;
$function$;

revoke execute on function public.winback_candidates(integer) from public, anon, authenticated;
