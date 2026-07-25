-- Make refresh_arrival_timing actually runnable.
--
-- WHY: wiring it into sync-prices' maintenance list (the migration that created
-- it always claimed it was there) surfaced that it could never have run via RPC
-- at all: `maintenance.arrivalTiming` came back
--   "error: UPDATE requires a WHERE clause"
-- The statement that stamps the GLOBAL arrival band onto every service had no
-- WHERE, and Supabase's safeupdate guard rejects unqualified UPDATEs for the
-- roles edge functions run as. So the p50/p90 in `services` were written once
-- by hand and then froze — and the app, once it starts reading them, would have
-- been quoting a snapshot that never refreshed.
--
-- `where id is not null` is semantically a no-op (id is the primary key) and
-- keeps the intent: every service gets the global band, then services with
-- enough of their own deliveries overwrite it below.

CREATE OR REPLACE FUNCTION public.refresh_arrival_timing(p_lookback interval DEFAULT '30 days'::interval, p_hold_seconds integer DEFAULT 120, p_min_service integer DEFAULT 8, p_min_p90 integer DEFAULT 20, p_min_global integer DEFAULT 20, p_provider text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
         arrival_hold_pct    = g_hold
   where id is not null;

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
$function$
;

revoke execute on function public.refresh_arrival_timing(interval, int, int, int, int, text)
  from public, anon, authenticated;
