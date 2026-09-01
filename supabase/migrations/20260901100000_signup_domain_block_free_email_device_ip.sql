-- Stop the free-e-mail signup farm: block disposable domains at SIGNUP, and
-- key the free temp-e-mail allowance on the DEVICE and the IP, not only the
-- mailbox.
--
-- ── What was measured (2026-09-01, 7-day window) ────────────────────────────
--
-- 90 email+password signups from throwaway domains in 7 days; 75 of them
-- `utiluan.com`, registered from exactly TWO push tokens. Every account did
-- the same thing: sign up → take the one free outlook.com address for
-- facebook.com → receive the code (70 of 75) → next signup. Zero SMS orders,
-- 168 idle grant credits, and the free outlook pool — the scarcest inventory
-- in the app — drained from real users. That is a third of the week's
-- "signup surge".
--
-- `20260818160000` predicted this exact shape: "Email + password signup means
-- the key can be an address the USER picks, which costs nothing to re-roll."
-- The mailbox-keyed tombstones (`signup_grants`, `email_free_grants`) are
-- correct and still necessary — they close Delete Account on ONE mailbox —
-- but a catch-all domain re-rolls the mailbox for free. What the farm cannot
-- re-roll for free is the PHONE (2 tokens / 75 accounts) and, cheaply, the IP.
--
-- ── What this does ──────────────────────────────────────────────────────────
--
--   1. `public.signup_blocked_domains` + a BEFORE INSERT trigger on auth.users
--      that RAISES for a blocked domain (or any subdomain of one). Owner
--      decision 2026-09-01: reject the signup outright — "I don't want fake
--      signups" — rather than starve it. GoTrue surfaces the raise as a 500
--      `unexpected_failure` ("Database error saving new user"); the app shows
--      its generic error. Nobody on a disposable domain is a customer we lose.
--      Seeded with every domain the farm has used; rotation is expected, so
--      this layer is hygiene and layers 2–3 are the wall.
--   2. `public.free_email_device_grants` — the lifetime free-address allowance
--      also keyed on md5(push token). `begin_email_order`'s non-subscriber
--      branch refuses on greatest(per-user count, mailbox tombstone, DEVICE
--      tombstone). One free address per phone, ever, whatever the mailbox.
--   3. `public.free_email_ip_grants` — free addresses per IP per UTC day,
--      capped by `app_config.email_free_ip_daily_cap` (3). Non-subscriber
--      free path only; a paying subscriber is never IP-capped. Catches a farm
--      that declines push permission (no token) and covers layer 2's gap.
--
-- Both new tables have NO foreign key to auth.users, like every other
-- tombstone in this repo. A real user who deletes and re-creates their account
-- on the same phone gets no second free address — that is the intended
-- meaning of "one per person". Stated residual: a new phone or a new IP is a
-- new allowance; that is a cost floor, not a wall, and the next layer up is
-- Apple DeviceCheck (needs a client release).
--
-- ── Rollback ────────────────────────────────────────────────────────────────
--
--   drop trigger on_auth_user_before_created on auth.users;
--   restore `begin_email_order` from `20260826100000` (5-arg signature) after
--   dropping the 6-arg one here; the two new tables can stay or go.
--   `create-email-order` passes `p_ip_hash`, which the 5-arg body ignores only
--   if redeployed from `20260826100000`'s era — redeploy it too.

-- ── 1. Signup domain block ──────────────────────────────────────────────────

create table if not exists public.signup_blocked_domains (
  domain   text primary key,
  note     text,
  added_at timestamptz not null default now()
);
comment on table public.signup_blocked_domains is
  'E-mail domains refused at signup by on_auth_user_before_created (exact or '
  'any subdomain). Service-role only. Added 2026-09-01 against the utiluan.com '
  'free-e-mail farm.';
alter table public.signup_blocked_domains enable row level security;
revoke all on public.signup_blocked_domains from public, anon, authenticated;

insert into public.signup_blocked_domains (domain, note) values
  ('utiluan.com',              '75 accounts / 2 devices, facebook farm, 2026-08-27..09-01'),
  ('gersos.com',               'facebook farm'),
  ('okyre.com',                'facebook farm'),
  ('mayorlogistic.com',        'facebook farm'),
  ('customclearanceservice.com','facebook farm'),
  ('5secmail.com',             'disposable (bd.5secmail.com seen)'),
  ('umail.asia',               'disposable'),
  ('banglatip.com',            'disposable (asia.banglatip.com seen)'),
  ('668mail.com',              'disposable'),
  ('slotsave.com',             'disposable'),
  ('sergunes.com',             'disposable'),
  ('eltripservice.com',        'disposable'),
  ('revenuebee.top',           'disposable (vip.revenuebee.top seen)'),
  ('mowan666.com',             'disposable'),
  ('hsiqx.com',                'disposable'),
  ('vaztor.com',               'disposable'),
  ('sokmail.com',              'disposable'),
  ('replyloop.com',            'disposable')
