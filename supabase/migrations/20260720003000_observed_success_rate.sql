-- success_rate was PURELY SMSPool's self-reported /request/price number —
-- never checked against what actually happens on our own orders. Live
-- incident 2026-07-20: facebook/ch showed "100%" while 9/9 real attempts
-- over 2.5h delivered zero codes (a paying customer who'd just bought 30
-- credits). Credits were correctly refunded every time (no money lost), but
-- the displayed reliability was fiction the whole time.
--
-- This computes a REAL success rate from public.orders and overrides the
-- self-reported one once there's enough same-route sample, and auto-hides
-- any route with proven total failure (0 successes across >= p_min_sample
-- genuine attempts). "Genuine attempt" excludes near-instant cancels
-- (< 90s) — those are inconclusive (not enough time for an SMS to land),
-- not evidence of delivery failure, so one impatient user can't tank a
-- route's stats on their own.
--
-- Self-healing: the bulk pricing phase in sync-smspool re-activates any
-- in-stock route every run; this function re-evaluates right after, so a
-- route only stays hidden while its trailing lookback window still shows
-- zero successes. One real delivery is enough to stop the hide.
create or replace function public.refresh_smspool_observed_success(
  p_lookback interval default interval '3 days',
  p_min_sample integer default 5
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hidden integer;
begin
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

revoke execute on function public.refresh_smspool_observed_success(interval, integer)
  from public, anon, authenticated;
