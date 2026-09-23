-- Server-controlled support destination, flippable from Telegram
-- (`/supportlink <url>`).
--
-- WHY THIS EXISTS. WhatsApp Business banned the support account +14375243093
-- on 2026-09-23. Every shipped build through 2.17 hardcodes a `wa.me` link to
-- that number in `LegalLinks.swift`, so every Support button in every
-- installed copy dead-ended at once, and moving it needed an App Store review
-- cycle. From the build that reads this key, the destination is a config value:
-- the next ban is one bot command, not a release.
--
-- VALUE: a jsonb STRING holding an https URL whose host is `t.me` or `wa.me`
-- (the same shape as `launch_tab`). The client appends its own prefilled
-- draft as `?text=`, so store the bare link. Anything else — another host,
-- http, a malformed string, a non-string — is treated by the client as absent
-- and it falls back to its compiled default (https://t.me/vSMSAPP).
--
-- CLIENT BEHAVIOUR, and it is not derivable from this file:
--   * Unlike `launch_tab`, a fetched value is used IMMEDIATELY in the same
--     session (there is no layout to protect). It is also persisted, so a
--     launch whose status fetch fails still uses the last value seen.
--   * An absent row clears the stored copy, so deleting the row returns every
--     app to its compiled default.
--   * Builds <= 2.17 never read this key and keep opening WhatsApp.

insert into public.app_config (key, value)
values ('support_url', '"https://t.me/vSMSAPP"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- 🔴 The whitelist is the ONLY safe way to publish a key to clients. NEVER
-- replace this with `using (true)`: the same table holds every provider
-- balance, the watchdog verdict, every sync cursor and the Instagram token,
-- and this policy is what keeps them off the wire. Every pre-existing key is
-- repeated verbatim — this is a REPLACE, so an omission silently un-publishes
-- a live feature.
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
                          'launch_tab',
                          'support_url']));
