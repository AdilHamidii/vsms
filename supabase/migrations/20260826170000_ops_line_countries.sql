-- Ops surface for the international line-country catalog (Phase 7).
--
-- Companion to 20260826160000_line_country_catalog, which added
-- `line_country_catalog` and `refresh_line_country_sellability()`. Nothing in
-- that migration is readable from the ops chat, and nothing watches it — so a
-- sync that blanks the catalog, or a country Telnyx starts refusing orders for,
-- would be invisible until a customer paid for a dead number.
--
-- Two functions and one wiring line:
--   1. ops_line_countries()          — the /lines countries answer
--   2. watchdog_line_catalog_checks() — three checks, composed into run_watchdog
--
-- ── Why a COMPANION watchdog function, again ────────────────────────────────
-- Same reasoning as 20260818120000 (money) and 20260826140000 (delivery):
-- run_watchdog_core is ~15 KB of clauses, each one an incident, and this repo
-- has already turned a one-line refactor of it into a monitoring outage. The
-- composition point is `run_watchdog`, which is 20 lines — the diff below is
-- exactly one declared variable, one call and one concatenation term.
--
-- ⚠️ `run_watchdog` below was regenerated from pg_get_functiondef on
-- 2026-08-26 and carries extra (money) + extra2 (delivery) verbatim. Re-diff
-- before applying: if another session composed a fourth function in the
-- meantime, this CREATE OR REPLACE would silently drop it.
--
-- ── The three checks, and why each one exists ───────────────────────────────
-- `line-country-catalog-stale` — a freshness check on `sync-line-countries`'
-- heartbeat. It reads the heartbeat's OWN `checked_at` VALUE rather than the
-- app_config row's `updated_at`, because `updated_at` is maintained by the
-- app_config_touch trigger and moves whenever ANYTHING writes the row. No
-- alert state is stored on this key today (telegram-notify writes back only
-- onto 'watchdog'), so `updated_at` would in fact be correct right now — but
-- the watchdog verdict itself was read that way once and a dead watchdog plus
-- one re-page read as "ran just now". Read the value; it cannot drift.
--
-- 🔴 It is gated on the catalog HAVING ROWS. An unbootstrapped system — the
-- state on the day this ships — has no heartbeat and no rows, and paging about
-- a sync that has never been deployed is exactly the alert fatigue that hides
-- the next real outage.
--
-- `line-country-none-sellable` — a STATE check, not a freshness one. A sync
-- that runs on schedule, writes its heartbeat and blanks every sell_state is
-- the `releasing`-rows failure repeated: the heartbeat proves the job is alive,
-- never that it produced anything. Zero sellable countries means the product
-- cannot be bought at all.
--
-- `line-country-order-rejected` — the catalog said sellable and Telnyx refused
-- the order (verify-line-subscription writes sell_reason='order_rejected' as a
-- self-healing block). That is our probe being wrong about a country while a
-- customer was at the till, so it pages for 24h with the country codes in the
-- detail. It ages out on its own: the row stays blocked, the alert goes quiet.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. ops_line_countries()
-- ─────────────────────────────────────────────────────────────────────────────
-- Returns an OBJECT, not a bare array: the standing rule from 20260821120000
-- is that every count a formatter prints must be computed in SQL, never over
-- the rows it was handed — ops_route's headline was once an artifact of its own
-- LIMIT. `total` / `sellable` are over the whole set; `countries` is what gets
-- rendered (and capped) by the bot.
--
-- Row set: every `local` row, plus any row of another number_type that is
-- actually sellable. Toll-free/national rows we have merely probed and blocked
-- are noise in an ops list; one that can be sold is not.
--
-- `live_lines` joins phone_lines on (country_code, number_type) over the SAME
-- status set as the `phone_lines_one_live_per_user` partial unique index —
-- provisioning/active/grace/past_due/suspended/releasing. That set is the
-- product's definition of "this number is ours and billing", and a suspended
-- or releasing line is rent we are still paying, so it belongs in the count.
create or replace function public.ops_line_countries()
returns jsonb
language sql
security definer
set search_path = public
as $$
  with rows as (
    select c.*
      from public.line_country_catalog c
     where c.number_type = 'local'
        or c.sell_state = 'sellable'
  ),
  live as (
    select l.country_code, l.number_type, count(*)::int as live_lines
      from public.phone_lines l
     where l.status in ('provisioning','active','grace','past_due',
                        'suspended','releasing')
     group by 1, 2
  ),
  joined as (
    select r.*, coalesce(v.live_lines, 0) as live_lines
      from rows r
      left join live v
        on v.country_code = r.country_code
       and v.number_type  = r.number_type
  )
  select jsonb_build_object(
    'total',    (select count(*) from joined),
    'sellable', (select count(*) from joined where sell_state = 'sellable'),
    'live_lines', (select coalesce(sum(live_lines), 0) from joined),
    'sync',     (select value from public.app_config
                  where key = 'line_country_sync'),
    'max_age_hours', (select value from public.app_config
                       where key = 'line_country_catalog_max_age_hours'),
    'countries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code',                    j.country_code,
        'name',                    j.country_name,
        'number_type',             j.number_type,
        'sell_state',              j.sell_state,
        'sell_reason',             j.sell_reason,
        'sell_override',           j.sell_override,
        'supports_voice',          j.supports_voice,
        'supports_sms',            j.supports_sms,
        'supports_mms',            j.supports_mms,
        'supports_emergency',      j.supports_emergency,
        'stock_seen',              j.stock_seen,
        'sample_monthly_cents',    j.sample_monthly_cents,
        'sample_upfront_cents',    j.sample_upfront_cents,
        'sample_currency',         j.sample_currency,
        'sample_cost_known',       j.sample_cost_known,
        'document_count',          j.document_count,
        'requirement_group_status', j.requirement_group_status,
        'requirements_checked_at', j.requirements_checked_at,
        'coverage_checked_at',     j.coverage_checked_at,
        'last_fault',              j.last_fault,
        'live_lines',              j.live_lines)
        -- Sellable first, then alphabetical: the answer to "what can I sell"
        -- is the top of the list, and the rest is reference.
        order by (j.sell_state = 'sellable') desc, j.country_code, j.number_type)
      from joined j), '[]'::jsonb)
  );
