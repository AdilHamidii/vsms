-- Sell US and Puerto Rico line numbers again (owner, 2026-09-17), reversing
-- `20260917090000` the same day.
--
-- The 10DLC finding stands: outbound SMS from an unregistered US long code
-- fails `40010` at the carrier, while Canadian numbers deliver. The owner's
-- decision is to keep selling US/PR and TELL the buyer instead — the client
-- warns that texting other phones is unreliable from a US number and works
-- from a Canadian one. Everything else on a US number (inbound SMS, calls in
-- both directions) is unaffected.
--
-- 🔴 The warning is the ONLY thing standing between a US buyer and a refund
-- request. If it is ever removed from the client, block these rows again:
--   update public.line_country_catalog set sell_override = 'force_block'
--    where country_code in ('US','PR');
--   select public.refresh_line_country_sellability();
update public.line_country_catalog
   set sell_override = null
 where country_code in ('US', 'PR');

select public.refresh_line_country_sellability();
