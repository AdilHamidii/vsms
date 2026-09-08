-- Schedule the rescue sweep: a paying subscriber with no number gets one
-- within ~15 minutes, with no notification and no user interaction.
--
-- Offset to :08/:23/:38/:53 so it does not collide with `reclaim-lapsed-lines`
-- (*/15, on the quarter) or `relay-release-lines` (:03/:18/:33/:48). It runs
-- AFTER the reclaim sweep on purpose: reclaim is what moves a lapsed line out
-- of the live status set, and doing it first means this one judges occupancy
-- from settled state rather than racing it.
--
-- 🔴 An HTTP hop, not pure SQL, because it buys numbers at Telnyx — the
-- opposite trade from `reclaim_lapsed_lines`, whose CLAIM must survive the
-- edge layer being down. A rescue we could not make is retried in 15 minutes;
-- a claim we could not make would leak rent forever.
select cron.schedule(
  'relay-rescue-unprovisioned-lines',
  '8,23,38,53 * * * *',
  $$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/rescue-unprovisioned-lines',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000);
  $$
);
