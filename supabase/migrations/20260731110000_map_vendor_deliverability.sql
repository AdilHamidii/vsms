-- Map the raw HeroSMS deliverability payloads onto our own service/country ids.
--
-- The shape is now KNOWN, from a real response rather than a guess:
--
--   { "data": [ { "country": 187, "service": "fb", "percent": 43.4 }, ... ] }
--
-- `country` is HeroSMS's numeric country id (-> countries.herosms_id),
-- `service` is their service code (-> services.herosms_code), `percent` is the
-- success rate over the requested interval.
--
-- ⚠️ IT IS A TOP-10 LIST, NOT A FULL TABLE. The request carries
-- `ranking=Top 10 Countries`, so each service returns at most ten rows. That
-- makes ABSENCE MEANINGLESS: a country missing from the list is "not in the top
-- ten", which is nothing like "delivers badly". Facebook alone is bookable in
-- 47 countries and reports ten.
--
-- This is the single easiest way to poison the steering, and it is exactly the
-- mistake this codebase already made once: SMSPVA's seeded per-country grade
-- ranked untested routes as "proven" and had to be demoted to .notTested. So
-- `rank` is exposed and there is deliberately NO row for an unlisted country —
-- consumers must treat "no row" as no information, never as a low score.
--
-- And the standing rule stands: this is HeroSMS's aggregate across ALL their
-- customers, not our delivery. Steering input, never a badge, and never written
-- into routes.success_rate.

create or replace view public.vendor_deliverability_mapped as
select
  s.id                                        as service_id,
  c.id                                        as country_id,
  (e.value ->> 'percent')::numeric            as vendor_percent,
  row_number() over (
    partition by vd.service_code
    order by (e.value ->> 'percent')::numeric desc
  )                                           as vendor_rank,
  vd.service_code                             as vendor_service_code,
  (e.value ->> 'country')::int                as vendor_country_id,
  vd.params ->> 'interval'                    as interval_hours,
  vd.params ->> 'successCount'                as success_count_filter,
  vd.fetched_at
from public.vendor_deliverability vd
cross join lateral jsonb_array_elements(vd.payload -> 'data') as e(value)
-- INNER joins on purpose: a vendor id we cannot map is not silently coerced
-- into some nearby country. Unmapped rows are surfaced by the diagnostic below
-- instead, so the gap is visible rather than invented.
join public.services  s on s.herosms_code = vd.service_code
join public.countries c on c.herosms_id   = (e.value ->> 'country')::int
where vd.provider = 'herosms'
  and jsonb_typeof(vd.payload -> 'data') = 'array';

comment on view public.vendor_deliverability_mapped is
  'HeroSMS top-10 deliverability per service, mapped to our ids. ABSENCE OF A ROW '
  'MEANS NO INFORMATION, not a low rate — the source is a top-10 ranking. Vendor '
  'aggregate across all their customers: steering input only, never a badge.';

-- What could not be mapped, so a missing country/service mapping is visible
-- rather than a silently shorter list.
create or replace view public.vendor_deliverability_unmapped as
select vd.service_code,
       (e.value ->> 'country')::int as vendor_country_id,
       (e.value ->> 'percent')::numeric as vendor_percent,
       (s.id is null) as service_unmapped,
       (c.id is null) as country_unmapped
from public.vendor_deliverability vd
cross join lateral jsonb_array_elements(vd.payload -> 'data') as e(value)
left join public.services  s on s.herosms_code = vd.service_code
left join public.countries c on c.herosms_id   = (e.value ->> 'country')::int
where vd.provider = 'herosms'
  and jsonb_typeof(vd.payload -> 'data') = 'array'
  and (s.id is null or c.id is null);

-- The actionable question, answerable the moment data lands: for services we
-- actually sell, which vendor-recommended countries are we failing to put in
-- front of users — because the route is hidden, missing, or priced beyond what
-- the signup grant can reach?
create or replace view public.vendor_deliverability_gaps as
select m.service_id,
       m.country_id,
       m.vendor_percent,
       m.vendor_rank,
       r.status                       as route_status,
       r.retail_credits,
       -- The 3-credit signup grant is what a brand-new user actually holds, and
       -- landing them above it is how they end up in the cheap-and-worst tier.
       (r.retail_credits is not null and r.retail_credits > 3) as above_signup_grant,
       r.success_codes,
       r.success_sample
from public.vendor_deliverability_mapped m
left join public.routes r
       on r.service_id = m.service_id and r.country_id = m.country_id
-- `routes` is keyed on (service_id, country_id) and has NO id column, so the
-- left-join miss is detected on service_id.
where r.service_id is null                           -- no route at all
   or r.status <> 'active'                           -- hidden
   or (r.retail_credits is not null and r.retail_credits > 3)  -- unaffordable at signup
order by m.service_id, m.vendor_rank;

revoke all on public.vendor_deliverability_mapped   from anon, authenticated;
revoke all on public.vendor_deliverability_unmapped from anon, authenticated;
revoke all on public.vendor_deliverability_gaps     from anon, authenticated;
