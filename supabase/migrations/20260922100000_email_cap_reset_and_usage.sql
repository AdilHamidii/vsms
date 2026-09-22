-- E-mail subscriber caps: an owner-issued reset, and a usage read the app can
-- show (owner decisions 2026-09-22).
--
-- 1. `profiles.email_cap_reset_at` — the included-address caps (8/day, 60 per
--    rolling 30 days) count only orders created AT OR AFTER this instant. It
--    exists so the owner can clear one subscriber's usage without deleting or
--    rewriting their orders (which would falsify history and the refund
--    ledger). Set by hand: `update profiles set email_cap_reset_at = now()
--    where user_id = …`. Clients cannot write it — profiles UPDATE is
--    column-granted to display_name only (asserted at the bottom).
--
-- 2. `email_included_used(user, since)` is now the ONE count both caps use,
--    and `email_sub_caps()` the ONE read of both limits. begin_email_order (the
--    refusal) and email_usage (the number shown in the app) call the same two
--    functions, so the app can never say "4 of 8 today" while the server
--    refuses as if it were 8 of 8 — the predicate-drift failure this repo has
--    shipped before (see CLAUDE.md, the `greatest` vs `coalesce` bug).
--
-- begin_email_order is otherwise UNCHANGED from its live definition as read on
-- 2026-09-22 via pg_get_functiondef — diffed clause by clause: only the two
-- subscriber count statements and the two cap reads were replaced.

alter table public.profiles add column if not exists email_cap_reset_at timestamptz;

comment on column public.profiles.email_cap_reset_at is
  'Owner-issued reset of the e-mail subscriber caps: included addresses created '
  'before this instant are not counted. Service-role only.';

-- The included-address count. DELIVERED plus in-flight, cost_credits = 0 only
-- (a paid 1-credit address never consumes the included allowance), from the
-- later of `p_since` and the user's reset.
create or replace function public.email_included_used(p_user uuid, p_since timestamptz)
returns integer
language sql stable security definer
set search_path to 'public'
as $$
  select count(*)::integer
    from public.email_orders e
   where e.user_id = p_user
     and e.cost_credits = 0
     and (e.code is not null or e.status = 'waiting')
     and e.created_at >= greatest(
           p_since,
           coalesce((select p.email_cap_reset_at from public.profiles p
                      where p.user_id = p_user), '-infinity'::timestamptz));
$$;

