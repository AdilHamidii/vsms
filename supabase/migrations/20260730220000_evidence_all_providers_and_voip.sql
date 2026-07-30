-- Delivery work, three parts. See docs/plan and CLAUDE.md.
--
-- 1. Gather route/service/country evidence for EVERY provider, not just the one
--    `active_sms_provider()` happens to vote for.
-- 2. A config list of services that reject VoIP numbers.
-- 3. Record, on each order, whether the route had real-SIM stock — so the
--    hypothesis behind (2) can actually be tested later instead of believed.

-- ── 1. Evidence for every provider ───────────────────────────────────────────
--
-- `refresh_route_observed_success` and friends scope every statement to
-- `coalesce(p_provider, active_sms_provider())`, and `active_sms_provider()`
-- votes by ACTIVE ROUTE COUNT. After the HeroSMS cutover made the catalog a
-- per-service split, and `sync-herosms` hid the routes HeroSMS cannot serve,
-- SMSPVA held 7,757 active routes against HeroSMS's 5,201 — so the vote
-- returned `smspva`, the provider that was no longer serving the demand.
--
-- Consequence, measured 2026-07-30: `rate_source = 'measured'` was **0 rows**
-- catalog-wide. Every route rendered "Not tested", all steering fell through to
-- the untested tier, and the pre-registered "conclusive delivery over the first
-- 40 orders" rollback checkpoint for the switch could not be evaluated at all.
--
-- Re-tuning the vote is the wrong fix: a vote by recent order count is unstable
-- mid-cutover, and it keeps one provider's evidence hostage to another's row
-- count. Blending providers is also wrong — a single rate averages a retired
-- provider with a live one and describes neither. The functions are already
-- provider-scoped and take `p_provider`, so simply run them once per provider.
create or replace function public.refresh_evidence_all_providers(
  p_lookback   interval default '30 days'::interval,
  p_min_sample integer  default 3
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_provider  text;
  v_out       jsonb := '{}'::jsonb;
  v_routes    integer;
  v_services  integer;
  v_countries integer;
begin
  for v_provider in
    select distinct provider
    from public.routes
    where status = 'active' and provider is not null
    order by 1
  loop
    v_routes    := public.refresh_route_observed_success(p_lookback, p_min_sample, v_provider);
    v_services  := public.refresh_service_delivery(p_lookback, v_provider);
    v_countries := public.refresh_country_delivery(p_lookback, v_provider);

    -- Per-provider counts, not a single total: a run that touched 40 SMSPVA
    -- routes and 0 HeroSMS ones is the exact failure this function exists to
    -- make visible, and a summed integer would hide it.
    v_out := v_out || jsonb_build_object(v_provider, jsonb_build_object(
      'routes', v_routes, 'services', v_services, 'countries', v_countries));
  end loop;

  return v_out;
end;
$$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC, and anon/authenticated are members
-- of PUBLIC — so revoking from anon/authenticated alone is a no-op. Revoke from
-- PUBLIC explicitly and assert with has_function_privilege, never by reading
-- the migration back.
revoke execute on function public.refresh_evidence_all_providers(interval, integer)
  from public, anon, authenticated;

comment on function public.refresh_evidence_all_providers(interval, integer) is
  'Runs the three provider-scoped evidence refreshes once per provider that '
  'owns active routes. Replaces the bare calls in sync-prices, which only ever '
  'measured whichever provider active_sms_provider() voted for.';

-- ── 2. Services that reject VoIP numbers ────────────────────────────────────
--
-- Same shape and role as `blocked_routes`: a hand-maintained kill-list, edited
-- without a deploy. Meta's properties reject VoIP ranges, which is the whole
-- reason we moved to a provider that reports real-SIM stock.
insert into public.app_config (key, value)
values ('voip_strict_services', '["facebook","instagram","whatsapp"]'::jsonb)
on conflict (key) do nothing;

-- ── 3. Make the VoIP hypothesis falsifiable ─────────────────────────────────
--
-- Hiding VoIP-only routes for these services is a well-motivated GUESS until it
-- is measured. Recording what we knew at reservation is what lets us settle it:
--
--   select (route_physical_count > 0) as had_real_sims,
--          count(*), count(*) filter (where otp is not null)
--   from public.orders
--   where smspva_number is not null and provider = 'herosms'
--     and service_id in ('facebook','instagram','whatsapp')
--   group by 1;
--
-- Nullable, and null for every historical row: absence means "we did not record
-- it", which must never be read as "no real SIMs".
alter table public.orders
  add column if not exists route_physical_count integer;

comment on column public.orders.route_physical_count is
  'HeroSMS physicalCount for the route at reservation time (real-SIM stock). '
  'Null = not recorded, NOT zero. Exists to test whether steering onto '
  'real-SIM routes actually improves delivery for VoIP-strict services.';
