-- Owner-controlled launch tab, flippable from Telegram (`/tabs`).
--
-- WHY THIS EXISTS. On 2026-09-09 the rented-line tab became both the first tab
-- and the landing tab. That has been done once before — 2.0, Aug 15-19 — and it
-- cost `create-order` ~30 calls/day -> 1 with zero first-day orders from 45
-- signups, so it was reverted on 2026-08-08. The premise that makes it right
-- this time (acquisition points at second-number intent) can stop being true
-- without warning: both vSMS ASA campaigns were gone from the account when this
-- shipped. A decision that reversible should not need an App Store review cycle
-- to reverse, which is exactly the argument `/lines` and `/esim` already won.
--
-- VALUES: 'line' (the rented number leads) or 'temp' (temp SMS + temp e-mail
-- leads). A STRING, not a boolean: "is the line first?" cannot express a third
-- tab ever leading, and a reader of this row should learn WHICH tab wins rather
-- than having to know which way the flag points. Anything else is treated by
-- the client as absent and it falls back to the order it was compiled with.
--
-- CLIENT BEHAVIOUR, and it is not derivable from this file:
--   * The value is read at LAUNCH from UserDefaults, not from the network, so
--     the tab bar cannot reorder itself under the user's thumb mid-session.
--     `refreshAppStatus` deliberately runs AFTER the reveal in `coldStart`
--     ("a banner is additive"), so the live value is not available at the
--     moment the bar first draws.
--   * Consequence: a flip lands on the user's SECOND cold launch. The first
--     one fetches and stores it. Say so in any copy about this switch.
--   * Client-side, so it only affects builds that ship with the reader. 2.11
--     and older keep whatever order they were built with, whatever this says.

insert into public.app_config (key, value)
values ('launch_tab', '"line"'::jsonb)
on conflict (key) do nothing;

-- 🔴 The whitelist is the ONLY safe way to publish a key to clients. NEVER
-- replace this with `using (true)`: the same table holds every provider
-- balance, the watchdog verdict and every sync cursor, and this policy is what
-- keeps them off the wire. Every pre-existing key is repeated verbatim — this
-- is a REPLACE, so an omission silently un-publishes a live feature.
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config
  for select to authenticated
  using (key = any (array['maintenance',
                          'announcement',
                          'esim_paused',
                          'lines_paused',
                          'line_swap_credits',
                          'delivery_metrics_hidden',
                          'email_sub_daily_cap',
                          'launch_tab']));
