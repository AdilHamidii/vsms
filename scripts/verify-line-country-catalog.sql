-- Behavioural verification of the international line-country catalog.
-- Runs inside a transaction that ROLLS BACK: nothing here touches live data.
--
-- Covers `20260826160000_line_country_catalog.sql` (the table, the two client
-- views and refresh_line_country_sellability()) and the ACL/watchdog surface
-- added by `20260826170000_ops_line_countries.sql`. Structural checks (do the
-- objects exist, are the grants revoked) prove nothing about BEHAVIOUR — this
-- proves the sellability state machine actually computes what its own comment
-- claims, using fake rows keyed on obviously-fake country codes (Z1..Z9) so
-- nothing here can collide with real catalog data even before the rollback.
--
--   supabase db query --linked --file scripts/verify-line-country-catalog.sql
begin;

do $$
declare
  v_state  text;
  v_reason text;
  fails    jsonb;
  n        integer;
begin
  -- ── 0. Test fixtures. Rolled back with everything else. ──────────────────
  -- Every row starts at the table's own defaults (sell_state='blocked', every
  -- capability/requirement column NULL = never probed) and only the columns a
  -- group cares about are overridden.
  insert into public.line_country_catalog (country_code, number_type)
  values ('Z1','local'), ('Z2','local'), ('Z3','local'), ('Z4','local'),
         ('Z5','local'), ('Z6','local'), ('Z7','local'), ('Z8','local'),
         ('Z9','local');

  -- ── 1. Never probed at all ⇒ blocked / never_probed. ──────────────────────
  -- Z1 keeps every column at its NULL default — coverage_checked_at is null,
  -- which is the FIRST blocking clause after sell_override.
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z1';
  if v_state <> 'blocked' or v_reason <> 'never_probed' then
    raise exception '1 FAILED: Z1 (all-NULL) = %/%, expected blocked/never_probed',
      v_state, v_reason;
  end if;

  -- ── 2. Coverage probed, requirements never probed ⇒ blocked / never_probed.
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = true, supports_voice = true,
         requirements_empty = null, requirements_checked_at = null,
         requirement_group_id = null, requirement_group_status = null
   where country_code = 'Z2';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z2';
  if v_state <> 'blocked' or v_reason <> 'never_probed' then
    raise exception '2 FAILED: Z2 (requirements never probed) = %/%, expected blocked/never_probed',
      v_state, v_reason;
  end if;

  -- ── 3. requirements_empty=false, no requirement group ⇒ blocked / documents_required.
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = true, supports_voice = true,
         requirements_empty = false, requirements_checked_at = now(),
         requirement_group_id = null, requirement_group_status = null
   where country_code = 'Z3';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z3';
  if v_state <> 'blocked' or v_reason <> 'documents_required' then
    raise exception '3 FAILED: Z3 (documents required, no group) = %/%, expected blocked/documents_required',
      v_state, v_reason;
  end if;

  -- ── 4. requirements_empty=false + an APPROVED requirement group ⇒ sellable.
  -- The group is the evidence that overrides a live "documents required" read.
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = true, supports_voice = true,
         requirements_empty = false, requirements_checked_at = now(),
         requirement_group_id = 'RG-1', requirement_group_status = 'approved'
   where country_code = 'Z4';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z4';
  if v_state <> 'sellable' or v_reason is not null then
    raise exception '4 FAILED: Z4 (approved group) = %/%, expected sellable/NULL',
      v_state, v_reason;
  end if;

  -- ── 5. sell_override='force_block' beats an otherwise-approved group ⇒
  --      blocked / owner_blocked. force_block is checked FIRST in the case
  --      expression — no override may ever produce a sellable row.
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = true, supports_voice = true,
         requirements_empty = false, requirements_checked_at = now(),
         requirement_group_id = 'RG-2', requirement_group_status = 'approved',
         sell_override = 'force_block'
   where country_code = 'Z5';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z5';
  if v_state <> 'blocked' or v_reason <> 'owner_blocked' then
    raise exception '5 FAILED: Z5 (force_block over approved group) = %/%, expected blocked/owner_blocked',
      v_state, v_reason;
  end if;

  -- ── 6a. reservable=false ⇒ blocked / not_reservable, even with everything
  --       else healthy. ────────────────────────────────────────────────────
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = false, supports_voice = true,
         requirements_empty = true, requirements_checked_at = now()
   where country_code = 'Z6';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z6';
  if v_state <> 'blocked' or v_reason <> 'not_reservable' then
    raise exception '6a FAILED: Z6 (reservable=false) = %/%, expected blocked/not_reservable',
      v_state, v_reason;
  end if;

  -- ── 6b. supports_voice=false ⇒ blocked / no_voice. ────────────────────────
  -- Every product line the catalog serves is voice-first; SMS-only capability
  -- is not enough on its own.
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = true, supports_voice = false,
         requirements_empty = true, requirements_checked_at = now()
   where country_code = 'Z7';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z7';
  if v_state <> 'blocked' or v_reason <> 'no_voice' then
    raise exception '6b FAILED: Z7 (supports_voice=false) = %/%, expected blocked/no_voice',
      v_state, v_reason;
  end if;

  -- ── 7. sell_reason='order_rejected' on a row that would otherwise compute
  --      sellable is PRESERVED across a refresh. This is the self-healing
  --      block verify-line-subscription writes when Telnyx refuses an order
  --      the catalog said was fine — it must survive a refresh that would
  --      otherwise reopen the exact country that just burned a real order.
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = true, supports_voice = true,
         requirements_empty = true, requirements_checked_at = now(),
         sell_state = 'blocked', sell_reason = 'order_rejected'
   where country_code = 'Z8';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z8';
  if v_state <> 'blocked' or v_reason <> 'order_rejected' then
    raise exception '7 FAILED: Z8 (order_rejected retention) = %/%, expected blocked/order_rejected (preserved)',
      v_state, v_reason;
  end if;

  -- ── 7b. Control: order_rejected does NOT survive when a real reason starts
  --       blocking again — retention only applies while blocked_by is null.
  update public.line_country_catalog
     set coverage_checked_at = now(), reservable = false, supports_voice = true,
         requirements_empty = true, requirements_checked_at = now(),
         sell_state = 'blocked', sell_reason = 'order_rejected'
   where country_code = 'Z9';
  perform public.refresh_line_country_sellability();
  select sell_state, sell_reason into v_state, v_reason
    from public.line_country_catalog where country_code = 'Z9';
  if v_state <> 'blocked' or v_reason <> 'not_reservable' then
    raise exception '7b FAILED: Z9 (real reason overrides order_rejected) = %/%, expected blocked/not_reservable',
      v_state, v_reason;
  end if;

  raise notice 'PASS groups 1-7 (sellability state machine)';

  -- ── 8. line_country_menu exposes ZERO cost/requirement columns. ──────────
  -- The view's own comment names the forbidden set explicitly: it is PUBLIC
  -- (readable by anon with no account at all), and any of these columns would
  -- leak either our wholesale cost book or a compliance record.
  select count(*) into n
    from information_schema.columns
   where table_schema = 'public'
     and table_name   = 'line_country_menu'
     and column_name  in (
       'sample_monthly_cents','sample_upfront_cents','sample_currency',
       'sample_cost_known','requirement_summary','requirement_sets',
       'document_count','requirement_group_id','requirement_group_status',
       'coverage_raw','last_fault'
     );
  if n <> 0 then
    raise exception '8 FAILED: line_country_menu exposes % forbidden column(s)', n;
  end if;
  raise notice 'PASS group 8 (line_country_menu column set)';

  -- ── 9. ACLs, read directly rather than trusting a `revoke` statement was
  --      not shadowed by a PUBLIC grant (this repo has hit that exact trap
  --      more than once — see the CLAUDE.md gotchas on default privileges). ──
  if has_table_privilege('anon', 'public.line_country_catalog', 'select') then
    raise exception '9a FAILED: anon can SELECT line_country_catalog';
  end if;
  if has_table_privilege('authenticated', 'public.line_country_catalog', 'select') then
    raise exception '9b FAILED: authenticated can SELECT line_country_catalog';
  end if;
  if not has_table_privilege('authenticated', 'public.line_country_menu', 'select') then
    raise exception '9c FAILED: authenticated CANNOT SELECT line_country_menu (the client-facing view)';
  end if;
  if has_function_privilege('anon', 'public.refresh_line_country_sellability()', 'execute') then
    raise exception '9d FAILED: anon can EXECUTE refresh_line_country_sellability()';
  end if;

  -- ops_line_countries() ships in a companion migration; guard its existence
  -- so this script still passes against a checkout that has 20260826160000
  -- but not yet 20260826170000.
  if to_regprocedure('public.ops_line_countries()') is not null then
    if has_function_privilege('anon', 'public.ops_line_countries()', 'execute') then
      raise exception '9e FAILED: anon can EXECUTE ops_line_countries()';
    end if;
  else
    raise notice '9e SKIPPED: ops_line_countries() not present in this checkout';
  end if;
  raise notice 'PASS group 9 (ACLs)';

  -- ── 10. Watchdog: with a sellable fake row present, watchdog_line_catalog_
  --       checks() must NOT report 'line-country-none-sellable'. Existence-
  --       guarded for the same reason as group 9e.
  if to_regprocedure('public.watchdog_line_catalog_checks()') is not null then
    fails := public.watchdog_line_catalog_checks();
    if exists (
      select 1 from jsonb_array_elements(fails) e
       where e ->> 'check' = 'line-country-none-sellable'
    ) then
      raise exception '10 FAILED: watchdog reports line-country-none-sellable while Z4 is sellable: %', fails;
    end if;
    raise notice 'PASS group 10 (watchdog_line_catalog_checks, checked against: %)', fails;
  else
    raise notice '10 SKIPPED: watchdog_line_catalog_checks() not present in this checkout';
  end if;

  raise notice 'ALL GROUPS PASSED';
end $$;

rollback;
