-- Disable the daily credit entirely (owner decision, 2026-08-01).
--
-- What it was: 1/2/3 credits on a streak ladder, granted by an explicit tap on
-- Home (claim_daily_credit) and ALSO silently on every cold launch from
-- register-push (claim_daily_credit_for), with a daily "claim your free credit"
-- push at 16:11 UTC. 93 grants / 101 credits lifetime, 92 of them in the last
-- 7 days.
--
-- Why a kill SWITCH and not a DROP:
--   * The SHIPPED app (1.6/1.7) calls both `daily_credit_status` and
--     `claim_daily_credit` over PostgREST — HomeScreen renders its claim card
--     on `status.available`. Dropping or revoking them breaks a live build.
--     Returning `available:false` makes the card disappear on its own, which is
--     exactly the behaviour we want and needs no client release.
--   * Verified every caller tolerates a refusal: AppState.refreshDailyCredit
--     uses `try?`; AppState.claimDailyCredit branches on `r.granted` and does
--     nothing when false; register-push branches on `.granted` and logs only.
--     `granted`/`available` are the sole non-optional fields in the Swift
--     models, so the payloads below still decode.
--   * Reverting is one UPDATE (see the bottom of this file).
--
-- Side effect worth recording: this closes the farming vector in the audit —
-- daily_bonus was a credit grant with no tombstone outside the auth.users
-- cascade (profiles.last_daily_credit_on cascades on delete), so delete +
-- re-signin re-granted it indefinitely. A disabled grant cannot be farmed, so
-- the tombstone is no longer needed unless this is ever re-enabled. If you DO
-- re-enable it, add the tombstone first, keyed on signup_grants.email_hash.

insert into public.app_config (key, value)
values ('daily_credit_enabled', jsonb_build_object('enabled', false))
on conflict (key) do update set value = excluded.value;

-- Fails CLOSED: a missing/garbled key reads as disabled. Correct direction for
-- a feature being switched off — losing the row must not silently resume paying.
create or replace function public.daily_credit_enabled()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select (value->>'enabled')::boolean
                     from public.app_config where key = 'daily_credit_enabled'), false);
$$;

revoke execute on function public.daily_credit_enabled() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The four grant/offer paths. Each gets ONE guard block at the top; every other
-- clause is byte-identical to the definition dumped from pg_get_functiondef
-- immediately before this migration was written.
-- ---------------------------------------------------------------------------

-- 1. What the app asks on launch to decide whether to render the claim card.
create or replace function public.daily_credit_status()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user   uuid := auth.uid();
  v_last   date;
  v_streak integer;
  v_next   integer;
  v_today  date := (now() at time zone 'utc')::date;
begin
  if not public.daily_credit_enabled() then
    return jsonb_build_object('available', false, 'reason', 'disabled');
  end if;

  if v_user is null then
    return jsonb_build_object('available', false, 'reason', 'unauthenticated');
  end if;

  select last_daily_credit_on, daily_streak
    into v_last, v_streak
    from public.profiles where user_id = v_user;

  if not found then
    return jsonb_build_object('available', false, 'reason', 'no_profile');
  end if;

  -- Same streak arithmetic the claim will use, so the offered amount and the
  -- granted amount cannot disagree.
  v_next := case when v_last = v_today - 1 then coalesce(v_streak, 0) + 1 else 1 end;

  if v_last = v_today then
    return jsonb_build_object(
      'available', false, 'reason', 'already_claimed',
      'streak', coalesce(v_streak, 0),
      'next_credits', public.daily_credit_amount(coalesce(v_streak, 0) + 1));
  end if;

  return jsonb_build_object(
    'available', true,
    'credits', public.daily_credit_amount(v_next),
    'streak',  coalesce(v_streak, 0),
    'next_streak', v_next);
end;
$function$;

-- 2. The explicit tap.
create or replace function public.claim_daily_credit()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user    uuid := auth.uid();
  v_last    date;
  v_streak  integer;
  v_amount  integer;
  v_balance integer;
  v_today   date := (now() at time zone 'utc')::date;
begin
  if not public.daily_credit_enabled() then
    return jsonb_build_object('granted', false, 'reason', 'disabled');
  end if;

  if v_user is null then
    return jsonb_build_object('granted', false, 'reason', 'unauthenticated');
  end if;

  -- Serialise per user: a double-tap, or launch + foreground firing together,
  -- must not pay twice.
  perform pg_advisory_xact_lock(hashtext(v_user::text));

  select last_daily_credit_on, daily_streak
    into v_last, v_streak
    from public.profiles
   where user_id = v_user
     for update;

  if not found then
    return jsonb_build_object('granted', false, 'reason', 'no_profile');
  end if;

  if v_last = v_today then
    select balance into v_balance from public.wallets where user_id = v_user;
    return jsonb_build_object(
      'granted', false, 'reason', 'already_claimed',
      'streak',  coalesce(v_streak, 0),
      'balance', coalesce(v_balance, 0),
      -- What tomorrow is worth, so the UI can say "come back for +N".
      'next_credits', public.daily_credit_amount(coalesce(v_streak, 0) + 1));
  end if;

  -- Consecutive only if yesterday; any gap restarts the streak at 1.
  v_streak := case when v_last = v_today - 1 then coalesce(v_streak, 0) + 1 else 1 end;
  v_amount := public.daily_credit_amount(v_streak);

  update public.profiles
     set last_daily_credit_on = v_today,
         daily_streak         = v_streak,
         daily_credits_total  = coalesce(daily_credits_total, 0) + v_amount
   where user_id = v_user;

  perform public.wallet_credit(v_user, v_amount, 'daily_bonus', null, null);
  select balance into v_balance from public.wallets where user_id = v_user;

  return jsonb_build_object(
    'granted', true,
    'credits', v_amount,
    'streak',  v_streak,
    'balance', coalesce(v_balance, 0),
    'next_credits', public.daily_credit_amount(v_streak + 1));
