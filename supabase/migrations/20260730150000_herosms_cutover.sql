-- HeroSMS cutover: snapshot the evidence, then re-home HeroSMS-served services.
--
-- OWNERSHIP IS PER SERVICE, NOT PER ROUTE (owner decision 2026-07-30):
--   * a service HeroSMS carries  -> HeroSMS, in every country
--   * a service it does not      -> stays on SMSPVA, in every country
--
-- A service is therefore never split across providers. That keeps per-service
-- delivery evidence attributable to one vendor — a blended rate destroys
-- exactly that, and once read 10% while the live provider was at 43%.
--
-- It also keeps the catalog whole: the 118 services with no HeroSMS code retain
-- all 7,757 of their active routes on SMSPVA instead of going dark. HeroSMS
-- takes the 150 services carrying 99.4% of lifetime order volume.
--
-- One transaction, with assertions that roll everything back rather than leave
-- a half-cut-over catalog.

begin;

-- ── 1. Freeze the evidence BEFORE anything moves ────────────────────────────
--
-- `active_sms_provider()` returns whichever provider owns the most ACTIVE
-- routes, and refresh_route_observed_success / refresh_service_delivery /
-- refresh_country_delivery / refresh_arrival_timing / recent_sms_delivery_rate
-- all filter on it. The instant HeroSMS holds the majority, every one of them
-- starts measuring a provider with zero orders and wipes what it finds stale —
-- 14 measured routes, 23 services, 20 countries and 268 arrival rows, gone
-- within the hour, silently, each function returning 200.
--
-- orders.provider is stamped per row and is the durable record; this snapshot
-- is for the DERIVED columns with no other home, above all routes.success_*,
-- which ships to every phone.
create table if not exists public.provider_evidence_snapshot (
  id          bigint generated always as identity primary key,
  label       text        not null,
  taken_at    timestamptz not null default now(),
  scope       text        not null check (scope in ('route','service','country','arrival')),
  provider    text        not null,
  service_id  text,
  country_id  text,
  status              text,
  retail_credits      integer,
  premium_credits     integer,
  last_cost_cents     integer,
  smoothed_cost_cents integer,
  smspva_operator     text,
  success_rate        integer,
  rate_source         text,
  success_sample      integer,
  success_codes       integer,
  observed_attempts   integer,
  observed_codes      integer,
  observed_orders     integer,
  sort_order          integer,
  arrival_p50_seconds integer,
  arrival_p90_seconds integer,
  arrival_sample      integer,
  arrival_scope       text,
  herosms_code        text,
  herosms_id          integer
);

alter table public.provider_evidence_snapshot enable row level security;
revoke all on public.provider_evidence_snapshot from public, anon, authenticated;

insert into public.provider_evidence_snapshot
  (label, scope, provider, service_id, country_id, status, retail_credits,
   premium_credits, last_cost_cents, smoothed_cost_cents, smspva_operator,
   success_rate, rate_source, success_sample, success_codes, herosms_code, herosms_id)
select 'pre-herosms', 'route', r.provider, r.service_id, r.country_id, r.status,
       r.retail_credits, r.premium_credits, r.last_cost_cents, r.smoothed_cost_cents,
       r.smspva_operator, r.success_rate, r.rate_source, r.success_sample,
       r.success_codes, s.herosms_code, c.herosms_id
from public.routes r
join public.services  s on s.id = r.service_id
join public.countries c on c.id = r.country_id
where r.rate_source is not null or r.smspva_operator is not null;

insert into public.provider_evidence_snapshot
  (label, scope, provider, service_id, observed_attempts, observed_codes,
   sort_order, arrival_p50_seconds, arrival_p90_seconds, arrival_sample,
   arrival_scope, herosms_code)
select 'pre-herosms', 'service', public.active_sms_provider(), s.id,
       s.observed_attempts, s.observed_codes, s.sort_order,
       s.arrival_p50_seconds, s.arrival_p90_seconds, s.arrival_sample,
       s.arrival_scope, s.herosms_code
from public.services s
where s.observed_attempts is not null or s.arrival_scope is not null
   or s.sort_order >= 5000;

insert into public.provider_evidence_snapshot
  (label, scope, provider, country_id, observed_attempts, observed_codes,
   observed_orders, herosms_id)
select 'pre-herosms', 'country', public.active_sms_provider(), c.id,
       c.observed_attempts, c.observed_codes, c.observed_orders, c.herosms_id
from public.countries c
where c.observed_attempts is not null;

-- ── 2. Retire the premium tier ON HEROSMS SERVICES ONLY ─────────────────────
--
-- premium_credits and smspva_operator are written ONLY by
-- sync-smspva-operators and describe an SMSPVA carrier. On a HeroSMS order
-- there is no pin to apply, so the tier would charge a 20-50% uplift and
-- reserve exactly the number the standard tier reserves. create-order refuses
-- it with 409, but the shipped app renders the tier chips from
-- premium_credits — so null it out and the option disappears from the UI
-- rather than erroring when tapped.
--
-- Deliberately scoped to HeroSMS-owned services: routes still served by SMSPVA
-- keep a working premium tier, and sync-smspva-operators keeps maintaining it
-- for them.
--
-- The pins and prices are preserved in the snapshot above, so this is
-- reversible.
update public.routes r
   set premium_credits = null
  from public.services s
 where s.id = r.service_id
   and s.herosms_code is not null
   and r.premium_credits is not null;

-- ── 3. Re-home the HeroSMS-served services ──────────────────────────────────
--
-- Every route of every service HeroSMS carries. This flips
-- active_sms_provider() to 'herosms', so from here the evidence functions
-- measure the provider serving the large majority of orders.
--
-- SMSPVA rows are NOT deleted anywhere — rollback is dropping the first branch
-- of providerOrder() plus reverting this UPDATE.
update public.routes r
   set provider = 'herosms'
  from public.services s
 where s.id = r.service_id
   and s.herosms_code is not null;

-- ── 4. Assertions — fail the whole transaction rather than half-cut over ────
do $$
declare
  n_hero int; n_pva int; n_split int; n_premium_hero int; n_snap int; v_active text;
begin
  select count(*) into n_hero from public.routes where provider = 'herosms';
  select count(*) into n_pva  from public.routes where provider = 'smspva';
  select count(*) into n_snap from public.provider_evidence_snapshot where label = 'pre-herosms';
  select public.active_sms_provider() into v_active;

  -- THE invariant the owner asked for: no service split across providers.
  select count(*) into n_split from (
    select r.service_id from public.routes r
     group by r.service_id having count(distinct r.provider) > 1) t;

  select count(*) into n_premium_hero
    from public.routes r join public.services s on s.id = r.service_id
   where s.herosms_code is not null and r.premium_credits is not null;

  raise notice 'herosms cutover: % hero routes, % smspva routes, % split services, % snapshot rows, active_sms_provider=%',
    n_hero, n_pva, n_split, n_snap, v_active;

  if n_snap = 0 then
    raise exception 'evidence snapshot is empty — refusing to cut over blind';
  end if;
  if n_split > 0 then
    raise exception '% services are split across providers — the one thing this design forbids', n_split;
  end if;
  if n_premium_hero > 0 then
    raise exception 'premium_credits still set on % HeroSMS routes — the tier would 409 when tapped', n_premium_hero;
  end if;
  if v_active is distinct from 'herosms' then
    raise exception 'active_sms_provider() is % — evidence would measure the minority provider', v_active;
  end if;
end $$;

commit;
