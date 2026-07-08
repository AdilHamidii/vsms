-- Schedule sync-prices daily at 04:00 UTC. Reuses the cron_secret vault
-- entry and private_cron_secret() helper that were created alongside the
-- poll-active-orders schedule in 20260528160000_push_devices.sql.

select cron.schedule(
    'relay-sync-prices',
    '0 4 * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 60000
    );
    $cmd$
);
