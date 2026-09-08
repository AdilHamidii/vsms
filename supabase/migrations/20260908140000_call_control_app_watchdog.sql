-- Make inbound calling's configuration durable and watched.
--
-- 🔴 ALL INBOUND CALLING DEPENDS ON ONE `app_config` ROW THAT ONLY A MANUAL
-- PROBE HAS EVER WRITTEN. `telnyx_call_control_app` holds the id of the Call
-- Control application every rented number's inbound voice points at. Telnyx
-- will not route a DID to an on-demand telephony credential, so that
-- application IS the inbound path (number -> app -> telnyx-webhook -> transfer
-- to the device's SIP URI). It was created on 2026-09-08 by
-- `probe-telnyx-connection {"probe":"call_control_ring"}` and written by that
-- probe alone: no migration seeded it, and no watchdog covered it.
--
-- If the row is lost, `provisionLineVoice` falls back to the credential
-- connection — the known-broken path — records a fault nobody reads, and every
-- newly sold line silently cannot ring.
--
-- Two changes, both about durability rather than behaviour:
--   1. seed the key, so a fresh environment does not come up inbound-broken;
--   2. add `line-call-control-app-missing` to the line-catalog watchdog.
--
-- The function below is `pg_get_functiondef` of the live
-- `watchdog_line_catalog_checks()` with ONE block appended before `return
-- fails`. Every other clause is byte-identical — the procedure CLAUDE.md
-- demands after the refactor that silently disabled a delivery check.

insert into public.app_config (key, value)
values ('telnyx_call_control_app',
        jsonb_build_object('id', '3044254304371213803',
                           'note', 'seeded 2026-09-08; created by probe call_control_ring'))
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public.watchdog_line_catalog_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  fails       jsonb := '[]'::jsonb;
  v_rows      int;
  v_sellable  int;
  v_max_age   numeric;
  v_checked   timestamptz;
  v_have_key  boolean;
  v_rejected  text;
  v_rej_n     int;
  v_stale     text;
  v_stale_n   int;
begin
  select count(*), count(*) filter (where sell_state = 'sellable')
    into v_rows, v_sellable
    from line_country_catalog;

  -- Nothing probed yet: every check below is about a catalog that exists.
  -- Returning empty here is the whole "do not page an unbootstrapped system"
  -- rule, in one branch.
  if coalesce(v_rows, 0) = 0 then
    return fails;
  end if;

  -- ── (1) The country sync has stopped ──────────────────────────────────────
  -- A scalar SUBQUERY, not `select … into … from app_config`: an INTO that
  -- matches no row writes NULL over the variable, so a deleted config key
  -- would silently disarm the comparison below. This is the same shape as the
  -- "a guard reading a config key nobody writes fails open and silent" lesson.
  v_max_age := coalesce(
    (select (value #>> '{}')::numeric from app_config
      where key = 'line_country_catalog_max_age_hours'), 48);

  select true, (value->>'checked_at')::timestamptz
    into v_have_key, v_checked
    from app_config where key = 'line_country_sync';

  if coalesce(v_have_key, false) is not true
     or v_checked is null
     or v_checked < now() - make_interval(hours => greatest(v_max_age, 1)::int) then
    fails := fails || jsonb_build_object(
      'check', 'line-country-catalog-stale',
      'detail', v_rows || ' catalog row(s) and the sync-line-countries ' ||
                'heartbeat is ' ||
                coalesce('from ' || v_checked::text, 'missing entirely') ||
                ' (max age ' || v_max_age || 'h) — sell states and wholesale ' ||
                'samples are being served from a stale probe');
  end if;

  -- ── (1b) A SELLABLE row is past the gate and is being REFUSED ─────────────
  -- Mirrors `sellableCountry()` exactly: coverage always counts; requirements
  -- count unless an APPROVED group stands in for them. The sync heartbeat
  -- above can be perfectly fresh while this fires — that is the 2026-09-05
  -- outage, and it is why this is a separate check with its own name.
  select count(*), string_agg(upper(country_code) || '/' || number_type, ', '
                              order by upper(country_code), number_type)
    into v_stale_n, v_stale
    from line_country_catalog
   where sell_state = 'sellable'
     and (
       coverage_checked_at is null
       or coverage_checked_at < now() - make_interval(hours => greatest(v_max_age, 1)::int)
       or (
         not (requirement_group_id is not null and requirement_group_status = 'approved')
         and (requirements_checked_at is null
              or requirements_checked_at < now() - make_interval(hours => greatest(v_max_age, 1)::int))
       )
     );

  if coalesce(v_stale_n, 0) > 0 then
    fails := fails || jsonb_build_object(
      'check', 'line-country-sellable-stale',
      'detail', v_stale_n || ' sellable row(s) past the ' || v_max_age ||
                'h freshness gate (' || coalesce(v_stale, '?') || ') — every ' ||
                'seller is REFUSING them as country_not_sellable right now; ' ||
                'run sync-line-countries');
  end if;

  -- ── (2) Nothing is sellable ───────────────────────────────────────────────
  if coalesce(v_sellable, 0) = 0 then
    fails := fails || jsonb_build_object(
      'check', 'line-country-none-sellable',
      'detail', 'the catalog holds ' || v_rows || ' row(s) and NONE is ' ||
                'sellable — no second number can be rented in any country');
  end if;

  -- ── (3) Telnyx refused an order we said was sellable ──────────────────────
  select count(*), string_agg(distinct upper(country_code), ', ' order by upper(country_code))
    into v_rej_n, v_rejected
    from line_country_catalog
   where sell_reason = 'order_rejected'
     and last_checked_at >= now() - interval '24 hours';

  if coalesce(v_rej_n, 0) > 0 then
    fails := fails || jsonb_build_object(
      'check', 'line-country-order-rejected',
      'detail', 'Telnyx refused an order in ' || coalesce(v_rejected, '?') ||
                ' in the last 24h after the catalog said it was sellable — ' ||
                'the row has self-blocked, but the probe was wrong while a ' ||
                'customer was paying');
  end if;

  -- ── (4) Inbound calling has no Call Control application to route to ───────
  -- Every rented number's INBOUND voice points at the account-wide Call
  -- Control application named by `app_config.telnyx_call_control_app`.
  -- `provisionLineVoice` reads that key; when it is missing it falls back to
  -- the credential connection, which Telnyx will NOT route a DID to — the
  -- exact configuration that meant no inbound call ever connected in the
  -- product's first five weeks. The fallback records a fault nobody reads, so
  -- without this check a lost row means every newly sold line silently cannot
  -- ring, and the only symptom is a customer saying their phone never rang.
  if not exists (select 1 from app_config
                  where key = 'telnyx_call_control_app'
                    and coalesce(value->>'id', '') <> '') then
    fails := fails || jsonb_build_object(
      'check', 'line-call-control-app-missing',
      'detail', 'app_config.telnyx_call_control_app is missing or has no id — ' ||
                'every line provisioned from now on will be pointed at its ' ||
                'credential connection instead, and INBOUND CALLS TO IT WILL ' ||
                'NOT RING. Re-create it with probe-telnyx-connection ' ||
                '{"probe":"call_control_ring"} and re-run sync-line-voice');
  end if;

  return fails;
end;
$function$

