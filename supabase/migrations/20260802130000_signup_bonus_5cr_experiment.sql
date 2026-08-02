-- Signup bonus 3 -> 5 credits: a ONE-WEEK EXPERIMENT (owner decision,
-- 2026-08-02), to test whether starter-grant reach is what kills activation.
--
-- The hypothesis it tests: 74% of signups never place an order and leave with
-- their free credits untouched. Reason #2 on the shortlist is that 3 credits
-- cannot reach what they came for (median route ~16 cr). At 5 credits the
-- grant reaches 3,721 active routes across 247 of 265 services, vs 2,299/227
-- at 3 (measured 2026-08-02, post-repricing catalog).
--
-- EVALUATE ~2026-08-09: signup -> first-order rate vs the baselines —
-- 26% (7d to 08-02) and 21.7% (lifetime). Revert = this same migration with
-- v_bonus := 3. Delivery in the 4-5 credit band measured 53.8% over 30d
-- (best-evidenced band above 3), so the extra reach is not junk inventory.
--
-- Cost exposure: worst case ~$0.10-0.12 wholesale per signup at ~65
-- signups/week if every grant were fully spent — bounded and small.
--
-- History: 1 cr (20260721130000) produced a 0%-conversion funnel; 5 cr
-- briefly (20260726130000); 3 cr (20260726140000) since. The tombstone
-- (signup_grants, email-hash, outside the auth cascade) is untouched — the
-- experiment changes the AMOUNT only, so account-delete-and-resignup still
-- cannot re-mint it.
--
-- Body reproduced verbatim from live pg_get_functiondef 2026-08-02; the ONLY
-- change is v_bonus 3 -> 5 (the clause-by-clause diff rule, by construction).

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_hash  text := case when new.email is null then null else md5(lower(new.email)) end;
  v_seen  boolean := false;
  v_bonus integer := 5;
begin
    insert into public.profiles (user_id, display_name, referral_code)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
        public.gen_referral_code()
    );

    -- Has this identity been paid a signup bonus before? A null email cannot be
    -- deduped, so it still gets the grant — failing OPEN is correct here: a
    -- missed grant on a legitimate signup costs more than a rare duplicate.
    if v_hash is not null then
      select true into v_seen from public.signup_grants where email_hash = v_hash;
      if v_seen then
        v_bonus := 0;
      else
        insert into public.signup_grants (email_hash) values (v_hash)
        on conflict (email_hash) do update
          set grant_count = public.signup_grants.grant_count + 1;
      end if;
    end if;

    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, v_bonus, now());

    if v_bonus > 0 then
      insert into public.wallet_transactions (user_id, delta, reason)
      values (new.id, v_bonus, 'signup_bonus');
    end if;

    return new;
end;
$function$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;
