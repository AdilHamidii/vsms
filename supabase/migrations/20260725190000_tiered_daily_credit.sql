-- Tiered daily credit: the longer the streak, the bigger the grant.
--
--   day 1-2   -> +1 credit
--   day 3-9   -> +2 credits
--   day 10+   -> +3 credits
--
-- The point is escalation: a flat +1 gives a returning user nothing new to
-- earn, whereas a tier they can lose is a reason to come back tomorrow
-- specifically. Streak resets to 1 on any missed UTC day, so the day-10 tier
-- costs a real 10-day run.
--
-- Economics at the current 6x divisor (median active route = 12 credits):
--   a perfect 12-day run yields 1+1+2*7+3*3 = 25 credits — i.e. two median
--   numbers in ~12 days, versus ~12 days for ONE under the old flat +1.
--   Still not an activation fix on its own: a brand-new user holds 1 credit,
--   which buys 24 of 16,303 routes. The levers for that remain the signup
--   grant and CREDIT_DIVISOR.

-- Single source of truth for the ladder, so the granting function and the push
-- copy can never disagree about what a user is owed.
create or replace function public.daily_credit_amount(p_streak integer)
returns integer
language sql
immutable
as $function$
  select case
           when coalesce(p_streak, 1) <= 2 then 1
           when coalesce(p_streak, 1) <= 9 then 2
           else 3
         end;
$function$;

comment on function public.daily_credit_amount(integer) is
  'Daily credit ladder: streak 1-2 -> 1, 3-9 -> 2, 10+ -> 3. Used by both '
  'claim_daily_credit() and daily_credit_candidates() so the grant and the '
  'notification copy cannot drift apart.';

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

revoke execute on function public.claim_daily_credit() from public, anon;
grant  execute on function public.claim_daily_credit() to authenticated;

-- Read-only status, so the app can OFFER the claim without granting it.
--
-- The credit is claimed by an explicit tap, not silently on launch: a grant the
-- user never chose is invisible, and the daily habit we want is "open the app
-- and collect", not "the number quietly changed". This must therefore be a
-- separate, side-effect-free call — never infer availability by attempting a
-- claim.
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

revoke execute on function public.daily_credit_status() from public, anon;
grant  execute on function public.daily_credit_status() to authenticated;

-- Candidates now carry what the user would actually receive, computed the same
-- way the claim will compute it — including the streak RESET when their last
-- claim was not yesterday, so the push never promises a tier they've lost.
drop function if exists public.daily_credit_candidates(integer);

create function public.daily_credit_candidates(p_limit integer default 500)
returns table (user_id uuid, token text, environment text, streak integer, credits integer)
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
   where p.last_daily_credit_on is distinct from (now() at time zone 'utc')::date
   order by coalesce(p.daily_streak, 0) desc
   limit p_limit;
$function$;

revoke execute on function public.daily_credit_candidates(integer)
  from public, anon, authenticated;