end;
$function$;

-- 3. The SILENT grant on every cold launch, from register-push. This is the one
--    that actually paid out 92 of the last 93 grants.
create or replace function public.claim_daily_credit_for(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_last    date;
  v_streak  integer;
  v_amount  integer;
  v_balance integer;
  v_today   date := (now() at time zone 'utc')::date;
begin
  if not public.daily_credit_enabled() then
    return jsonb_build_object('granted', false, 'reason', 'disabled');
  end if;

  if p_user is null then
    return jsonb_build_object('granted', false, 'reason', 'no_user');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select last_daily_credit_on, daily_streak
    into v_last, v_streak
    from public.profiles
   where user_id = p_user
     for update;

  if not found then
    return jsonb_build_object('granted', false, 'reason', 'no_profile');
  end if;

  if v_last = v_today then
    return jsonb_build_object('granted', false, 'reason', 'already_claimed');
  end if;

  v_streak := case when v_last = v_today - 1 then coalesce(v_streak, 0) + 1 else 1 end;
  v_amount := public.daily_credit_amount(v_streak);

  update public.profiles
     set last_daily_credit_on = v_today,
         daily_streak         = v_streak,
         daily_credits_total  = coalesce(daily_credits_total, 0) + v_amount
   where user_id = p_user;

  perform public.wallet_credit(p_user, v_amount, 'daily_bonus', null, null);
  select balance into v_balance from public.wallets where user_id = p_user;

  return jsonb_build_object(
    'granted', true, 'credits', v_amount, 'streak', v_streak,
    'balance', coalesce(v_balance, 0),
    'next_credits', public.daily_credit_amount(v_streak + 1));
end;
$function$;

-- 4. Who the daily push goes to. Belt and braces: the cron is unscheduled
--    below, but if anything ever calls this function directly it must not
--    advertise a credit that can no longer be granted.
create or replace function public.daily_credit_candidates(p_limit integer default 500)
returns table(user_id uuid, token text, environment text, streak integer, credits integer)
language sql
security definer
set search_path to 'public'
as $function$
  select p.user_id, d.token, d.environment,
         coalesce(p.daily_streak, 0) as streak,
         public.daily_credit_amount(
           case when p.last_daily_credit_on = (now() at time zone 'utc')::date - 1
                then coalesce(p.daily_streak, 0) + 1
                else 1
           end) as credits
    from public.profiles p
    join lateral (
      select pd.token, pd.environment
        from public.push_devices pd
       where pd.user_id = p.user_id
       order by pd.updated_at desc
       limit 1
    ) d on true
   where public.daily_credit_enabled()
     and p.last_daily_credit_on is distinct from (now() at time zone 'utc')::date
   order by coalesce(p.daily_streak, 0) desc
   limit p_limit;
$function$;

revoke execute on function public.daily_credit_status()          from public, anon;
revoke execute on function public.claim_daily_credit_for(uuid)   from public, anon, authenticated;
revoke execute on function public.daily_credit_candidates(int)   from public, anon, authenticated;
-- daily_credit_status() and claim_daily_credit() keep their `authenticated`
-- grant ON PURPOSE: the shipped app calls both directly over /rest/v1/rpc.
-- They are now no-ops, so the grant carries no privilege.

-- Stop the 16:11 UTC "claim your free credit" push. unschedule() raises if the
-- job is absent, so guard it — this migration must be re-runnable.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'relay-daily-credit') then
    perform cron.unschedule('relay-daily-credit');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- TO RE-ENABLE (read this first): add a tombstone for the grant BEFORE
-- flipping the flag, or it is farmable through account deletion again.
--
--   update public.app_config
--      set value = jsonb_build_object('enabled', true)
--    where key = 'daily_credit_enabled';
--
--   select cron.schedule('relay-daily-credit', '11 16 * * *', $c$
--     select net.http_post(
--       url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/daily-credit',
--       headers := jsonb_build_object('Content-Type','application/json',
--                                     'x-cron-secret', private_cron_secret()),
--       body := '{}'::jsonb, timeout_milliseconds := 120000);
--   $c$);
-- ---------------------------------------------------------------------------
