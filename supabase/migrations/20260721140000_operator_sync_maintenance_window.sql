-- Nightly maintenance window for the operator sync, managed by pg_cron.
--
-- The single-invocation daily pass from 20260721130000 is IMPOSSIBLE on this
-- edge runtime: workers are killed at ~150s wall clock. Verified live twice —
-- a synchronous 5-minute request died with IDLE_TIMEOUT at 150s, and an
-- EdgeRuntime.waitUntil background task died at the same mark (cursor stopped
-- ~33 countries in, exactly 150s of 4.5s-paced calls; the maintenance flag's
-- `until` bound cleaned up after it, as designed).
--
-- New shape — three independently idempotent cron jobs:
--   04:29        maintenance UP via plain SQL (until-bounded to 04:46, so a
--                broken window can never wedge the app past that)
--   04:30–:40/2  sync-smspva-operators, six slots x 12 countries ≈ covers the
--                whole ~69-country catalog by ~04:41
--   04:43        maintenance DOWN via plain SQL
-- A failed slot leaves its countries for tomorrow (the cursor just doesn't
-- advance past them); pins are stable day to day, so that is harmless.

select cron.unschedule('relay-sync-smspva-operators');

select cron.schedule(
    'relay-smspva-operators-maint-up',
    '29 4 * * *',
    $cmd$
    update public.app_config
    set value = jsonb_build_object(
        'active', true,
        'until', to_char((now() + interval '17 minutes') at time zone 'utc',
                         'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'message', 'Nightly catalog refresh — back in a few minutes.'
    )
    where key = 'maintenance';
    $cmd$
);

select cron.schedule(
    'relay-sync-smspva-operators',
    '30,32,34,36,38,40 4 * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-smspva-operators',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $cmd$
);

select cron.schedule(
    'relay-smspva-operators-maint-down',
    '43 4 * * *',
    $cmd$
    update public.app_config
    set value = '{"active": false}'::jsonb
    where key = 'maintenance';
    $cmd$
);
