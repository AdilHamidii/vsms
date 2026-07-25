-- Daily credit — the retention loop.
--
-- 1 credit on signup (unchanged) plus 1 credit for each distinct UTC day the
-- user opens the app, with a daily push reminding them to collect it.
--
-- WHY UTC and not device-local: the claim must be decidable server-side from
-- the row alone. A device-local day lets a traveller — or anyone willing to
-- change their clock — claim twice.
--
-- SIZING CAVEAT (read before tuning): the median active route is 12 credits at
-- the current 6x divisor, so +1/day accrues a median number in ~12 days. This
-- is a genuine reason to return daily, but it does NOT by itself make the app
-- usable for a new user — 1 credit buys 24 of 16,303 routes. If activation
-- stays flat, the lever is the grant size or CREDIT_DIVISOR, not the cadence.
--
-- Separate migration from 20260725170000 because `alter type ... add value`
-- cannot be USED in the transaction that adds it.

alter table public.profiles
  add column if not exists last_daily_credit_on date,
  add column if not exists daily_streak integer not null default 0,
  add column if not exists daily_credits_total integer not null default 0;

comment on column public.profiles.last_daily_credit_on is
  'UTC date of the most recently claimed daily credit. One claim per UTC day.';
comment on column public.profiles.daily_streak is
  'Consecutive UTC days claimed. Resets to 1 when a day is missed.';

-- Claimed by the signed-in client on launch/foreground. auth.uid() scopes it,
-- so it takes no user argument — a client must never be able to name someone
-- else's account here.
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
  v_balance integer;
  v_today   date := (now() at time zone 'utc')::date;
begin
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
      'balance', coalesce(v_balance, 0));
  end if;

  -- Consecutive only if yesterday; any gap restarts the streak at 1.
  v_streak := case when v_last = v_today - 1 then coalesce(v_streak, 0) + 1 else 1 end;

  update public.profiles
     set last_daily_credit_on = v_today,
         daily_streak         = v_streak,
         daily_credits_total  = coalesce(daily_credits_total, 0) + 1
   where user_id = v_user;

  perform public.wallet_credit(v_user, 1, 'daily_bonus', null, null);
  select balance into v_balance from public.wallets where user_id = v_user;

  return jsonb_build_object(
    'granted', true, 'credits', 1,
    'streak',  v_streak,
    'balance', coalesce(v_balance, 0));
end;
$function$;

revoke execute on function public.claim_daily_credit() from public, anon;
grant  execute on function public.claim_daily_credit() to authenticated;

-- Who to nudge: has a push token and hasn't claimed today. Ordered by streak so
-- the users with something to lose are reached first if the limit binds.
create or replace function public.daily_credit_candidates(p_limit integer default 500)
returns table (user_id uuid, token text, environment text, streak integer)
language sql
security definer
set search_path to 'public'
as $function$
  select p.user_id, d.token, d.environment, coalesce(p.daily_streak, 0)
    from public.profiles p
    join lateral (
      select pd.token, pd.environment
        from public.push_devices pd
       where pd.user_id = p.user_id
       order by pd.updated_at desc
       limit 1
    ) d on true
   where p.last_daily_credit_on is distinct from (now() at time zone 'utc')::date
   order by coalesce(p.daily_streak, 0) desc
   limit p_limit;
$function$;

revoke execute on function public.daily_credit_candidates(integer)
  from public, anon, authenticated;
