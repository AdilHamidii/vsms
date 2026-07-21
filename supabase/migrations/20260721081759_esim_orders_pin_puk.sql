-- SMSPool returns `pin` and `puk` on every /esim/profile response and we
-- discarded both. iOS prompts for the SIM PIN when the line activates, so a
-- user without it simply cannot bring the eSIM up — the data plan is paid for
-- and unusable, and looks to them like "the internet doesn't work".
-- Live example: the Polish 500MB eSIM had pin 9322 / puk 86642369 and reported
-- 0 of 500 MB consumed.
alter table public.esim_orders
  add column if not exists sim_pin text,
  add column if not exists sim_puk text;

comment on column public.esim_orders.sim_pin is
  'SIM PIN from /esim/profile — iOS asks for this at activation.';
