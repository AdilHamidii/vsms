-- sync-smspool prices SMS ROUTES only (eSIM plans are sync-esim-plans, a
-- separate job). With SMS on SMSPVA it would otherwise re-activate 7,054
-- SMSPool routes every hour and fight the catalog. Unscheduled, not dropped —
-- the function and all its data survive for a future comparison.
select cron.unschedule('relay-sync-smspool');

-- sync-prices owns SMSPVA pricing and was unscheduled during the SMSPool-only
-- period, so SMSPVA prices are days stale. Bring it back, hourly rather than
-- daily so displayed prices track cost the way they did for SMSPool.
select cron.schedule(
    'relay-sync-prices',
    '17 * * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $cmd$
);
