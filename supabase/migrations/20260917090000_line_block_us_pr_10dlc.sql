-- Stop selling US and Puerto Rico line numbers; Canada only (owner, 2026-09-17).
--
-- US carriers refuse texts from US long codes that are not 10DLC-registered
-- (Telnyx 40010), and nothing in this product registers one. Over the 30 days
-- to 2026-09-17, 16 of 24 outbound texts failed, all from US numbers; Canadian
-- numbers delivered every send. New subscribers' first act is a test text, so
-- a US number sold today is a refund request. PR numbers are +1 US-carrier
-- long codes and fall under the same rule.
--
-- `force_block` is the catalog's only override and nothing in code writes it,
-- so `sync-line-countries` cannot re-open these rows. Existing US subscribers
-- keep their numbers; a same-country swap is deliberately not gated on
-- sellability. Reverse with `sell_override = null` + the refresh below.
update public.line_country_catalog
   set sell_override = 'force_block'
 where country_code in ('US', 'PR');

select public.refresh_line_country_sellability();
