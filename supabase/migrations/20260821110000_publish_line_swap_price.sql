-- Publish the swap price to signed-in clients.
--
-- ── Why the client cannot just hardcode 5 ──────────────────────────────────
--
-- `line_swap_credits` is server config the owner can change with no release.
-- This repo has already shipped two client constants derived from a
-- server-changed amount and had both go wrong in front of users: the "+3
-- credits" onboarding card that survived the grant going to zero, and
-- `inviteJoinerCredits = 5`, a 150% overstatement the moment the signup grant
-- moved. A confirmation dialog that names a price MUST read that price from
-- the server.
--
-- ── Widened by ONE KEY, never to `using (true)` ────────────────────────────
--
-- `app_config` also holds provider balances, the watchdog verdict and every
-- sync cursor. `using (true)` would publish all of it to anyone holding the
-- publishable key. The whitelist is the only safe way to widen this policy,
-- and a price we charge users is the least sensitive thing in the table.
--
-- `anon` is unaffected: it has a table SELECT grant but no policy, so it still
-- reads nothing. The app is past AuthGate and reads as `authenticated`.

drop policy if exists app_config_read on public.app_config;

create policy app_config_read on public.app_config
  for select to authenticated
  using (key = any (array[
    'maintenance',
    'announcement',
    'esim_paused',
    'lines_paused',
    'line_swap_credits'
  ]));
