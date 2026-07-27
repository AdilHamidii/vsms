-- Retention: repair winback targeting, add the missing reorder cohort, and let
-- the daily credit be granted by the service role.
--
-- Measured 2026-07-27 (dev account excluded throughout):
--   codes ever received   users   avg lifetime orders
--   0                        23                   2.1
--   1                         8                   4.9
--   2+                        5                  14.8
-- Receiving codes IS the retention mechanic — a 7x spread. And every one of the
-- 126 repeat-order gaps in the dataset falls inside 5 DAYS; there is not a
-- single repeat beyond that. So nudges must fire in days, not weeks.
--
-- Standing pool: 100 users hold >= 3 credits and have not ordered in 7 days,
-- 466 idle credits between them. Only 15 users ordered at all last week.

-- ── 1. Counters so a nudge can recur without becoming spam.
alter table public.profiles
  add column if not exists winback_sent_count integer not null default 0,
  add column if not exists reorder_nudge_sent_at timestamptz,
  add column if not exists reorder_nudge_count integer not null default 0;

-- Backfill: anyone already nudged has had exactly one.
update public.profiles
set winback_sent_count = 1
where winback_sent_at is not null and winback_sent_count = 0;

-- ── 2. winback_candidates — four regressions repaired.
--
-- Against 20260717000300 the current version had lost:
--   (a) `balance > 0`. Verified consequence: of 89 users nudged, 8 who had never
--       ordered and held ZERO credits were told "your free credit is waiting",
--       and 2 more at zero balance were told "your credits are still here".
--       Both statements were false.
--   (b) the age gate, with ordering flipped to `created_at desc` — so the
--       once-per-lifetime nudge was spent preferentially on the FRESHEST users,
--       the least likely to have churned. 21 of 89 were nudged inside 24h of
--       signing up. That inverts the whole point of a winback.
--   (c) any notion of recurrence: `winback_sent_at is null` capped every user at
--       one nudge ever, and the pool is now EXHAUSTED — 8 candidates left
--       against ~16 signups/day.
--
-- Dormancy now keys on push_devices.updated_at, which is a genuine "last opened
-- the app" signal on the shipped build: AuthGate calls
-- requestAuthorizationAndRegister() on every signed-in launch, which re-upserts
-- the token row. Nothing in the product reads it today.
drop function if exists public.winback_candidates(integer);

create function public.winback_candidates(p_limit integer default 200)
returns table(user_id uuid, kind text)
language sql
security definer
set search_path to 'public'
as $function$
  select p.user_id,
         case when exists (select 1 from public.orders o where o.user_id = p.user_id)
              then 'tried_failed' else 'never_ordered' end as kind
    from public.profiles p
    join public.wallets w on w.user_id = p.user_id
   where p.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     -- Never promise credits to someone who has none.
     and w.balance > 0
     -- Recurring, but bounded: at most 3 in a lifetime, 14 days apart.
     and p.winback_sent_count < 3
     and (p.winback_sent_at is null or p.winback_sent_at < now() - interval '14 days')
     -- Genuinely dormant: hasn't opened the app in 3 days.
     and exists (
           select 1 from public.push_devices d
            where d.user_id = p.user_id
              and d.updated_at < now() - interval '3 days')
     -- Never won back someone who is already succeeding.
     and not exists (
           select 1 from public.orders o
            where o.user_id = p.user_id
              and (o.status = 'received' or o.otp is not null))
     -- Nor anyone currently active.
     and not exists (
           select 1 from public.orders o
            where o.user_id = p.user_id
              and o.created_at >= now() - interval '3 days')
   order by p.created_at asc    -- oldest/most-churned first, not freshest
   limit p_limit;
$function$;

revoke execute on function public.winback_candidates(integer) from public, anon, authenticated;

-- ── 3. reorder_candidates — the cohort with proven fit and NO lifecycle.
--
-- winback_candidates excludes anyone with a delivered order, and
-- stranded_credit_candidates requires the last order to have FAILED. So users
-- who succeeded were excluded from every nudge in the product by construction —
-- despite being the only cohort with demonstrated fit (12 of 13 code-receivers
-- went on to purchase; 2+ codes averages 14.8 lifetime orders).
--
-- Window is deliberately tight (3-14 days). Every observed repeat order happens
-- within 5 days, so a nudge at day 30 is talking to someone who is already gone.
create or replace function public.reorder_candidates(p_limit integer default 200)
returns table(user_id uuid, balance integer, last_service text)
language sql
security definer
set search_path to 'public'
as $function$
  select w.user_id, w.balance, s.name as last_service
    from public.wallets w
    join public.profiles p on p.user_id = w.user_id
    join lateral (
      select o.service_id, o.created_at
        from public.orders o
       where o.user_id = w.user_id
         and (o.status = 'received' or o.otp is not null)
       order by o.created_at desc
       limit 1
    ) last_ok on true
    left join public.services s on s.id = last_ok.service_id
   where w.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and w.balance > 0
     and p.reorder_nudge_count < 3
     and (p.reorder_nudge_sent_at is null
          or p.reorder_nudge_sent_at < now() - interval '14 days')
     -- Inside the observed repeat window, but past the same-session burst.
     and last_ok.created_at < now() - interval '3 days'
     and last_ok.created_at > now() - interval '14 days'
     and not exists (
           select 1 from public.orders o
            where o.user_id = w.user_id
              and o.created_at >= now() - interval '3 days')
     and exists (select 1 from public.push_devices d where d.user_id = w.user_id)
   order by w.balance desc
   limit p_limit;
$function$;

revoke execute on function public.reorder_candidates(integer) from public, anon, authenticated;

-- ── 4. claim_daily_credit_for — same ladder, callable by the service role.
--
-- claim_daily_credit() reads auth.uid(), which is NULL under the service role,
-- so an edge function cannot grant on the user's behalf. That is why the daily
-- credit needs a button — and the button only exists in an unreleased build,
-- which is why 95-104 pushes/day have produced ZERO claims and will repeat
-- forever (the dedupe is `last_daily_credit_on = today`, which the shipped app
-- can never set).
--
-- With this, register-push can grant on app open: the app already calls it on
-- every cold launch, so "opening the app" becomes the trigger. That preserves
-- the design intent exactly — pay people who came back, not people who didn't —
-- with no app update.
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

revoke execute on function public.claim_daily_credit_for(uuid) from public, anon, authenticated;
