-- Daily SMSPool catalog sync at 03:00 UTC — an hour before the SMSPVA sync
-- (04:00) so SMSPVA's stale-guard sees SMSPool-owned routes already claimed.
-- Same private_cron_secret() + net.http_post relay pattern as the other jobs.
select cron.schedule(
    'relay-sync-smspool',
    '0 3 * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-smspool',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $cmd$
);
