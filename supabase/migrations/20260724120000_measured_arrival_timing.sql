-- Measured arrival timing — replace the seed `eta_seconds` promise with fact.
--
-- WHY: `services.eta_seconds` is seed data (22-35s across the catalog, DB default
-- 30, never recomputed by anything). The app rendered it as fact in four places
-- ("Usually arrives in 28s"). Measured median arrival on the live provider is
-- ~53s and p90 is ~139s. So the app promised a wait it could not keep, and users
-- cancelled at a median of 63s believing the code was already overdue — 36 of 52
-- cancels happen under two minutes, while 86% of every code we have ever
-- delivered arrived inside that same window. We were manufacturing the
-- impatience that costs us the sale.
--
-- Scope decision: percentiles are resolved SERVER-side onto `services` with a
-- `arrival_scope` marker, not computed per route. Only 2 of 18,492 routes have
-- >= 8 deliveries, and `routes` ships to every phone with select=* — 18k rows of
-- NULL columns to serve two routes is a bad trade. Service tier -> global tier,
-- and NULL when even the global sample is too thin. `eta_seconds` is never
-- consulted again; when there is no measurement the UI says something
-- structural and true instead of a number.

alter table public.services
  add column if not exists arrival_p50_seconds int,
  add column if not exists arrival_p90_seconds int,
  add column if not exists arrival_sample      int,
  add column if not exists arrival_scope       text,
  add column if not exists arrival_hold_pct    int;

alter table public.services drop constraint if exists services_arrival_scope_check;
alter table public.services add constraint services_arrival_scope_check
  check (arrival_scope is null or arrival_scope in ('service','global'));

comment on column public.services.arrival_p50_seconds is
  'Median seconds created_at -> arrived_at on the ACTIVE provider. NOTE: arrived_at is '
  'DETECTION time (check-order polls every 4s while the app is open; poll-active-orders '
  'is a 1-minute cron), so backgrounded orders read up to ~60s slow. The bias overstates '
  'the wait, which is the safe direction. NULL = no claim may be made; never fall back '
  'to services.eta_seconds, which is seed data.';

comment on column public.services.arrival_scope is
  'service = this service earned its own percentiles; global = catalog-wide fallback '
  'copied onto the row. The UI MUST NOT phrase a global band as service-specific.';

comment on column public.services.arrival_hold_pct is
  'Share of DELIVERED codes that landed within the WaitingScreen patience hold '
  '(p_hold_seconds, 120). Conditioned on delivery — it is NOT the chance of getting a '
  'code. Keep in lockstep with WaitingScreen.holdSeconds.';

-- Percentiles over delivered orders, service tier then global tier.
-- Called from sync-prices' hourly maintenance list (no new cron, so no new
-- run_watchdog freshness check needed — a dead sync-prices already pages).
create or replace function public.refresh_arrival_timing(
  p_lookback     interval default '30 days',
  p_hold_seconds int      default 120,   -- MUST match WaitingScreen.holdSeconds
  p_min_service  int      default 8,     -- p50 gate per service
  p_min_p90      int      default 20,    -- a p90 under 20 samples is just "the slowest one"
  p_min_global   int      default 20,
  p_provider     text     default null
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_provider text := coalesce(p_provider, public.active_sms_provider());
  g_n int; g_p50 int; g_p90 int; g_hold int; v_updated int;
begin
  -- Staleness is worse than absence: wipe every row we own before rewriting, so
  -- a provider switch degrades to "say nothing" rather than to yesterday's
  -- numbers describing a provider we no longer use.
  update public.services
     set arrival_p50_seconds = null, arrival_p90_seconds = null,
         arrival_sample = null, arrival_scope = null, arrival_hold_pct = null
   where arrival_scope is not null;

  select count(*),
         ceil(percentile_cont(0.5) within group (order by secs))::int,
         ceil(percentile_cont(0.9) within group (order by secs))::int,
         round(100.0 * count(*) filter (where secs <= p_hold_seconds)
               / nullif(count(*), 0))::int
    into g_n, g_p50, g_p90, g_hold
  from (
    select extract(epoch from (o.arrived_at - o.created_at))::numeric as secs
      from public.orders o
     where o.provider = v_provider
       and o.arrived_at is not null
       and o.arrived_at > o.created_at
       and o.created_at >= now() - p_lookback
       and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
  ) d;

  -- No honest claim available anywhere: leave everything NULL and stay silent.
  if coalesce(g_n, 0) < p_min_global then
    return 0;
  end if;

  update public.services
     set arrival_p50_seconds = g_p50,
         arrival_p90_seconds = case when g_n >= p_min_p90 then g_p90 end,
         arrival_sample      = g_n,
         arrival_scope       = 'global',
         arrival_hold_pct    = g_hold;

  -- Services with enough of their own deliveries overwrite the global band.
  with per as (
    select o.service_id,
           count(*) as n,
           ceil(percentile_cont(0.5) within group
                (order by extract(epoch from (o.arrived_at - o.created_at))))::int as p50,
           ceil(percentile_cont(0.9) within group
                (order by extract(epoch from (o.arrived_at - o.created_at))))::int as p90,
           round(100.0 * count(*) filter (
                   where extract(epoch from (o.arrived_at - o.created_at)) <= p_hold_seconds)
                 / count(*))::int as hold
      from public.orders o
     where o.provider = v_provider
       and o.arrived_at is not null
       and o.arrived_at > o.created_at
       and o.created_at >= now() - p_lookback
       and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     group by o.service_id
    having count(*) >= p_min_service
  ),
  upd as (
    update public.services s
       set arrival_p50_seconds = per.p50,
           arrival_p90_seconds = case when per.n >= p_min_p90 then per.p90 end,
           arrival_sample      = per.n,
           arrival_scope       = 'service',
           arrival_hold_pct    = per.hold
      from per where s.id = per.service_id
    returning 1
  )
  select count(*) into v_updated from upd;

  return v_updated;
end;
$function$;

revoke execute on function public.refresh_arrival_timing(interval, int, int, int, int, text)
  from public, anon, authenticated;
