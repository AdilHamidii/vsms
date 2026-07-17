-- Hide services that can never deliver from the catalog entirely (not just show
-- "Unavailable" on every country). Binance/Venmo/Mercari have placeholder
-- smspva_code = 'UNMAPPED_*' (set by 20260712000000_fix_wrong_smspva_codes.sql)
-- and no virtualsms_code, so every one of their ~69 country routes is hidden —
-- yet they still listed in the picker as guaranteed dead ends.
--
-- Data-driven `visible` flag: the catalog fetch filters visible=true, so any
-- service can be pulled or restored from SQL without a client release.
--
-- Hide every service whose SMSPVA code is an UNMAPPED placeholder. Some of these
-- (binance 'bn', venmo 'vm') also carry a virtualsms_code and look bookable via
-- virtualsms — but virtualsms /customer/purchase is currently returning 503 on
-- every buy (validated 2026-07-16), so those routes charge-then-fail too. Until
-- either a real SMSPVA code is mapped OR virtualsms purchase is restored, they
-- are dead ends. Restore with: update services set visible=true where id in (...).

alter table public.services
  add column if not exists visible boolean not null default true;

update public.services
set visible = false
where coalesce(smspva_code, '') like 'UNMAPPED%';
