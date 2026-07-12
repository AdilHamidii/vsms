-- Fix 3 wrong service -> SMSPVA opt-code mappings, found by verifying the whole
-- catalog against SMSPVA's authoritative /activation/servicesprices list
-- (262/268 were already correct; the popular services — whatsapp opt20,
-- google opt1, openai opt132, telegram opt29 — all verified correct, so their
-- zero-delivery is number quality, not a mapping bug).
--
-- These three codes actually belong to unrelated services:
--   opt190 = "SNKRDUNK"   (mapped as binance)
--   opt39  = "Verse"      (mapped as venmo)
--   opt197 = "MPSellers"  (mapped as mercari)
-- A wrong code still rents a number, but the expected code never arrives
-- (rent -> no SMS -> auto-refund -> churn) AND sells the user a number
-- provisioned for a different service. No orders have hit these yet, but they
-- are latent landmines — Binance especially is real demand.
--
-- SMSPVA's priced catalog has NO Binance/Venmo/Mercari entry (searches for each
-- returned nothing), so we cannot remap to a correct code here. Disable the
-- three — invalidate the code so sync-prices won't re-price them, and
-- deactivate their live routes — until a correct SMSPVA code is confirmed via
-- SMSPVA support / their full (incl. out-of-stock) service list. To re-enable
-- later, restore smspva_code to the verified value and let sync-prices reprice.
--
-- The other flagged rows are correct (matcher false positives), left unchanged:
--   opt7 = "MS Office 365" (ms365), opt84 = "POF.com" (pof),
--   opt268 = "Pokémon Center Online" (pokemon-center).

update public.routes
   set status = 'inactive'
 where service_id in ('binance', 'venmo', 'mercari');

update public.services
   set smspva_code = 'UNMAPPED_' || smspva_code
 where id in ('binance', 'venmo', 'mercari')
   and smspva_code not like 'UNMAPPED_%';
