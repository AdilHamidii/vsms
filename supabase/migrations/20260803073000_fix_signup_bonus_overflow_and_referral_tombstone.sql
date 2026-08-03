-- Two defects in 20260803070000, both found by adversarial review of that
-- migration and both confirmed against the live database before fixing.
--
-- ── 1. The regex guard did not prevent the ::int cast from raising ─────────
--
-- `~ '^[0-9]+$'` constrains the CHARACTER SET but not the MAGNITUDE, and the
-- clamp least(greatest(x,0),50) is applied to the RESULT of the cast, so it can
-- never stop the cast itself. Verified live:
--
--     select case when '99999999999' ~ '^[0-9]+$'
--                 then least(greatest(('99999999999')::int,0),50) else 0 end;
--     ERROR: 22003: value "99999999999" is out of range for type integer
--
-- handle_new_user is a trigger on auth.users, so that raise does not fail the
-- grant — it fails SIGNUP, for everyone, until the row is corrected. And the
-- re-enable recipe the previous migration documents is a hand-written UPDATE
-- with nothing validating it, so one extra keystroke was a total outage.
--
-- Bounding the regex to at most 9 digits makes overflow structurally
-- impossible: 999999999 < 2147483647. Longer input resolves to 0, which is the
-- correct fail-closed direction. A CHECK constraint is added as well so a
-- malformed write is rejected at UPDATE time rather than silently disabling
-- the grant and being discovered by users getting nothing.
--
-- ── 2. Disabling the bonus made the REFERRAL bonus farmable ────────────────
--
-- signup_grants is shared by TWO grants. handle_new_user was its only writer,
-- and 20260803070000 stopped it writing when the bonus is 0 (nothing was paid,
-- so nothing to tombstone — correct in isolation). But redeem_referral records
-- its own tombstone with a BARE UPDATE on that same row:
--
--     update public.signup_grants set referral_redeemed_at = now()
--      where email_hash = v_hash;          -- matches 0 rows, succeeds silently
--
-- With no row present that write does nothing, and redeem_referral's durable
-- guard (`exists ... and referral_redeemed_at is not null`) then finds nothing.
-- Chain: sign up while the bonus is off (no row) -> redeem a referral (+2 to
-- the joiner, +5 queued to the referrer) -> delete the account, which Apple
-- mandates we offer -> sign in again with the same private-relay address, which
-- is stable per (user, app) -> no row again -> redeem again. Unbounded.
--
-- Exactly the invariant CLAUDE.md calls the most repeated money bug here:
-- every grant needs a tombstone OUTSIDE the auth.users cascade, and it must not
-- depend on a different grant having paid out. Each grant now owns its own.
--
-- Currently unexploited only because profiles.referred_by is 0 rows — the
-- referral feature has never been used. Structural, not latent on usage.
--
-- redeem_referral below is regenerated from pg_get_functiondef and diffed
-- clause by clause: exactly ONE hunk differs (the UPDATE above becoming an
-- upsert). Same for handle_new_user: one hunk, the regex bound.

alter table public.app_config drop constraint if exists app_config_signup_bonus_sane;
alter table public.app_config add constraint app_config_signup_bonus_sane
  check (key <> 'signup_bonus_credits' or value->>'credits' ~ '^[0-9]{1,9}$');

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hash  text := case when new.email is null then null else md5(lower(new.email)) end;
  v_seen  boolean := false;
  v_bonus integer;
begin
    -- Policy amount. Regex-guarded, clamped, and defaulted to 0 — see header.
    select case
             when c.value->>'credits' ~ '^[0-9]{1,9}$'
               then least(greatest((c.value->>'credits')::int, 0), 50)
               else 0
           end
      into v_bonus
      from public.app_config c
     where c.key = 'signup_bonus_credits';
    v_bonus := coalesce(v_bonus, 0);

    insert into public.profiles (user_id, display_name, referral_code)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
        public.gen_referral_code()
    );

    -- Has this identity been paid a signup bonus before? A null email cannot be
    -- deduped, so it still gets the grant — failing OPEN is correct here: a
    -- missed grant on a legitimate signup costs more than a rare duplicate.
    --
    -- Skipped entirely when the policy pays nothing, so no tombstone is burned
    -- for a grant that never happened.
    if v_hash is not null and v_bonus > 0 then
      select true into v_seen from public.signup_grants where email_hash = v_hash;
      if v_seen then
        v_bonus := 0;
      else
        insert into public.signup_grants (email_hash) values (v_hash)
        on conflict (email_hash) do update
          set grant_count = public.signup_grants.grant_count + 1;
      end if;
    end if;

    -- ALWAYS, including at 0 — wallet_credit raises without this row.
    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, v_bonus, now());

    if v_bonus > 0 then
      insert into public.wallet_transactions (user_id, delta, reason)
      values (new.id, v_bonus, 'signup_bonus');
    end if;

    return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.redeem_referral(p_referee uuid, p_code text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_referrer uuid;
    v_n        integer;
    v_hash     text;
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
    -- re-signup. signup_grants lives outside that cascade and is keyed on the
    -- same md5(lower(email)) as handle_new_user — Apple's private relay
    -- address is stable per (user, app), so it survives deletion.
    --
    -- Fails OPEN on a null email, matching handle_new_user's stated policy: a
    -- blocked redemption for a legitimate user costs more than a rare
    -- duplicate.
    select md5(lower(u.email)) into v_hash from auth.users u where u.id = p_referee;
    if v_hash is not null and exists (
        select 1 from public.signup_grants
         where email_hash = v_hash and referral_redeemed_at is not null
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
        -- INSERT..ON CONFLICT, not a bare UPDATE. handle_new_user is no longer
        -- guaranteed to have created this row: with the signup bonus disabled
        -- (app_config.signup_bonus_credits = 0) it writes no tombstone, because
        -- nothing was paid. A bare UPDATE then matches ZERO rows and silently
        -- succeeds, so the referral guard above finds nothing and the +2/+5 is
        -- farmable by delete-and-re-signup — the exact cascade bug CLAUDE.md
        -- calls the most repeated money bug in this codebase.
        --
        -- Each grant must own its own tombstone. coalesce keeps the FIRST
        -- redemption's timestamp if the row already exists.
        insert into public.signup_grants (email_hash, referral_redeemed_at)
        values (v_hash, now())
        on conflict (email_hash) do update
           set referral_redeemed_at =
                 coalesce(public.signup_grants.referral_redeemed_at, now());
    end if;

    perform public.wallet_credit(p_referee, 2, 'referral_invitee', null, null);
    return 'ok';
end;
$function$
;
