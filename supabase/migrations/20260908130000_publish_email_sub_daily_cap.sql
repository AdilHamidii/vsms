-- Publish `email_sub_daily_cap` to authenticated clients.
--
-- WHY: the mail paywall quotes "Up to N addresses a day" and N mirrored a
-- CLIENT constant (`MailProduct.dailyAddressCap = 25`) against a server value
-- the owner changes with one UPDATE and no release. That is the same class as
-- the "+3 credits" onboarding card and `inviteJoinerCredits`, both of which
-- shipped wrong — and this one is quoted on a PAYWALL, so a divergence is a
-- paid promise we would not be keeping.
--
-- The client now reads it live and DROPS the figure when it is absent, so a
-- failed read degrades the sentence rather than inventing a number.
--
-- 🔴 `app_config` is RLS-restricted to an explicit key WHITELIST and this is
-- the ONLY safe way to widen it — the same table holds provider balances, the
-- watchdog verdict, support-nag state and every sync cursor. NEVER replace
-- this policy with `using (true)`.
--
-- This is the SEVENTH published key. The others: maintenance, announcement,
-- esim_paused, lines_paused, line_swap_credits, delivery_metrics_hidden.

drop policy if exists app_config_read on public.app_config;

create policy app_config_read on public.app_config
  for select to authenticated
  using (key = any (array['maintenance',
                          'announcement',
                          'esim_paused',
                          'lines_paused',
                          'line_swap_credits',
                          'delivery_metrics_hidden',
                          'email_sub_daily_cap']));

-- The key must EXIST for the client to read one: `begin_email_order` defaults
-- to 25 when the row is missing, so the server would cap at 25 while the app
-- showed no figure at all. Seed it with the documented default, without
-- overwriting a value the owner has already chosen.
insert into public.app_config (key, value)
values ('email_sub_daily_cap', '25'::jsonb)
on conflict (key) do nothing;