-- Both subscriber limits, clamped exactly as begin_email_order clamped them.
create or replace function public.email_sub_caps(out daily integer, out monthly integer)
language sql stable security definer
set search_path to 'public'
as $$
  select
    coalesce((select greatest(0, least(10000, coalesce((value #>> '{}')::integer, 25)))
                from public.app_config where key = 'email_sub_daily_cap'), 25),
    coalesce((select greatest(0, least(100000, coalesce((value #>> '{}')::integer, 60)))
                from public.app_config where key = 'email_sub_monthly_cap'), 60);
$$;

-- What the app renders. Subscriber limits only: a non-subscriber is bounded by
-- the lifetime free grant, which is not a daily/monthly meter.
create or replace function public.email_usage(p_user uuid)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_day_start timestamptz := date_trunc('day', now() at time zone 'utc') at time zone 'utc';
  v_month_start timestamptz := now() - interval '30 days';
  v_caps record;
  v_reset timestamptz;
  v_oldest timestamptz;
begin
  select * into v_caps from public.email_sub_caps();
  select email_cap_reset_at into v_reset from public.profiles where user_id = p_user;

  -- When the 30-day meter is full, the next slot frees when the OLDEST counted
  -- order leaves the window. Same predicate as email_included_used.
  select min(e.created_at) into v_oldest
    from public.email_orders e
   where e.user_id = p_user and e.cost_credits = 0
     and (e.code is not null or e.status = 'waiting')
     and e.created_at >= greatest(v_month_start, coalesce(v_reset, '-infinity'::timestamptz));

  return jsonb_build_object(
    'subscribed',        public.has_email_subscription(p_user),
    'daily_used',        public.email_included_used(p_user, v_day_start),
    'daily_cap',         v_caps.daily,
    'daily_resets_at',   v_day_start + interval '1 day',
    'monthly_used',      public.email_included_used(p_user, v_month_start),
    'monthly_cap',       v_caps.monthly,
    'monthly_next_slot_at', case when v_oldest is null then null
                                 else v_oldest + interval '30 days' end
  );
end;
$$;

CREATE OR REPLACE FUNCTION public.begin_email_order(p_user uuid, p_service text, p_site text, p_domain text, p_credits integer, p_ip_hash text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_existing uuid; v_order uuid; v_ok boolean;
  v_free_ever integer; v_grants integer;
  v_today integer; v_cap integer;
  v_month integer; v_month_cap integer;
  v_enforced boolean;
  v_email text; v_raw text; v_norm text;
  v_tombstoned integer; v_used integer; v_rows integer;
  v_token text; v_dev text; v_dev_used integer;
  v_ip_cap integer; v_ip_used integer;
  v_count_free boolean := false;
begin
  if p_credits is null or p_credits < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id into v_existing from public.email_orders
   where user_id = p_user and site = p_site and domain = p_domain
     and status = 'waiting' and created_at > now() - interval '2 minutes'
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  if p_credits = 0 then
    select coalesce((value #>> '{}')::boolean, false) into v_enforced
      from public.app_config where key = 'email_subscription_enforced';
    v_enforced := coalesce(v_enforced, false);

    -- Device key: the most recently registered push token for this account.
    -- NULL when the user declined push — then only the IP cap stands.
    select token into v_token from public.push_devices
     where user_id = p_user order by updated_at desc nulls last limit 1;
    v_dev := case when v_token is null then null else md5(v_token) end;

    -- IP cap applies to BOTH non-subscriber free branches, never to a
    -- subscriber. Serialised on the ip so two parallel requests cannot both
    -- read cap-1.
    if p_ip_hash is not null and (not v_enforced or not public.has_email_subscription(p_user)) then
      select greatest(0, least(1000, coalesce((value #>> '{}')::integer, 3)))
        into v_ip_cap from public.app_config where key = 'email_free_ip_daily_cap';
      v_ip_cap := coalesce(v_ip_cap, 3);
      perform pg_advisory_xact_lock(hashtext('email_free_ip:' || p_ip_hash));
      delete from public.free_email_ip_grants where day < current_date - 7;
      select used_count into v_ip_used from public.free_email_ip_grants
       where ip_hash = p_ip_hash and day = (now() at time zone 'utc')::date;
      if coalesce(v_ip_used, 0) >= v_ip_cap then
        return jsonb_build_object('ok', false, 'reason', 'ip_limit_reached',
                                  'cap', v_ip_cap);
      end if;
      v_count_free := true;
    end if;

    if not v_enforced then
      select coalesce((value #>> '{}')::integer, 3) into v_cap
        from public.app_config where key = 'email_free_daily_cap';
      v_cap := coalesce(v_cap, 3);
      -- Counts DELIVERED addresses plus in-flight ones. See the header: an
      -- order that never produced a code did not consume an address, and
      -- `waiting` must stay in the count or a burst bypasses the cap.
      select count(*) into v_today from public.email_orders
       where user_id = p_user and cost_credits = 0
         and (code is not null or status = 'waiting')
         and created_at >= date_trunc('day', now() at time zone 'utc');
      if v_today >= v_cap then
        return jsonb_build_object('ok', false, 'reason', 'free_limit_reached',
                                  'cap', v_cap);
      end if;

    elsif public.has_email_subscription(p_user) then
      -- Both limits and both counts come from the SAME two helpers email_usage
      -- uses, so the meter in the app and this refusal cannot disagree
      -- (migration 20260922100000). email_included_used honours the owner's
      -- per-user reset in profiles.email_cap_reset_at.
      select daily, monthly into v_cap, v_month_cap from public.email_sub_caps();
      v_today := public.email_included_used(
        p_user, date_trunc('day', now() at time zone 'utc') at time zone 'utc');
      if v_today >= v_cap then
        return jsonb_build_object('ok', false, 'reason', 'daily_cap_reached',
                                  'cap', v_cap);
      end if;

      -- The rolling 30-day cap. See the header of migration 20260921100000 for
      -- why the daily cap above cannot do this job. Checked AFTER the daily one
      -- so a subscriber who is over both is told about the shorter,
      -- self-clearing limit first. Rolling rather than calendar-monthly on
      -- purpose — a calendar reset hands a farm its whole allowance again at
      -- midnight on the 1st.
      v_month := public.email_included_used(p_user, now() - interval '30 days');
      if v_month >= v_month_cap then
        return jsonb_build_object('ok', false, 'reason', 'monthly_cap_reached',
                                  'cap', v_month_cap);
      end if;

    else
      -- ⚠️ UNCHANGED ON PURPOSE — see the header. `v_free_ever` is only one of
      -- three inputs to `v_used`, and the two tombstones below count every
      -- attempt regardless of outcome, so exempting failures here would change
      -- no decision while reading as though it did.
      select greatest(0, least(50, coalesce((value #>> '{}')::integer, 1)))
        into v_grants from public.app_config
       where key = 'email_free_lifetime_grants';
      v_grants := coalesce(v_grants, 1);
      select count(*) into v_free_ever from public.email_orders
       where user_id = p_user and cost_credits = 0 and status <> 'failed';

      v_email := null;
      begin
        select u.email into v_email from auth.users u where u.id = p_user;
      exception when others then
        v_email := null;
      end;

      if v_email is not null and public.normalize_email(v_email) is not null then
        v_raw  := md5(lower(v_email));
        v_norm := md5(public.normalize_email(v_email));
        perform pg_advisory_xact_lock(hashtext('email_free_grant:' || v_norm));
        select coalesce(max(used_count), 0) into v_tombstoned
          from public.email_free_grants
         where email_hash = v_raw or email_hash_norm = v_norm;
      else
        v_raw := null; v_norm := null; v_tombstoned := 0;
      end if;

      -- The device tombstone. 75 farm accounts on 2 phones is the case this
      -- reads for: the mailbox is new every time, the token is not.
      v_dev_used := 0;
      if v_dev is not null then
        perform pg_advisory_xact_lock(hashtext('email_free_device:' || v_dev));
        select used_count into v_dev_used from public.free_email_device_grants
         where token_hash = v_dev;
        v_dev_used := coalesce(v_dev_used, 0);
      end if;

      v_used := greatest(coalesce(v_free_ever, 0), coalesce(v_tombstoned, 0), v_dev_used);
      if v_used >= v_grants then
        return jsonb_build_object('ok', false, 'reason', 'subscription_required',
                                  'used', v_used, 'grants', v_grants);
      end if;

      if v_raw is not null then
        update public.email_free_grants
           set used_count      = used_count + 1,
               last_used_at    = now(),
               email_hash_norm = coalesce(email_hash_norm, v_norm)
         where email_hash = v_raw or email_hash_norm = v_norm;
        get diagnostics v_rows = row_count;
        if v_rows = 0 then
          insert into public.email_free_grants
            (email_hash, email_hash_norm, used_count, first_used_at, last_used_at)
          values (v_raw, v_norm, 1, now(), now())
          on conflict (email_hash) do update
             set used_count      = public.email_free_grants.used_count + 1,
                 email_hash_norm = coalesce(public.email_free_grants.email_hash_norm,
                                            excluded.email_hash_norm),
                 last_used_at    = now();
        end if;
      end if;

      if v_dev is not null then
        insert into public.free_email_device_grants
          (token_hash, used_count, first_used_at, last_used_at)
        values (v_dev, 1, now(), now())
        on conflict (token_hash) do update
           set used_count   = public.free_email_device_grants.used_count + 1,
               last_used_at = now();
      end if;
    end if;

    if v_count_free then
      insert into public.free_email_ip_grants (ip_hash, day, used_count)
      values (p_ip_hash, (now() at time zone 'utc')::date, 1)
      on conflict (ip_hash, day) do update
         set used_count = public.free_email_ip_grants.used_count + 1;
    end if;
  end if;

  insert into public.email_orders (user_id, service_id, site, domain, cost_credits, status)
  values (p_user, p_service, p_site, p_domain, p_credits, 'waiting')
  returning id into v_order;

  if p_credits > 0 then
    select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
    if not coalesce(v_ok, false) then
      delete from public.email_orders where id = v_order;
      return jsonb_build_object('ok', false, 'reason', 'insufficient');
    end if;
    update public.wallet_transactions set email_order_id = v_order
     where id = (select id from public.wallet_transactions
                  where user_id = p_user and reason = 'spend' and email_order_id is null
                  order by created_at desc, id desc limit 1);
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order);
end;
$function$;

-- Service role only. REVOKE from PUBLIC explicitly: CREATE FUNCTION grants
-- EXECUTE to PUBLIC, and a revoke from anon/authenticated alone is a no-op
-- (CLAUDE.md, "revoke execute … IS A NO-OP while PUBLIC holds the grant").
revoke all on function public.email_included_used(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.email_sub_caps() from public, anon, authenticated;
revoke all on function public.email_usage(uuid) from public, anon, authenticated;
grant execute on function public.email_included_used(uuid, timestamptz) to service_role;
grant execute on function public.email_sub_caps() to service_role;
grant execute on function public.email_usage(uuid) to service_role;
