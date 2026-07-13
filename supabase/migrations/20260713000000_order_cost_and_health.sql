-- Per-order wholesale cost (retail is cost_credits) for real margin
-- observability, plus a virtualsms health/balance row the cron can update.
alter table public.orders add column if not exists actual_cost_cents int;

insert into public.app_config(key, value) values
  ('virtualsms_health', '{"balance_usd": null, "low": false, "checked_at": null}'::jsonb)
on conflict (key) do nothing;
