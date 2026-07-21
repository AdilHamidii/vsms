-- Seed route delivery evidence from SMSPVA's own conversions data.
--
-- Since the SMSPVA cutover, success_rate is null on all 16,320 active routes:
-- observed success is provider-scoped with a 3-day window and there is barely
-- any SMSPVA volume yet. Consequences: no delivery badges in the app, the
-- evidence-first steering has nothing to aim at, and 0-delivery combos stay
-- bookable. SMSPVA publishes a per-country conversion grade (0-3) per service
-- — their own measurement. sync-smspva-conversions (hourly cron below) maps
-- positive grades onto success_rate as a PRIOR: 3→90, 2→70, 1→40; grade 0 is
-- ignored (ambiguous: bad OR simply unmeasured — never condemn on it).
--
-- Two sources must coexist without fighting:
--   measured (our own orders, refresh_route_observed_success, hourly) always
--   OVERRULES seeded; seeded fills the gaps and is refreshed by its own sync.
-- rate_source tracks which one owns the current value.

alter table public.routes add column if not exists rate_source text;
alter table public.routes drop constraint if exists routes_rate_source_check;
alter table public.routes add constraint routes_rate_source_check
  check (rate_source in ('measured', 'seeded'));

comment on column public.routes.rate_source is
  'Provenance of success_rate: measured = our own order outcomes '
  '(refresh_route_observed_success); seeded = SMSPVA conversions prior '
  '(sync-smspva-conversions). Measured always overrules seeded.';

-- refresh_route_observed_success now clears ONLY measured rows before
-- rewriting them, so conversion seeds persist until real orders overrule
-- them. (The old full null-sweep existed to kill stale ratings; staleness is
-- now handled per-source: measured is cleared+rewritten hourly here, seeded
-- is cleared+rewritten per service by its own sync.)
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
  set success_rate = null, rate_source = null
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

-- Hourly, additive (no pin-clearing, no user-visible flicker), so it needs no
-- maintenance window. 12 service codes per run at 4s spacing rotates the full
-- ~260-code catalog in about a day; conversion grades move slowly.
select cron.schedule(
    'relay-sync-smspva-conversions',
    '49 * * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-smspva-conversions',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $cmd$
);
