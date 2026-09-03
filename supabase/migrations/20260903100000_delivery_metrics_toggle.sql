-- Owner kill switch for the user-facing delivery figure (2026-09-03).
--
-- The ONLY delivery number a user ever sees is the vendor's network rate
-- (`routes.pool_rate_pct`, rendered as High/Medium/Low). It is a third
-- party's aggregate that reads ~2× our realised delivery, and the owner
-- wants to be able to hide it from the phone, from Telegram, with no
-- release. `/metrics off` sets this key true; the client (2.8+) reads it in
-- the same `app_config` fetch as `esim_paused` and blanks every render
-- site. Steering and sorting are DELIBERATELY untouched — the rate still
-- decides where the app points a user; it just says nothing on screen.
--
-- Whitelist widened by ONE named key, never to `using (true)` — the same
-- table holds provider balances, the watchdog verdict and every sync cursor.
-- `anon` has a table SELECT grant but no policy, so it still reads nothing.

insert into public.app_config (key, value)
values ('delivery_metrics_hidden', 'false'::jsonb)
on conflict (key) do nothing;

drop policy if exists app_config_read on public.app_config;

create policy app_config_read on public.app_config
  for select to authenticated
  using (key = any (array[
    'maintenance',
    'announcement',
    'esim_paused',
    'lines_paused',
    'line_swap_credits',
    'delivery_metrics_hidden'
  ]));