$$;

comment on function public.ops_line_countries() is
  'Ops view of line_country_catalog for /lines countries: per-country sell '
  'state, capabilities, wholesale samples, requirement counts and live_lines '
  '(phone_lines in the one-live-per-user status set). Counts are computed in '
  'SQL, never over the returned array. Service role only.';

revoke execute on function public.ops_line_countries()
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. watchdog_line_catalog_checks()
-- ─────────────────────────────────────────────────────────────────────────────
-- Same contract as watchdog_delivery_checks() / watchdog_money_checks():
-- returns a jsonb ARRAY of {check, detail} objects, empty when healthy.
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

comment on function public.watchdog_line_catalog_checks() is
  'Watchdog companion for line_country_catalog: stale sync heartbeat, zero '
  'sellable countries, and Telnyx order rejections in the last 24h. Silent '
  'while the catalog is empty (an unbootstrapped system must not page).';

revoke execute on function public.watchdog_line_catalog_checks()
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. run_watchdog — regenerated from the live definition, ONE hunk added
-- ─────────────────────────────────────────────────────────────────────────────
-- Diff against pg_get_functiondef('public.run_watchdog()') as of 2026-08-26:
--   + `extra3 jsonb` in the declare list
--   + `extra3 := public.watchdog_line_catalog_checks();`
--   ~ `fails := fails || extra || extra2;`  →  `|| extra3`
-- Everything else — the core/money/delivery calls, the `prev` read, the
-- alerted/last_alert_at carry-forward and the on-conflict upsert — is
-- byte-identical.
create or replace function public.run_watchdog()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare fails jsonb; extra jsonb; extra2 jsonb; extra3 jsonb; prev jsonb;
begin
  fails := public.run_watchdog_core();
  extra := public.watchdog_money_checks();
  extra2 := public.watchdog_delivery_checks();
  extra3 := public.watchdog_line_catalog_checks();
  fails := fails || extra || extra2 || extra3;
  select value into prev from app_config where key = 'watchdog';
  insert into app_config (key, value)
  values ('watchdog', jsonb_build_object('checked_at', now(), 'failing', fails,
    'alerted', coalesce(prev->'alerted','[]'::jsonb), 'last_alert_at', prev->>'last_alert_at'))
  on conflict (key) do update set value = excluded.value;
  return fails;
end; $function$;

revoke execute on function public.run_watchdog() from public, anon, authenticated;
