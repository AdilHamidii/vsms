-- 1) Signup bonus 3 -> 1 credit (owner decision 2026-07-21).
--    The onboarding now SELLS the free credit explicitly (a dedicated page:
--    "your first try is on us") instead of silently granting a bigger one.
--    History: 1 cr at launch, raised to 3 on 2026-07-16 to unblock
--    activation. Only affects users created after this runs.
--
--    This re-creates the CURRENT handle_new_user (the referral-aware version
--    from 20260717000200 — profiles get a referral_code), changing only the
--    granted amount. CREATE OR REPLACE preserves privileges; the revoke is
--    re-asserted anyway.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (user_id, display_name, referral_code)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
        public.gen_referral_code()
    );

    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, 1, now());

    insert into public.wallet_transactions (user_id, delta, reason)
    values (new.id, 1, 'signup_bonus');

    return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- 2) Operator discovery becomes a DAILY full pass behind the maintenance
--    screen (owner decision 2026-07-21), replacing the hourly 12-country
--    rotation. One run now covers every country (~69 x 4s ≈ 5 min, inside
--    the 400s edge-function ceiling); the function raises
--    app_config.maintenance with an `until` bound while it rewrites pins, so
--    the clear-then-set window is never user-visible, and a crashed run
--    can't wedge the app (the client ignores active flags past `until`).
--    04:30 UTC: overnight for the EU-heavy user base, clear of the :17
--    hourly sync-prices run.
select cron.unschedule('relay-sync-smspva-operators');
select cron.schedule(
    'relay-sync-smspva-operators',
    '30 4 * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-smspva-operators',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 400000
    );
    $cmd$
);
