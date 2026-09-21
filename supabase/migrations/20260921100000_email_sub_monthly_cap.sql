-- A ROLLING 30-DAY cap on a mail subscriber's free addresses, on top of the
-- daily one.
--
-- 🔴 WHY THE DAILY CAP ALONE IS THE WRONG SHAPE. It does not bound a month at
-- all: at 8/day it permits 240 addresses. A $2.99 subscriber nets $2.54 after
-- Apple's 15%, and blended wholesale measured 4.2c/address over the 30 days to
-- 2026-09-21 (outlook.com 3.99c n=398, hotmail.com 4.27c n=79), so break-even
-- is ~60 addresses a month — under 2/day against a cap of 8. At the cap a
-- maxed subscriber costs $10.08 and pays $2.54.
--
-- And the daily cap bites the WRONG USER. Legitimate use is BURSTY — someone
-- registering a few accounts in one sitting — while farming is SUSTAINED, so a
-- per-day limit throttles the burst and never touches the farm. The evidence
-- is direct: the 25 -> 8 daily cut of 2026-09-16 was made against tiktok.com
-- running 76.9% of mail order volume, and in the 7 days to 2026-09-21 it ran
-- 205 of 237 orders (86.5%) from 13 accounts, with single accounts at 53, 43,
-- 33 and 30 orders. The daily cap demonstrably did not stop it.
--
-- 60 is chosen so the WORST case is break-even rather than a loss: 60 x 4.2c =
-- $2.52 against $2.54 of net revenue. It also clears every legitimate month
-- ever observed — the heaviest non-farm month was 36 — so this bounds the farm
-- without touching a real subscriber.
--
-- Enforced in SQL from `app_config`, like the daily cap, so the value can move
-- with no deploy and no release. Deliberately NOT added to the `app_config` RLS
-- whitelist: no client reads it, and the refusal already carries `cap` in its
-- body. Widening that whitelist by one key is the only safe way to publish a
-- value and there is no reason to here.

insert into public.app_config (key, value)
values ('email_sub_monthly_cap', '60'::jsonb)
on conflict (key) do nothing;

create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text,
  p_credits integer, p_ip_hash text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
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
      select count(*) into v_today from public.email_orders
       where user_id = p_user and cost_credits = 0
         and status <> 'failed'
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
         and status <> 'failed'
         and created_at >= date_trunc('day', now() at time zone 'utc');
      if v_today >= v_cap then
        return jsonb_build_object('ok', false, 'reason', 'daily_cap_reached',
                                  'cap', v_cap);
      end if;

      -- The rolling 30-day cap. See the header of this migration for why the
      -- daily cap above cannot do this job. Checked AFTER the daily one so a
      -- subscriber who is over both is told about the shorter, self-clearing
      -- limit first.
      --
      -- `status <> 'failed'` and `cost_credits = 0` match the daily count
      -- exactly — an order that never reached the provider is not an address
      -- consumed, and a PAID address is not what this cap is rationing.
      -- The window is rolling rather than calendar-monthly on purpose: a
      -- calendar reset hands a farm its whole allowance again at midnight on
      -- the 1st, which is the same burst-shaped hole the daily cap has.
      select greatest(0, least(100000, coalesce((value #>> '{}')::integer, 60)))
        into v_month_cap from public.app_config where key = 'email_sub_monthly_cap';
      v_month_cap := coalesce(v_month_cap, 60);
      select count(*) into v_month from public.email_orders
       where user_id = p_user and cost_credits = 0
         and status <> 'failed'
         and created_at >= now() - interval '30 days';
      if v_month >= v_month_cap then
        return jsonb_build_object('ok', false, 'reason', 'monthly_cap_reached',
                                  'cap', v_month_cap);
      end if;

    else
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
$$;

-- `CREATE FUNCTION` grants EXECUTE to PUBLIC by default and anon/authenticated
-- are members of PUBLIC, so a bare `revoke ... from anon, authenticated` is a
-- no-op. Revoke from PUBLIC, then grant only the service role.
revoke execute on function public.begin_email_order(uuid, text, text, text, integer, text) from public;
grant  execute on function public.begin_email_order(uuid, text, text, text, integer, text) to service_role;
