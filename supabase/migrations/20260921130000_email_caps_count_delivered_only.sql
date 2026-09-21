-- A temp-e-mail order that never delivered a code no longer consumes a cap.
--
-- WHY (2026-09-21, owner decision). A paying mail.monthly subscriber
-- (auto-renew ON, 8 orders a day for three days straight) wrote in: one of his
-- eight addresses expired with no code, and the failure ate the slot. He is
-- sold eight ADDRESSES a day and was receiving eight ATTEMPTS.
--
-- The cause is the predicate this migration replaces. All three cap counts
-- read `status <> 'failed'`, and `failed` means only "never reached the
-- provider". An order that DID get a mailbox and then never received a code is
-- `expired` (or `canceled`), so it counted — the user paid for the difference.
--
-- THE NEW PREDICATE, and why it is not simply "delivered":
--
--     (code is not null or status = 'waiting')
--
-- `code is not null` is the authority for "an address was consumed", never
-- `status = 'received'` — the same rule the SMS side applies to `otp`, and the
-- reason is identical: the vendor's own vocabulary is undocumented and the
-- value meaning "a code arrived" has never been observed. Encoding a guess
-- about their enum is what broke eSIM refunds.
--
-- 🔴 `status = 'waiting'` is LOAD-BEARING and must not be dropped as
-- redundant. Without it an in-flight order counts for nothing until it
-- settles, so a caller could fire fifty concurrent orders and every one of
-- them would read the cap as zero-consumed. Counting in-flight orders is what
-- holds concurrency at the cap (8 for a subscriber) and turns the residual
-- exposure below from unbounded into rate-limited.
--
-- RESIDUAL, stated plainly because the owner accepted it knowingly: someone
-- who orders and lets every address expire now draws on the shared free
-- outlook/hotmail pool without a daily or monthly ceiling. That pool is
-- genuinely scarce — one sweep measured TWO addresses available for
-- discord.com. The bound is concurrency × window: at most `email_sub_daily_cap`
-- orders in flight at once against a ~22-minute window, so roughly 500/day
-- worst case for one determined account. It yields the abuser nothing (an
-- expired mailbox carries no code), so the cost is pool pressure, not free
-- accounts. If the pool starts running dry, the lever is a separate attempt
-- ceiling — do NOT quietly re-add failures to these counts, which would
-- reintroduce the bug this migration fixes.
--
-- ⚠️ DELIBERATELY NOT CHANGED: the non-subscriber LIFETIME free grant
-- (`v_free_ever` / `email_free_lifetime_grants`). Exempting it would be inert
-- and misleading — `v_used` is `greatest(v_free_ever, v_tombstoned,
-- v_dev_used)`, and both tombstones increment on every ATTEMPT regardless of
-- outcome, so the tombstone would still say 1. Making them conditional on
-- delivery means writing them only after a code arrives, which reopens exactly
-- the farm vector they exist to close (one mailbox key farmed 75 times from two
-- phones). A first-time user whose single free address fails still gets
-- nothing; that is a separate owner decision with real farm risk attached.

create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text,
  p_credits integer, p_ip_hash text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
      select greatest(0, least(10000, coalesce((value #>> '{}')::integer, 25)))
        into v_cap from public.app_config where key = 'email_sub_daily_cap';
      v_cap := coalesce(v_cap, 25);
      select count(*) into v_today from public.email_orders
       where user_id = p_user and cost_credits = 0
         and (code is not null or status = 'waiting')
         and created_at >= date_trunc('day', now() at time zone 'utc');
      if v_today >= v_cap then
        return jsonb_build_object('ok', false, 'reason', 'daily_cap_reached',
                                  'cap', v_cap);
      end if;

      -- The rolling 30-day cap. See the header of migration 20260921100000 for
      -- why the daily cap above cannot do this job. Checked AFTER the daily one
      -- so a subscriber who is over both is told about the shorter,
      -- self-clearing limit first.
      --
      -- The predicate matches the daily count EXACTLY, and it must keep
      -- matching: a subscriber told "your day is clear" by one rule and
      -- "your month is full" by a different one cannot act on either. The
      -- window is rolling rather than calendar-monthly on purpose — a calendar
      -- reset hands a farm its whole allowance again at midnight on the 1st,
      -- which is the same burst-shaped hole the daily cap has.
      select greatest(0, least(100000, coalesce((value #>> '{}')::integer, 60)))
        into v_month_cap from public.app_config where key = 'email_sub_monthly_cap';
      v_month_cap := coalesce(v_month_cap, 60);
      select count(*) into v_month from public.email_orders
       where user_id = p_user and cost_credits = 0
         and (code is not null or status = 'waiting')
         and created_at >= now() - interval '30 days';
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

revoke execute on function public.begin_email_order(uuid, text, text, text, integer, text)
  from public, anon, authenticated;
