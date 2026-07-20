-- Cap unverified success claims + tighten the dead-route threshold.
--
-- SMSPool self-reported >=95% on 5,036 of 6,320 routes — it claimed 100% for
-- facebook/ch while that route delivered 0 of 9 real orders. Nothing we have
-- not measured ourselves may promise near-certainty, so unverified claims are
-- capped at 90 on every hourly run (routes inherited from a retired provider
-- carry stale 100% ratings, so this must run continuously, not once).
--
-- min_sample 5 -> 3: five separate users had to be failed before a dead route
-- was pulled. Three genuine attempts is enough proof.
drop function if exists public.refresh_smspool_observed_success(interval, integer);

create or replace function public.refresh_smspool_observed_success(
  p_lookback interval default interval '3 days',
  p_min_sample integer default 3,
  p_self_report_cap integer default 90
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hidden integer;
begin
  update public.routes
  set success_rate = p_self_report_cap
  where provider = 'smspool' and success_rate > p_self_report_cap;

  with obs as (
    select service_id, country_id,
      count(*) filter (
        where status = 'received'
           or (status in ('canceled', 'expired') and closed_at - created_at >= interval '90 seconds')
      ) as closed,
      count(*) filter (where status = 'received') as received
    from public.orders
    where provider = 'smspool' and created_at >= now() - p_lookback
    group by service_id, country_id
    having count(*) filter (
      where status = 'received'
         or (status in ('canceled', 'expired') and closed_at - created_at >= interval '90 seconds')
    ) >= p_min_sample
  ),
  upd as (
    update public.routes r
    set success_rate = round(100.0 * obs.received / obs.closed)::int,
        status = case when obs.received = 0 then 'hidden' else r.status end
    from obs
    where r.service_id = obs.service_id
      and r.country_id = obs.country_id
      and r.provider = 'smspool'
    returning (obs.received = 0) as was_hidden
  )
  select count(*) filter (where was_hidden) into v_hidden from upd;
  return v_hidden;
end;
$$;

revoke execute on function public.refresh_smspool_observed_success(interval, integer, integer)
  from public, anon, authenticated;
