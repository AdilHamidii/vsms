-- eSIM order idempotency + winback honesty fixes.
--
-- ─────────────────────────────────────────────────────────────────────────
-- 1) begin_esim_order — dedupe + reserve + charge in ONE transaction.
--
-- create-esim-order called wallet_spend and only inserted the order row ~20
-- lines later, after a provider round-trip. No advisory lock, no dedupe, no
-- unique constraint. A double-tap bought two eSIMs and charged twice; a worker
-- death in that window charged the user with no row, no refund and no trace.
-- This is exactly the shape begin_order was written to kill for SMS, where it
-- had produced "258 spends vs 126 orders — 51% of paid attempts invisible".
--
-- Mirrors begin_order deliberately: same advisory lock, same dedupe-then-
-- insert-then-charge ordering, same jsonb result contract.
create or replace function public.begin_esim_order(
  p_user uuid,
  p_plan text,
  p_credits integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_balance integer;
  v_existing uuid;
  v_id uuid;
begin
  -- Serialise per user, exactly as begin_order does.
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  -- Dedupe: an identical purchase already in flight. Narrow window on purpose
  -- — this guards double-taps and client retries, not a deliberate second buy.
  select id into v_existing
    from public.esim_orders
   where user_id = p_user
     and plan_id = p_plan
     and status = 'provisioning'
     and created_at > now() - interval '2 minutes'
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('status','duplicate','order_id', v_existing);
  end if;

  select balance into v_balance from public.wallets where user_id = p_user for update;
  if v_balance is null or v_balance < p_credits then
    return jsonb_build_object('status','insufficient');
  end if;

  insert into public.esim_orders (user_id, provider, plan_id, cost_credits, status)
  values (p_user, 'smspool', p_plan, p_credits, 'provisioning')
  returning id into v_id;

  perform public.wallet_spend(p_user, p_credits, 'spend', null);

  return jsonb_build_object('status','ok','order_id', v_id);
end;
$function$;

revoke execute on function public.begin_esim_order(uuid, text, integer)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) winback cohort 1 told burned users something false.
--
-- winback_candidates was broadened to include "ordered but never received a
-- code", but the copy stayed "Your free credit is waiting — your first one's
-- on us." Measured: 8 of the 34 users ever nudged had already placed orders.
-- They were told their first number was free AFTER paying for numbers that
-- failed. Return a `kind` so the function can pick honest copy.
-- Return type changes (adds `kind`), so this must be dropped, not replaced.
drop function if exists public.winback_candidates(integer);

create function public.winback_candidates(p_limit integer default 200)
returns table (user_id uuid, kind text)
language sql
security definer
set search_path to 'public'
as $function$
  select p.user_id,
         case when exists (select 1 from public.orders o where o.user_id = p.user_id)
              then 'tried_failed' else 'never_ordered' end as kind
    from public.profiles p
   where p.winback_sent_at is null
     and p.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and exists (select 1 from public.push_devices d where d.user_id = p.user_id)
     and not exists (
           select 1 from public.orders o
            where o.user_id = p.user_id and o.status = 'received')
   order by p.created_at desc
   limit p_limit;
$function$;

revoke execute on function public.winback_candidates(integer) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) The "delivery improved" gate measured the wrong thing.
--
-- recent_sms_delivery_rate() counts only CONCLUSIVE orders, which excludes
-- cancels under 240s — 13 of the last 15. So it read 50% while users actually
-- received 4 codes from 21 orders (19%), leaving the gate OPEN and arming the
-- "SMS delivery just got a big upgrade" push. The migration that added the
-- gate says its entire purpose is that promising improvement to already-burned
-- users and failing them again converts soft churn into permanent churn — so
-- it has to measure what the USER experienced, not what the route did.
create or replace function public.recent_user_delivery_rate(p_window interval default '48 hours')
returns integer
language sql
security definer
set search_path to 'public'
as $function$
  select coalesce(
    round(100.0 * count(*) filter (where status = 'received') / nullif(count(*), 0))::int,
    0)
    from public.orders
   where created_at >= now() - p_window
     and closed_at is not null
     and user_id <> '825688de-6117-4251-9f90-93b83b41b572';
$function$;

revoke execute on function public.recent_user_delivery_rate(interval)
  from public, anon, authenticated;

comment on function public.recent_user_delivery_rate(interval) is
  'Delivery rate as the USER experienced it: every closed order, no '
  'conclusiveness filter. Pair it with recent_sms_delivery_rate() before '
  'claiming delivery improved — the conclusive-only figure can read 50% on a '
  'window where real users got 19%.';
