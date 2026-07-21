-- SMS moves back to SMSPVA; SMSPool keeps the eSIM line only.
--
-- SMSPool served 43 SMS orders over 3 days and delivered 3. The decisive test
-- was leboncoin/NL — 8 of 13 on SMSPVA — going 0 of 1 on SMSPool with every
-- mechanism working correctly (number issued from the pinned pool at 7c
-- against a 1-credit charge, held 173s). Nothing was broken; the SMS just
-- never arrived.
--
-- SMSPool also bans financial/crypto/KYC/telecom/government verification in
-- its ToS 6.7, and has no mapping at all for ~134 services SMSPVA carries, so
-- keeping it on SMS costs catalog coverage as well as delivery.
--
-- eSIMs are NOT affected: esim_plans/esim_orders are separate tables served by
-- sync-esim-plans and create-esim-order, and SMSPool has delivered 9 of 9.

-- 1) Hand SMS back to SMSPVA. Only routes at or under the wholesale ceiling —
--    the rest stay hidden rather than being sold at a loss.
update public.routes
set status = 'active'
where provider = 'smspva'
  and retail_credits is not null
  and last_cost_cents is not null
  and last_cost_cents <= 400;

-- 2) SMSPool routes are SMS-only, so they come out of the catalog entirely.
--    Reversible: this is a status flip, nothing is deleted, and smspool_pool /
--    stock / observed rates are all preserved for a future comparison.
update public.routes set status = 'hidden' where provider = 'smspool';

-- 3) Services follow real coverage again (the same function sync-smspool
--    calls, so nothing drifts).
select public.sync_service_visibility();

-- 4) Blocked routes stay blocked regardless of provider — whatsapp|us et al
--    were deliberately killed for 0/4 delivery and must not come back just
--    because SMSPVA now owns them.
update public.routes r
set status = 'hidden'
from public.app_config c
where c.key = 'blocked_routes'
  and r.status = 'active'
  and (r.service_id || '|' || r.country_id) in (
        select jsonb_array_elements_text(c.value));
