-- Email + password sign-up: pay the signup grant only after the address is
-- CONFIRMED, and key the tombstone on a NORMALIZED address.
--
-- ── Why this is needed ───────────────────────────────────────────────────────
--
-- Every credit grant in this app is farmable through Delete Account unless it
-- is tombstoned outside the `auth.users` cascade. `signup_grants` is that
-- tombstone, and CLAUDE.md states the guarantee it rests on:
--
--   "The email hash works because Apple's private-relay address is stable per
--    (user, app), so it survives deletion while storing no address."
--
-- That sentence is TRUE and, the moment a user can choose their own address, it
-- stops being the whole story. Apple mints one relay address per (Apple ID,
-- app) and returns the same one forever, so a fresh md5 costs a whole new Apple
-- ID. A self-chosen address costs nothing: `a+1@gmail.com`, `a+2@gmail.com` and
-- `a.b@gmail.com` all reach one inbox and all produce different md5s.
--
-- Two changes close that, and NEITHER of them is sufficient alone:
--   1. the tombstone key is normalized, so plus-tags and gmail dots collapse;
--   2. the grant is paid on CONFIRMATION, so the address must actually receive
--      mail before it is worth anything.
--
-- ⚠️ WHAT THIS STILL DOES NOT DEFEND AGAINST, stated plainly so nobody reads a
-- guarantee that is not here: a user who owns ten real mailboxes gets ten
-- grants. That is a cost floor, not a wall, and it is LOWER than Apple's. Price
-- the signup grant accordingly — it is 0 today.
--
-- ── Why the key is a NEW COLUMN and not a rewrite ────────────────────────────
--
-- 🔴 DO NOT "FIX" THIS BY REWRITING `email_hash` IN PLACE. Measured 2026-08-18:
-- of 517 tombstones, 509 match a live `auth.users` row and **8 do not** — those
-- 8 are deleted accounts, which is precisely what a tombstone is FOR. We store
-- only the md5, so their original address is unrecoverable and their normalized
-- hash can never be computed. A migration that changed the key would silently
-- drop the only 8 rows that are doing real work.
--
-- So `email_hash` stays the primary key and stays enforced; `email_hash_norm`
-- is added beside it and BOTH are checked. Old rows keep protecting the exact
-- addresses they always did.

-- ── 1. Normalization ────────────────────────────────────────────────────────

create or replace function public.normalize_email(p_email text)
returns text
language plpgsql
immutable
as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
  v_local  text;
  v_domain text;
begin
  if v = '' then return null; end if;
  -- No '@' is not an address we can reason about; hash it as-is rather than
  -- inventing structure.
  if position('@' in v) = 0 then return v; end if;

  v_local  := split_part(v, '@', 1);
  v_domain := split_part(v, '@', 2);

  -- Plus-addressing is universal across the providers we see and is the
  -- cheapest way to mint a fresh identity, so it is stripped everywhere.
  if position('+' in v_local) > 0 then
    v_local := split_part(v_local, '+', 1);
  end if;

  -- ⚠️ DOTS ARE STRIPPED FOR GMAIL ONLY, and that restraint is the point.
  -- Google ignores dots in the local part; outlook.com, yahoo.com and the rest
  -- do NOT, so stripping them everywhere would merge two real strangers into
  -- one tombstone and rob the second of a grant they are owed. Apple relay
  -- locals are hex and contain neither dots nor plus signs, so they are
  -- untouched either way.
  if v_domain in ('gmail.com', 'googlemail.com') then
    v_local  := replace(v_local, '.', '');
    v_domain := 'gmail.com';
  end if;

  if v_local = '' then return null; end if;
  return v_local || '@' || v_domain;
end;
$$;

revoke execute on function public.normalize_email(text) from public, anon, authenticated;

-- ── 2. The second key ───────────────────────────────────────────────────────

alter table public.signup_grants
  add column if not exists email_hash_norm text;

comment on column public.signup_grants.email_hash_norm is
  'md5(normalize_email(address)). Added 2026-08-18 for email/password signup. '
  'NULL for the 8 rows belonging to deleted accounts, whose address is '
  'unrecoverable — never backfillable, and that is expected.';

create unique index if not exists signup_grants_email_hash_norm_key
  on public.signup_grants (email_hash_norm)
  where email_hash_norm is not null;

-- ── 3. Backfill, in the SAME migration as the readers ───────────────────────
--
-- `distinct on` is the collision handler: if two live accounts normalize to the
-- same hash, the OLDEST takes the normalized key and the younger keeps only its
-- legacy hash — still enforced, just not merged. That branch is dead today (526
-- distinct raw hashes, 526 distinct normalized) and stops being dead the first
-- time someone signs up with a plus-tag.

update public.signup_grants g
   set email_hash_norm = s.norm_hash
  from (
    select distinct on (md5(public.normalize_email(u.email)))
           md5(lower(u.email))                  as raw_hash,
           md5(public.normalize_email(u.email)) as norm_hash
      from auth.users u
     where u.email is not null
       and public.normalize_email(u.email) is not null
     order by md5(public.normalize_email(u.email)), u.created_at asc
  ) s
 where g.email_hash = s.raw_hash
   and g.email_hash_norm is null;

