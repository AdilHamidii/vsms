-- Evidence needed to warn bluntly (and to refuse to warn on thin evidence).
--
-- WHY: four services account for 33 orders and 1 delivered code across ~13
-- distinct users — Instagram (1/15, reaching more distinct users than any other
-- service), Betano (0/9), WhatsApp (0/5), Telegram (0/4). The catalog kept
-- selling them, and the browse rows rendered a sub-40% rate in GREY, i.e. calmer
-- than an amber 45% route. Two gaps made the warnings toothless:
--
--   1. `observed_attempts` only counts CONCLUSIVE orders, so a service that has
--      never once delivered can sit below the sample gate and show nothing at
--      all (WhatsApp: 5 orders, 3 conclusive). "We have never seen this work"
--      needs the raw order count, which nothing recorded.
--   2. `routes.success_rate` shipped without its sample size, so the client
--      could not distinguish 1-of-3 (noise) from 2-of-40 (a real disaster) and
--      therefore could not safely interrupt a purchase on it.
--
-- Both new columns exist ONLY to raise a warning on strong evidence, never to
-- reassure on weak evidence.

alter table public.services add column if not exists observed_orders int;
comment on column public.services.observed_orders is
  'Closed orders on the ACTIVE provider, ALL outcomes — a superset of observed_attempts '
  '(which counts only conclusive ones). Used ONLY to warn when observed_codes = 0; '
  'never to reassure.';

alter table public.routes add column if not exists success_sample int;
comment on column public.routes.success_sample is
  'Conclusive orders behind routes.success_rate. The client requires >= 5 before a rate '
  'may interrupt a purchase; refresh_route_observed_success writes rates from 3.';

-- refresh_service_delivery: unchanged except it now also records the raw order
-- count. Full body restated (create or replace cannot patch a CTE).
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
  set observed_attempts = null, observed_codes = null, observed_orders = null
  where observed_attempts is not null or observed_orders is not null;

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

revoke execute on function public.refresh_service_delivery(interval, text)
  from public, anon, authenticated;

-- refresh_route_observed_success: unchanged except it now also records the
-- sample size behind each measured rate. p_min_sample default stays 3 — the
-- badge may render from 3, but the client's purchase interrupt requires 5.
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
        rate_source = 'measured',
        success_sample = obs.closed,
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
