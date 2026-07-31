-- Give HeroSMS its own smoothed wholesale column, so sync-herosms can start
-- deriving retail_credits without inheriting SMSPVA's.
--
-- `herosms_cost_cents` stays what it has always been: the RAW observed quote.
-- sync-herosms deliberately had no smoothing because it derived no retail — the
-- margin gate reads that number and blurring it would only hide drift. Now that
-- it sets a price, it needs the same RATCHET the other two retail-setting syncs
-- have (`sync-prices`, `sync-esim-plans`): a cost RISE applies immediately and
-- only FALLS are smoothed.
--
-- That asymmetry is not a style choice. A plain symmetric EWMA averages a rise
-- against yesterday's cheaper price and therefore sets retail BELOW what we are
-- about to pay; that shipped once and put 4,384 routes under wholesale in a
-- single run. Keeping the raw and smoothed values in separate columns means the
-- margin gate can keep reading the real number while pricing reads the damped
-- one.
--
-- Nullable with no default and no backfill: the first sync-herosms run seeds it
-- from the current observation, exactly as sync-prices seeds
-- smoothed_cost_cents on a route's first sighting.
alter table public.routes
  add column if not exists herosms_smoothed_cost_cents integer;

comment on column public.routes.herosms_smoothed_cost_cents is
  'Ratcheted HeroSMS wholesale (cents): rises apply at once, falls are EWMA-smoothed. '
  'retail_credits for HeroSMS routes is derived from THIS, never from herosms_cost_cents '
  '(which stays raw for the order-time margin gate).';