-- ── 4. The grant itself, in one place ───────────────────────────────────────

create or replace function public.grant_signup_bonus(p_user uuid, p_email text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_raw   text;
  v_norm  text;
  v_bonus integer;
  v_seen  boolean := false;
begin
  -- Fails OPEN on a null address, matching the policy the other two grants
  -- already state: a missed grant on a legitimate signup costs more than a rare
  -- duplicate.
  if p_email is null or public.normalize_email(p_email) is null then
    return;
  end if;

  v_raw  := md5(lower(p_email));
  v_norm := md5(public.normalize_email(p_email));

  -- Serialise on the NORMALIZED identity. The referral path's lock is per
  -- invitee, which does not serialise two different user ids that share one
  -- mailbox — the exact case this migration exists to close.
  perform pg_advisory_xact_lock(hashtext('signup_grant:' || v_norm));

  -- 🔴 THE IDEMPOTENCE GUARD, and the reason two triggers can call this.
  -- Apple signups arrive already-confirmed and are paid from the INSERT
  -- trigger; email signups are paid from the confirmation trigger. A user who
  -- somehow hits both must be paid once.
  if exists (select 1 from public.wallet_transactions
              where user_id = p_user and reason = 'signup_bonus') then
    return;
  end if;

  -- Policy amount. Regex-guarded and clamped — unchanged from handle_new_user,
  -- where it was a fix for an overflow. Do not "simplify" the cast.
  select case
           when c.value->>'credits' ~ '^[0-9]{1,9}$'
             then least(greatest((c.value->>'credits')::int, 0), 50)
             else 0
         end
    into v_bonus
    from public.app_config c
   where c.key = 'signup_bonus_credits';
  v_bonus := coalesce(v_bonus, 0);

  -- Nothing to pay: burn no tombstone. A tombstone written for a grant that
  -- never happened would silently deny the user their first real one.
  if v_bonus = 0 then
    return;
  end if;

  -- Both keys. The legacy one still protects every address granted before
  -- 2026-08-18, including the 8 whose accounts are gone.
  select true into v_seen
    from public.signup_grants
   where email_hash = v_raw or email_hash_norm = v_norm;

  if v_seen then
    update public.signup_grants
       set grant_count = grant_count + 1
     where email_hash = v_raw or email_hash_norm = v_norm;
    return;
  end if;

  insert into public.signup_grants (email_hash, email_hash_norm)
  values (v_raw, v_norm)
  on conflict (email_hash) do update
     set grant_count      = public.signup_grants.grant_count + 1,
         email_hash_norm  = coalesce(public.signup_grants.email_hash_norm,
                                     excluded.email_hash_norm);

  perform public.wallet_credit(p_user, v_bonus, 'signup_bonus', null, null);

exception when others then
  -- ⚠️ DELIBERATE, AND THE TRADE IS ASYMMETRIC. This function is reachable from
  -- an AFTER INSERT trigger on auth.users, where anything that raises fails
  -- SIGNUP ITSELF for every user. A missed grant is recoverable by hand
  -- (`goodwill-credit` exists); a signup that 500s is not. The block is a
  -- subtransaction, so a failure here rolls back this function's own writes and
  -- cannot leave a tombstone without its credit.
  raise warning 'signup grant failed for % : %', p_user, sqlerrm;
end;
$$;

revoke execute on function public.grant_signup_bonus(uuid, text) from public, anon, authenticated;

-- ── 5. handle_new_user: profile + wallet always, grant only when confirmed ──

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
    insert into public.profiles (user_id, display_name, referral_code)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
        public.gen_referral_code()
    );

    -- ALWAYS, and always at ZERO. `wallet_credit` raises without this row, so
    -- it has to exist before any grant is attempted — and the balance is now
    -- moved by `wallet_credit` rather than written here, so the ledger and the
    -- balance can never disagree about a signup bonus.
    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, 0, now());

    -- 🔴 THE CONFIRMED CHECK IS THE WHOLE POINT. Apple and every other OAuth
    -- signup arrives with `email_confirmed_at` already set, so those users are
    -- paid right here, exactly as before. An email/password signup arrives
    -- UNCONFIRMED — it is paid by `on_auth_user_confirmed` once the user proves
    -- they can receive mail at that address.
    if new.email_confirmed_at is not null then
      perform public.grant_signup_bonus(new.id, new.email);
    end if;

    return new;
end;
$$;

-- ── 6. The confirmation trigger ─────────────────────────────────────────────

create or replace function public.handle_user_confirmed()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.grant_signup_bonus(new.id, new.email);
  return new;
end;
$$;

drop trigger if exists on_auth_user_confirmed on auth.users;

-- ⚠️ THE `when` CLAUSE IS LOAD-BEARING, NOT TIDINESS. `AFTER UPDATE OF col`
-- fires on any UPDATE that MENTIONS the column, not only one that changes it —
-- and GoTrue writes auth.users on every single sign-in (`last_sign_in_at`).
-- Without the guard this would run on every login forever.
create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row
  when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.handle_user_confirmed();

