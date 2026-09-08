-- A delivered activation is held open for a SECOND SMS instead of being
-- finished immediately.
--
-- 5sim's FAQ: "If you finish an order, then there is no way to request and
-- receive SMS using the same number again." We were calling finish() on code
-- arrival — 25 seconds, in the support case that prompted this — which
-- destroyed the only mechanism that can deliver a re-sent code to the number
-- the user's account is actually registered on. `user/reuse/{product}/{number}`
-- is not a way back: refused after a cancel AND after a finish (paid probes
-- 2026-08-18 and 2026-09-08).
--
-- 🔴 NO NEW `order_status` VALUE, DELIBERATELY. The iOS OrderStatus enum
-- (Components/Pills.swift) is a plain String enum with no unknown case, so a
-- status it does not recognise throws on decode and takes the Orders tab down
-- for every shipped build. The order still flips to 'received'; the window
-- lives in a nullable column, the same shape `late_watch_until` already uses
-- for the late-code rescue.
--
-- No money moves here and none may: a second code is free within the original
-- activation, so there is no wallet call, no refund path and no new
-- wallet_reason anywhere in this feature.

alter table public.orders
  add column if not exists resend_watch_until timestamptz,
  add column if not exists otp_history jsonb;

comment on column public.orders.resend_watch_until is
  'While > now(), poll-active-orders keeps re-polling this delivered order for '
  'another SMS and has NOT yet called markSuccess. Null means either the pool '
  'cannot take a second SMS or the window closed and finish() has been made. '
  'Reset to now() + 5 min on every new code — 5sim''s clock restarts per '
  'message, so this is never a countdown from a fixed total.';

comment on column public.orders.otp_history is
  'Every code seen on this activation, oldest first: [{code, text, at}]. '
  '`otp` always holds the NEWEST. Shipped builds render `otp` alone, which is '
  'what lets a second code reach them with no client release.';

-- Partial: the sweep only ever wants open windows, and they are a handful of
-- rows against the whole order history.
create index if not exists orders_resend_watch_idx
  on public.orders (resend_watch_until)
  where resend_watch_until is not null;
