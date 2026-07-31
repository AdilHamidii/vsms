-- Force a REAL SIM on US numbers, for every service.
--
-- Probed 2026-07-31 against HeroSMS: `getOperators` for the US lists a pool
-- literally named `physic` alongside the carriers, and
-- `getNumbersStatus?country=187&operator=physic` returns ~113 numbers per
-- service against ~450,000 unfiltered — the default US pool is ~99.97% VoIP.
--
-- Evidence this matters, from the preceding 12 hours: badoo/us and bumble/us
-- took **175 of the 198 credits charged** across 5 orders and returned ZERO
-- codes, all refunded. The new evidence pipeline had already measured badoo/us
-- at 0 of 3.
--
-- `create-order` pins this operator STRICTLY (a dry pool fails the order rather
-- than silently handing back the VoIP number the setting exists to avoid), and
-- `sync-herosms` hides any route in a listed country whose service has no
-- physical stock — 74 of 101 active US routes, badoo and bumble among them.
--
-- Rollback: set this to '{}'. `create-order` stops pinning immediately and the
-- next hourly sync re-activates the routes.
insert into public.app_config (key, value)
values ('force_physical_operator', '{"us":"physic"}'::jsonb)
on conflict (key) do update set value = excluded.value;
