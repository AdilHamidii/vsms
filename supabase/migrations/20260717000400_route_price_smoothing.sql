-- Price smoothing input for sync-prices. retail_credits currently reprices off a
-- single day's SMSPVA quote, so a hot route can flip affordable<->unavailable
-- day to day (e.g. leboncoin/RO 3->4cr overnight). Keep an exponentially-weighted
-- moving average of the wholesale cost and price off THAT instead of the latest
-- raw quote. last_cost_cents is retained for reference/observability.
alter table public.routes
  add column if not exists smoothed_cost_cents int;
