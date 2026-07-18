-- Daily SMSPool eSIM catalog sync at 02:00 UTC (before the SMS syncs).
select cron.schedule(
    'relay-sync-esim-plans',
    '0 2 * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-esim-plans',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $cmd$
);
