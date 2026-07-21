-- SMSPool returns a `network` field on every /esim/plans row describing which
-- countries and operators a plan actually covers. sync-esim-plans read the
-- field into a typed interface and then threw it away, hardcoding region=null:
-- 0 of 1081 active plans carry any coverage data.
--
-- So a buyer choosing "the cheapest Poland eSIM" is never told it is
-- Poland-only on Play/Orange. They find out when their data does not work
-- abroad — which is a refund and a one-star review, not a support ticket.
alter table public.esim_plans
  add column if not exists network text;

comment on column public.esim_plans.network is
  'Raw coverage payload from SMSPool /esim/plans. region holds the derived human label.';
