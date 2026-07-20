-- Pin SMSPool purchases to the pool we priced from. sync-smspool records the
-- best affordable pool (priciest ≤ $4 ceiling) per combo; create-order passes
-- it to /purchase/sms so we buy the quality tier the 3× sticker already pays
-- for, instead of letting SMSPool default to the cheapest (worst) pool.
alter table public.routes add column if not exists smspool_pool text;