on conflict (domain) do nothing;

-- Exact domain or any parent: `bd.5secmail.com` is blocked by `5secmail.com`.
create or replace function public.signup_domain_blocked(p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.signup_blocked_domains b
     where lower(split_part(coalesce(p_email, ''), '@', 2)) = b.domain
        or lower(split_part(coalesce(p_email, ''), '@', 2)) like '%.' || b.domain
  );
$$;
revoke execute on function public.signup_domain_blocked(text) from public, anon, authenticated;

create or replace function public.reject_blocked_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email is not null and public.signup_domain_blocked(new.email) then
    raise exception 'signup_blocked_domain'
      using hint = 'e-mail domain is on public.signup_blocked_domains';
  end if;
  return new;
end;
$$;
revoke execute on function public.reject_blocked_signup() from public, anon, authenticated;

drop trigger if exists on_auth_user_before_created on auth.users;
create trigger on_auth_user_before_created
  before insert on auth.users
  for each row execute function public.reject_blocked_signup();

-- ── 2. Device tombstone ─────────────────────────────────────────────────────

create table if not exists public.free_email_device_grants (
  token_hash    text primary key,
  used_count    integer not null default 0,
  first_used_at timestamptz,
  last_used_at  timestamptz
);
comment on table public.free_email_device_grants is
  'Free temp-e-mail addresses spent per DEVICE (md5 of the APNs push token), '
  'read alongside email_free_grants so a re-rolled mailbox on the same phone '
  'cannot re-arm the lifetime allowance. No FK to auth.users. Added 2026-09-01.';
alter table public.free_email_device_grants enable row level security;
revoke all on public.free_email_device_grants from public, anon, authenticated;

-- Backfill: every token whose holders (all of them, past and present — the
-- unique key is (user_id, token), so a re-used phone has several rows) have
-- taken a free address. Counts what exists today; cascaded history is gone.
insert into public.free_email_device_grants (token_hash, used_count, first_used_at, last_used_at)
select md5(p.token), count(o.id), min(o.created_at), max(o.created_at)
  from public.push_devices p
  join public.email_orders o on o.user_id = p.user_id
 where o.cost_credits = 0 and o.status <> 'failed'
 group by p.token
on conflict (token_hash) do nothing;

-- ── 3. IP daily cap ─────────────────────────────────────────────────────────

create table if not exists public.free_email_ip_grants (
  ip_hash    text not null,
  day        date not null,
  used_count integer not null default 0,
  primary key (ip_hash, day)
);
comment on table public.free_email_ip_grants is
  'Free temp-e-mail addresses per client IP (sha-256, hashed by '
  'create-email-order) per UTC day. Non-subscriber free path only. Rows older '
  'than 7 days are pruned inside begin_email_order. Added 2026-09-01.';
alter table public.free_email_ip_grants enable row level security;
revoke all on public.free_email_ip_grants from public, anon, authenticated;

insert into public.app_config (key, value)
values ('email_free_ip_daily_cap', '3'::jsonb)
on conflict (key) do nothing;

-- ── 4. begin_email_order: device + IP keys on the free path ─────────────────
--
-- The signature gains `p_ip_hash text default null`. The 5-arg function is
-- DROPPED first: leaving both would make PostgREST's named-argument resolution
-- ambiguous for the 5-arg call the not-yet-redeployed bundle still makes.
-- Every existing return key is unchanged; one reason is added:
-- `ip_limit_reached` (create-email-order maps it to the client's existing
-- `free_limit_reached` copy).

drop function if exists public.begin_email_order(uuid, text, text, text, integer);

create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text, p_credits integer,
  p_ip_hash text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing uuid; v_order uuid; v_ok boolean;
  v_free_ever integer; v_grants integer;
  v_today integer; v_cap integer;
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

revoke execute on function public.begin_email_order(uuid, text, text, text, integer, text)
  from public, anon, authenticated;

-- ── 5. Assertions ───────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'on_auth_user_before_created') then
    raise exception 'on_auth_user_before_created trigger was not created';
  end if;
  if not public.signup_domain_blocked('x@utiluan.com') then
    raise exception 'utiluan.com is not blocked';
  end if;
  if not public.signup_domain_blocked('x@bd.5secmail.com') then
    raise exception 'subdomain match is not working';
  end if;
  if public.signup_domain_blocked('x@gmail.com') or public.signup_domain_blocked('x@outlook.fr') then
    raise exception 'a mainstream domain is blocked';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'begin_email_order' and p.pronargs = 5) then
    raise exception 'old 5-arg begin_email_order still present (PostgREST ambiguity)';
  end if;
end $$;
