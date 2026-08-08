-- `orders.from_default` — was the SERVICE the app's own pre-selection rather
-- than something the user chose?
--
-- Why this is a stored column and not a heuristic: measured 2026-08-07, six
-- deliveroo/us orders from FOUR brand-new users, every one on the app's default
-- pair at exactly the grant size, all issued a number, NONE delivering a code —
-- while a deliberate order on the same route delivered in 86 seconds. Four of
-- the six were never even cancelled, just left to expire. They were numbers
-- nobody entered anywhere, because nobody had come for that service.
--
-- Scoring those as delivery failures measures our own steering. It already
-- dragged `delivery-degraded` to "10/38 in 7d" against a ~73% baseline.
--
-- ⚠️ Deliberately NOT inferred server-side. The obvious proxy — first order,
-- soon after signup, on whichever route bestStarter resolves to — is a guess,
-- and this repo has already shipped TWO watchdog checks that silently measured
-- the wrong thing (impatient cancels counted as delivery failures; a 6h/>=8
-- gate that was mathematically unreachable). A third heuristic in the alerting
-- path is not worth it when the client can simply state the fact.
--
-- NULL means "not recorded" — every order placed before 2.1 — which is NOT the
-- same as false. Consumers must treat only `from_default = true` as excluded,
-- so old rows keep counting exactly as they do today.
alter table public.orders
  add column if not exists from_default boolean;

comment on column public.orders.from_default is
  'True when the service was the app''s pre-selection, not a user choice. '
  'NULL = not recorded (pre-2.1). Exclude only TRUE from delivery evidence.';

-- Partial index: the only query that reads this wants the excluded set, which
-- is a small minority of rows.
create index if not exists orders_from_default_idx
  on public.orders (created_at)
  where from_default;
