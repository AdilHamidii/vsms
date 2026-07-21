-- The self-report cap turned into a fabricated fact: 5,256 of 6,962 active
-- routes displayed exactly 90 — a placeholder rendered to users as a measured
-- reliability figure. Worse, the app's "best success" sorts key on
-- success_rate and tie-break on LOWEST price, so a catalog tied at 90
-- silently degenerated into "cheapest first" — and the cheapest pool is the
-- worst inventory. bestCountry(for: facebook) was returning Albania on zero
-- evidence, shown as "90% delivered - Reliable route".
--
-- Correct behaviour: unverified means NULL (the app renders nothing), and only
-- rates we measured from our own orders are ever displayed.
create or replace function public.refresh_smspool_observed_success(
  p_lookback interval default interval '3 days',
  p_min_sample integer default 3,
  p_self_report_cap integer default 90   -- retained for signature compatibility
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hidden integer;
begin
  update public.routes set success_rate = null where provider = 'smspool';

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
