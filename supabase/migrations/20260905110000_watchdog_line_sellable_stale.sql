-- Page when a SELLABLE line country is being refused for staleness.
--
-- ── The outage this catches ────────────────────────────────────────────────
-- `sellableCountry()` fails closed when a row's `coverage_checked_at` or (with
-- no approved requirement group) `requirements_checked_at` is older than
-- `line_country_catalog_max_age_hours` (48). `sync-line-countries` re-probed
-- requirements every 7 DAYS. So every sellable country went dark 48h after its
-- probe and stayed dark until the weekly sweep returned — the whole Number
-- store answered "We don't sell numbers here yet" in every country. Measured
-- 2026-09-05 from the function logs: 89 / 97 / 53 `line_catalog_stale`
-- refusals on 08-30, 09-01, 09-02, and three hours on 09-05 before the owner
-- hit it by hand. That is the entire window in which 2.7's store was measured
-- at 162 views and zero subscriptions.
--
-- The existing check (1) tests only the sync HEARTBEAT, and the sync was
-- running fine — it simply was not touching the rows that mattered. A
-- heartbeat-only check stays green through exactly this failure, which is the
-- same lesson as the `releasing` rows check on the rented-line lifecycle:
-- check the STATE, not just that something ran.
--
-- ── Procedure ──────────────────────────────────────────────────────────────
-- Regenerated from `pg_get_functiondef` and diffed: exactly ONE hunk differs
-- (the new check 1b below). Every existing clause is byte-identical.

create or replace function public.watchdog_line_catalog_checks()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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

  return fails;
end;
$function$;

revoke execute on function public.watchdog_line_catalog_checks() from public, anon, authenticated;
