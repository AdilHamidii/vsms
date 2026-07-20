-- Fail fast. Every code we have EVER delivered arrived in 26-115s; the single
-- slowest was 337s (5.6 min). But orders were held 20 minutes before expiry,
-- so a user whose SMS was never coming sat through ~18 minutes of dead hope
-- before their refund — then had to start over. Live case 2026-07-20: a
-- customer who had just bought 30 credits burned 2.5 hours this way.
--
-- 8 minutes keeps a comfortable margin over the slowest real delivery while
-- cutting the failure loop by 60%, so users recover and retry sooner.
-- poll-active-orders (every 1 min) does the expiry + auto-refund.
alter table public.orders alter column expires_at set default now() + interval '8 minutes';