-- ── 7. redeem_referral reads and writes BOTH keys ───────────────────────────

create or replace function public.redeem_referral(p_referee uuid, p_code text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_referrer uuid;
    v_n        integer;
    v_hash     text;
    v_norm     text;
    v_email    text;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return 'invalid_code';
    end if;

    -- Serialise per invitee so two concurrent redemptions cannot both pay.
    perform pg_advisory_xact_lock(hashtext(p_referee::text));

    if exists (select 1 from public.profiles
                where user_id = p_referee and referred_by is not null) then
        return 'already_referred';
    end if;

    -- Durable identity check. The predicate above reads `profiles`, which is
    -- erased by Delete Account, so on its own it re-opens the +2 on every
    -- re-signup. `signup_grants` lives outside that cascade.
    --
    -- Checks BOTH keys as of 2026-08-18: the legacy md5 still covers every
    -- address tombstoned before that date (including 8 whose accounts are
    -- deleted and whose address can never be recovered), while the normalized
    -- key is what stops one mailbox becoming ten through plus-tags now that
    -- users can choose their own address.
    --
    -- Fails OPEN on a null email, matching handle_new_user's stated policy.
    select u.email into v_email from auth.users u where u.id = p_referee;
    v_hash := case when v_email is null then null else md5(lower(v_email)) end;
    v_norm := case when public.normalize_email(v_email) is null then null
                   else md5(public.normalize_email(v_email)) end;

    if v_norm is not null then
        perform pg_advisory_xact_lock(hashtext('signup_grant:' || v_norm));
    end if;

    if v_hash is not null and exists (
        select 1 from public.signup_grants
         where (email_hash = v_hash
                or (v_norm is not null and email_hash_norm = v_norm))
           and referral_redeemed_at is not null
    ) then
        return 'already_referred';
    end if;

    select user_id into v_referrer
        from public.profiles
        where upper(referral_code) = upper(trim(p_code));
    if v_referrer is null then return 'invalid_code'; end if;
    if v_referrer = p_referee then return 'self'; end if;

    update public.profiles
        set referred_by = v_referrer
        where user_id = p_referee and referred_by is null;

    -- Only pay if THIS call is the one that claimed the referral.
    get diagnostics v_n = row_count;
    if v_n = 0 then return 'already_referred'; end if;

    if v_hash is not null then
        -- ⚠️ UPDATE-then-INSERT, no longer a single `on conflict (email_hash)`.
        -- There are now TWO unique constraints on this table, and an ON
        -- CONFLICT naming one of them does not catch a violation of the other —
        -- the same class of trap as the partial-index ON CONFLICT that made
        -- every inbound webhook 500 (see CLAUDE.md).
        update public.signup_grants
           set referral_redeemed_at = coalesce(referral_redeemed_at, now()),
               email_hash_norm      = coalesce(email_hash_norm, v_norm)
         where email_hash = v_hash
            or (v_norm is not null and email_hash_norm = v_norm);

        get diagnostics v_n = row_count;
        if v_n = 0 then
            insert into public.signup_grants (email_hash, email_hash_norm, referral_redeemed_at)
            values (v_hash, v_norm, now())
            on conflict (email_hash) do update
               set referral_redeemed_at =
                     coalesce(public.signup_grants.referral_redeemed_at, now());
        end if;
    end if;

    perform public.wallet_credit(p_referee, 2, 'referral_invitee', null, null);
    return 'ok';
end;
$$;

revoke execute on function public.redeem_referral(uuid, text) from public, anon, authenticated;

-- ── 8. Assert, rather than hope ─────────────────────────────────────────────

do $$
declare
  v_unbackfilled integer;
  v_total        integer;
begin
  select count(*) into v_total from public.signup_grants;
  select count(*) into v_unbackfilled
    from public.signup_grants where email_hash_norm is null;

  -- 8 orphans from deleted accounts are expected and unrecoverable; anything
  -- much beyond that means the backfill matched nothing and shipped a table
  -- that protects only half of what it claims to.
  if v_unbackfilled > 12 then
    raise exception 'signup_grants backfill matched too little: % of % rows have no normalized hash',
      v_unbackfilled, v_total;
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'on_auth_user_confirmed') then
    raise exception 'on_auth_user_confirmed trigger was not created';
  end if;

  -- The normalizer is the security boundary; a regression here is silent.
  if public.normalize_email('Foo.Bar+spam@GoogleMail.com') <> 'foobar@gmail.com' then
    raise exception 'normalize_email: gmail dots/plus not collapsed';
  end if;
  if public.normalize_email('foo.bar+x@outlook.com') <> 'foo.bar@outlook.com' then
    raise exception 'normalize_email: non-gmail dots must be preserved';
  end if;
  if public.normalize_email('  A@B.COM ') <> 'a@b.com' then
    raise exception 'normalize_email: trim/lower failed';
  end if;
  if public.normalize_email(null) is not null or public.normalize_email('') is not null then
    raise exception 'normalize_email: null/empty must yield null';
  end if;
end;
$$;
