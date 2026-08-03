-- Disable the welcome (signup) credit grant — owner decision 2026-08-03.
--
-- A KILL SWITCH, not a drop, and the amount is a NUMBER rather than a boolean so
-- the 3 -> 5 experiment can be resumed, or any other value tried, with one
-- UPDATE and no migration:
--
--     update public.app_config set value = '{"credits": 5}'::jsonb
--      where key = 'signup_bonus_credits';
--
-- ── Why this is shaped the way it is ────────────────────────────────────────
--
-- `handle_new_user` is a TRIGGER ON auth.users. Anything that raises in here
-- does not fail the grant — it fails SIGNUP, for everyone, with no way to
-- create an account at all. Three consequences, all deliberate below:
--
--  1. The config value is regex-guarded before the cast. `(value->>'credits')::int`
--     RAISES on a non-numeric value, and a raise here takes the product down.
--     Anything that is not a run of digits resolves to 0 instead.
--  2. It FAILS CLOSED. A missing row, a null, or junk all mean 0. Losing the row
--     must never silently resume paying out — the same rule the daily credit
--     kill switch follows (20260801150000).
--  3. The value is clamped to 0..50. A fat-fingered 5000 would otherwise mint
--     credits on every signup, and this path has no other ceiling.
--
-- ── What must NOT change ────────────────────────────────────────────────────
--
-- The wallets row is still inserted UNCONDITIONALLY, at 0. `wallet_credit`
-- raises 'no wallet row for user %', so a user without one cannot be credited
-- at all — their first IAP purchase would fail. This is also why 0 is already a
-- proven-safe value here: the repeat-signup path (v_seen) has always inserted a
-- 0-balance wallet, and those users go on to buy normally.
--
-- No wallet_transactions row is written for a 0 grant, so the ledger invariant
-- sum(delta) = balance still holds exactly (0 = 0).
--
-- ── One semantic change, on purpose ─────────────────────────────────────────
--
-- The `signup_grants` tombstone is now written only when we ACTUALLY PAY. It
-- exists to answer "has this identity been paid a signup bonus before?", and
-- writing it while paying nothing would answer that question wrongly: a user who
-- signed up during the disabled window would be marked already-granted and
-- silently skipped if the grant is ever turned back on. The anti-farming
-- property is unaffected — there is nothing to farm at 0.
--
-- ⚠️ SHIPPED COPY STILL PROMISES CREDITS. OnboardingScreen says "Sign in and
-- you'll find 3 free credits waiting" and HomeScreen says "Your free credits
-- cover this — first number's on us." Both are false at 0 and neither can be
-- changed without a client release. Fix the copy before leaving this off for
-- long, and note 1.8 was in review when this was applied.

insert into public.app_config (key, value)
values ('signup_bonus_credits', '{"credits": 0}'::jsonb)
on conflict (key) do update set value = excluded.value;

create or replace function public.handle_new_user()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_hash  text := case when new.email is null then null else md5(lower(new.email)) end;
  v_seen  boolean := false;
  v_bonus integer;
begin
    -- Policy amount. Regex-guarded, clamped, and defaulted to 0 — see header.
    select case
             when c.value->>'credits' ~ '^[0-9]+$'
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
$function$;
