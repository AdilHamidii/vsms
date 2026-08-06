-- Repair the routes `sync-5sim` seized from providers that actually own them.
--
-- THE BUG (fixed in the same commit, sync-5sim/index.ts): the mapping guard
-- tested only the COUNTRY mapping. `chosen` is keyed by (service, country) and
-- populated only from services carrying a `fivesim_product`, so a route whose
-- SERVICE was unmapped could never receive a pick — it fell through to the
-- write path and was stamped `provider='5sim'`, `status='hidden'`,
-- `premium_credits=null`, and counted as a stockout.
--
-- WHY IT NEEDED A REPAIR AND COULD NOT HEAL ITSELF: `sync-herosms` reads
-- `.eq("provider","herosms")` and `sync-prices` skips every row it does not
-- own, so once a row said `5sim` the only sync that would ever look at it again
-- was the one that cannot price it — which re-hid it every hour, forever.
--
-- Measured before this ran: 6,900 routes across 115 services, all `hidden`,
-- none `active`; 14 services had been emptied to zero active routes and
-- dropped out of the catalog entirely, 101 more were stripped to their nine
-- non-5sim countries. All 6,900 carried a non-null `retail_credits`, i.e. they
-- were priced, sellable inventory before the seizure.

-- Ownership is restored from PER-ROUTE evidence, not per-service guesswork.
-- `herosms_cost_cents` is written only by `sync-herosms`, so a non-null value
-- is proof HeroSMS both served and priced that exact route. Everything else
-- goes to SMSPVA, which is safe by construction: `services.smspva_code` is NOT
-- NULL and was verified non-empty for all 115 affected services.
update public.routes r
   set provider = case
                    when r.herosms_cost_cents is not null then 'herosms'
                    else 'smspva'
                  end,
       -- Deliberately `hidden`, never `active`. The owning sync recomputes
       -- status from live stock and price on its next run (sync-herosms at :37,
       -- sync-prices at :17); re-activating here would put rows back on the
       -- shelf at a price nobody has re-confirmed, which is how you sell
       -- something you cannot fulfil.
       status = 'hidden',
       -- The 5sim columns are now lies about a provider that does not own the
       -- row. `pool_rate_pct` in particular is RENDERED in CountrySheet, so
       -- leaving it would show one provider's published delivery rate beside
       -- another provider's number the moment the row goes active again.
       pool_operator = null,
       pool_rate_pct = null,
       pool_rate_window = null,
       pool_rate_checked_at = null,
       fivesim_cost_cents = null,
       fivesim_smoothed_cost_cents = null,
       fivesim_stock = null,
       fivesim_checked_at = null
  from public.services s
 where s.id = r.service_id
   and r.provider = '5sim'
   and s.fivesim_product is null;

-- Assert the seizure signature is gone. If sync-5sim is redeployed with the
-- guard fix, this must stay at zero forever; a nonzero count here means the
-- guard regressed.
do $$
declare v_left int;
begin
  select count(*) into v_left
    from public.routes r
    join public.services s on s.id = r.service_id
   where r.provider = '5sim' and s.fivesim_product is null;
  if v_left <> 0 then
    raise exception 'repair incomplete: % routes still owned by 5sim with no fivesim_product', v_left;
  end if;
end $$;
