-- A small owner-controlled announcement banner, plus letting the app STATE that
-- eSIMs are paused rather than infer it from an empty catalog.
--
-- `app_config` holds provider balances, the watchdog verdict, blocked routes and
-- sync cursors. It is RLS-protected with a single deliberate hole:
--
--   app_config_read: SELECT to `authenticated` USING (key = 'maintenance')
--
-- That whitelist shape is the only safe way to widen this — never a blanket
-- `using (true)`, which would publish `herosms_health` / `smspva_health`
-- (balances) and `watchdog` to anyone holding the publishable key. Two keys are
-- added, both of which are things we are deliberately TELLING users:
--
--   announcement — owner-written text, set from Telegram with /announce
--   esim_paused  — the boolean set by set_esim_paused(); a fact about what is
--                  on sale, and already visible as "no plans" either way
--
-- `esim_paused` deliberately stays ONE key rather than being copied into a new
-- client-facing row: it is read by sync-esim-plans, run_watchdog and now the
-- app, and this codebase's own history says a duplicated constant drifts.

drop policy if exists app_config_read on public.app_config;

create policy app_config_read on public.app_config
  for select to authenticated
  using (key = any (array['maintenance', 'announcement', 'esim_paused']));

-- Shape:
--   {"active": bool, "text": string, "kind": "info"|"warn", "id": string}
--
-- `id` exists so a dismissal sticks to ONE announcement. Without it the client
-- can only remember "dismissed", and the next announcement the owner writes is
-- silently never shown to anyone who dismissed the previous one — a broadcast
-- channel that quietly stops broadcasting.
insert into public.app_config (key, value)
values ('announcement', '{"active": false, "text": "", "kind": "info", "id": ""}'::jsonb)
on conflict (key) do nothing;
