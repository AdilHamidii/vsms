-- Per-route REAL-SIM carrier, and the correction that made it necessary.
--
-- `physic` is ONE pool, not "all real SIMs". Probed 2026-07-31, badoo/us:
--   physic 0 · at_t 131 · tmobile 4,179 · verizon 14,224 · textnow 458,985
-- so pinning `physic` alone hid 71 US routes that had ample real-carrier stock,
-- while `textnow` alone (a VoIP texting service) accounts for ~96% of the pool.
--
-- The config therefore becomes country -> ORDERED LIST of acceptable real
-- operators, and `sync-herosms` records which one actually has stock for each
-- (service, country) so `create-order` can pin it. Storing the winner per route
-- also gives the eventual "VoIP or real SIM?" choice something to price and
-- offer, instead of guessing at order time.
alter table public.routes
  add column if not exists herosms_real_operator text,
  add column if not exists herosms_real_count    integer;

comment on column public.routes.herosms_real_operator is
  'HeroSMS operator carrying REAL SIMs for this route, chosen as the one with '
  'the most stock among app_config.force_physical_operator[country]. Null = no '
  'real-carrier stock, or the country is not configured.';

update public.app_config
set value = '{"us":["verizon","tmobile","at_t","physic","cricket_wireless","boost_mobile","mint_mobile","us_mobile","ultra_mobile","hello_mobile","h2o_wireless","lycamobile","simple","virgin"]}'::jsonb
where key = 'force_physical_operator';
