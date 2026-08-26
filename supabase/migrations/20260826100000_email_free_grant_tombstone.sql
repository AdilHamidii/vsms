-- The temp-e-mail LIFETIME free grant is farmable through Delete Account.
--
-- ── The bug (verified live, 2026-08-26) ─────────────────────────────────────
--
-- `app_config.email_subscription_enforced` is true, so a non-subscriber gets
-- `app_config.email_free_lifetime_grants` (1) free addresses "for life".
-- `begin_email_order` counts that allowance as
--
--     count(*) from email_orders where user_id = p_user
--        and cost_credits = 0 and status <> 'failed'
--
-- and `email_orders.user_id` is ON DELETE CASCADE from `auth.users`. So
-- Delete Account erases the only record that the grant was ever spent, and the
-- next sign-in re-arms the free address. Live evidence: one Apple identity
-- (`signup_grants.email_hash = 89cafbd7611e162449cbb5adf86fa916`) has done
-- exactly this **55 times** — the CREDIT grant caught it because it is
-- tombstoned outside the cascade; the EMAIL grant had no tombstone at all.
--
-- This is the fourth instance of the class CLAUDE.md already names: "EVERY
-- credit grant is farmable through account deletion unless it is tombstoned
-- OUTSIDE the `auth.users` cascade". A free mailbox is a grant. It gets the
-- same treatment as the other three — a table with NO foreign key to
-- `auth.users`, keyed on BOTH the legacy `md5(lower(email))` and the
-- normalized `md5(normalize_email(email))`, exactly as
-- `20260818160000_email_signup_normalized_tombstone.sql` established.
--
-- ── What this does NOT claim ────────────────────────────────────────────────
--
-- A user who owns ten real mailboxes still gets ten free addresses. That is a
-- cost floor, not a wall, and it is the same residual the signup grant states
-- plainly. What is closed is the FREE re-roll: one Apple ID, deleted and
-- re-created, no longer re-arms anything.
--
-- ── Rollback ────────────────────────────────────────────────────────────────
--
--   1. restore the prior `begin_email_order` body verbatim from
--      `supabase/migrations/20260818160001_email_subscriptions.sql` (the live
--      definition at the time of writing is byte-identical to that file), and
--   2. `drop table public.email_free_grants;`
--
-- Nothing else in the product reads the table. The RPC signature and the
-- returned JSON keys are UNCHANGED, so `create-email-order` needs no redeploy
-- either way.

-- ── 1. The tombstone ────────────────────────────────────────────────────────
--
-- 🔴 NO FOREIGN KEY TO auth.users. A reference there is precisely what would
-- delete this row along with the account — which is the bug. Same rule as
-- `signup_grants`, `iap_grants`, `line_subscriptions` and
-- `email_subscriptions`.
--
-- `email_hash` is the primary key and `email_hash_norm` sits beside it, both
-- checked on read. The index on the normalized key is deliberately NOT unique:
-- two live accounts may legitimately normalize to one mailbox (a plus-tag and
-- its base address), and a unique index would make the second account's
-- tombstone INSERT raise inside an order that we have already decided to
-- grant. The read path takes `max(used_count)` across every matching row and
-- the write path increments all of them, so duplicates are counted, not lost.

create table if not exists public.email_free_grants (
  email_hash      text primary key,
  email_hash_norm text,
  used_count      integer not null default 0,
  first_used_at   timestamptz,
  last_used_at    timestamptz
);

comment on table public.email_free_grants is
  'Free temp-e-mail addresses already spent, keyed on the mailbox rather than '
  'the account, so Delete Account cannot re-arm the lifetime allowance. '
  'Deliberately has NO foreign key to auth.users. Added 2026-08-26.';

comment on column public.email_free_grants.email_hash_norm is
  'md5(public.normalize_email(address)). Matched alongside email_hash so a '
  'plus-tag or gmail-dot variant of the same mailbox cannot mint a fresh '
  'allowance. NULL only where the address could not be normalized.';

create index if not exists email_free_grants_norm_idx
  on public.email_free_grants (email_hash_norm)
  where email_hash_norm is not null;

alter table public.email_free_grants enable row level security;
-- RLS is on with NO policy, so even a role holding the table grant reads
-- nothing. Belt and braces: revoke the grant too. Only SECURITY DEFINER
-- functions and the service role touch this.
revoke all on public.email_free_grants from public, anon, authenticated;

-- ── 2. Backfill ─────────────────────────────────────────────────────────────
--
-- Measured 2026-08-26 before writing this: 238 qualifying free orders across
-- 102 live mailboxes, 102 distinct normalized hashes (no collisions today),
-- and ZERO orphaned rows — the cascade means a deleted account's free orders
-- are already gone, so the farmed history is unrecoverable and the 55 replays
-- above cannot be charged retroactively. This backfill therefore protects the
-- CURRENT population going forward; it does not punish anyone who already
-- deleted.
--
-- For every live user it writes exactly the count `begin_email_order` already
-- computes, so no existing account's gate outcome changes on the day this is
-- applied. The only difference is that the count now survives deletion.
--
-- Rolled up by NORMALIZED hash, summing across plus-tag variants, with the
-- oldest account's raw hash taking the primary key — the same `distinct on`
-- collision rule the signup tombstone backfill uses. `do nothing` on conflict
-- so re-applying is inert.

with per_mailbox as (
  select u.email                                   as email,
         md5(lower(u.email))                       as raw_hash,
         md5(public.normalize_email(u.email))      as norm_hash,
         min(u.created_at)                         as user_created_at,
         count(*)::int                             as n,
         min(o.created_at)                         as first_at,
         max(o.created_at)                         as last_at
    from public.email_orders o
    join auth.users u on u.id = o.user_id
   where o.cost_credits = 0
     and o.status <> 'failed'
     and u.email is not null
     and public.normalize_email(u.email) is not null
   group by u.email
), rolled as (
  select norm_hash,
         (array_agg(raw_hash order by user_created_at asc, raw_hash asc))[1] as raw_hash,
         sum(n)::int   as n,
         min(first_at) as first_at,
         max(last_at)  as last_at
    from per_mailbox
   group by norm_hash
)
insert into public.email_free_grants
  (email_hash, email_hash_norm, used_count, first_used_at, last_used_at)
select raw_hash, norm_hash, n, first_at, last_at from rolled
on conflict (email_hash) do nothing;

-- ── 3. The gate ─────────────────────────────────────────────────────────────
--
-- Regenerated from the LIVE definition (`pg_get_functiondef`, read 2026-08-26,
-- byte-identical to 20260818160001). EXACTLY THREE THINGS CHANGE, all of them
-- inside the non-subscriber lifetime branch:
--
--   a. the caller's address is resolved from auth.users and hashed twice;
--   b. the refusal test becomes greatest(per-user order count, tombstone
--      used_count matched on EITHER hash) >= grants;
--   c. granting a free address increments/inserts the tombstone, in this same
--      transaction.
--
-- UNCHANGED, deliberately and clause by clause: the argument list and every
-- returned key (`create-email-order` parses ok/reason/order_id/cap/used/
-- grants and is not redeployed by this migration), the bad_request guard, the
-- per-user advisory lock, the 2-minute duplicate check, the
-- `email_subscription_enforced` read and its fail-closed coalesce, the ENTIRE
-- pre-flip per-UTC-day branch, the ENTIRE subscriber daily-cap branch, the
-- order INSERT, the paid (gmail) wallet_spend path and its ledger stitch.
--
-- ⚠️ FAILS OPEN on an address we cannot resolve or normalize — no email, no
-- tombstone, and the per-user count alone decides. Same policy the other three
-- grants state: a missed grant on a legitimate signup costs more than a rare
-- duplicate. A tombstone is never written for an address we could not key.
create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text, p_credits integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existing uuid; v_order uuid; v_ok boolean;
  v_free_ever integer; v_grants integer;
  v_today integer; v_cap integer;
  v_enforced boolean;
  v_email text; v_raw text; v_norm text;
  v_tombstoned integer; v_used integer; v_rows integer;
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

    if not v_enforced then
      -- PRE-2.2 BEHAVIOUR, deliberately byte-identical to what shipped: N free
      -- addresses per UTC day, refused as `free_limit_reached`. Do not "tidy"
      -- this branch away — it is what keeps the live 2.1 build working while
      -- the subscription ships dark.
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
      -- Subscribed. Free domains cost us nothing, but the inventory is scarce
      -- and SHARED — one looping subscriber could drain it for every user. A
      -- stated hard stop, not a throttle.
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
      -- Not subscribed: a LIFETIME allowance, counted over all history.
      -- `status <> 'failed'` is retained from the old daily rule — an order
      -- that never provisioned a mailbox is not a grant.
      select greatest(0, least(50, coalesce((value #>> '{}')::integer, 1)))
        into v_grants from public.app_config
       where key = 'email_free_lifetime_grants';
      v_grants := coalesce(v_grants, 1);
      select count(*) into v_free_ever from public.email_orders
       where user_id = p_user and cost_credits = 0 and status <> 'failed';

      -- 🔴 THE ROW COUNT ABOVE CASCADES WITH THE ACCOUNT. It is what made this
      -- allowance re-rollable 55 times from one Apple identity. The tombstone
      -- below does not cascade, so it is the half that actually holds; the row
      -- count is kept because it is authoritative WITHIN an account (it sees
      -- orders placed a second ago, and it needs no address at all).
      v_email := null;
      begin
        select u.email into v_email from auth.users u where u.id = p_user;
      exception when others then
        v_email := null;   -- fail OPEN: never refuse an order over a read we
      end;                 -- could not perform.

      if v_email is not null and public.normalize_email(v_email) is not null then
        v_raw  := md5(lower(v_email));
        v_norm := md5(public.normalize_email(v_email));
        -- Serialise on the MAILBOX, not the account. The per-user lock taken
        -- at the top does not serialise two DIFFERENT user ids sharing one
        -- inbox, which is the exact race this migration exists to close.
        -- Always taken after the per-user lock, so the ordering is consistent
        -- and cannot deadlock against another caller of this function.
        perform pg_advisory_xact_lock(hashtext('email_free_grant:' || v_norm));
        select coalesce(max(used_count), 0) into v_tombstoned
          from public.email_free_grants
         where email_hash = v_raw or email_hash_norm = v_norm;
      else
        v_raw := null; v_norm := null; v_tombstoned := 0;
      end if;

      v_used := greatest(coalesce(v_free_ever, 0), coalesce(v_tombstoned, 0));
      if v_used >= v_grants then
        return jsonb_build_object('ok', false, 'reason', 'subscription_required',
                                  'used', v_used, 'grants', v_grants);
      end if;

      -- Granting. Burn the tombstone in THIS transaction, so a failure
      -- anywhere below rolls the record back with the order rather than
      -- charging the user an allowance they never received.
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

-- ── 4. Privileges ───────────────────────────────────────────────────────────
-- The `public` half is the one that matters: CREATE FUNCTION grants EXECUTE to
-- PUBLIC by default and anon/authenticated are members, so revoking only those
-- two changes nothing at all. `create or replace` does not reset an existing
-- ACL, but restate it so a from-scratch replay is secured too.
revoke execute on function public.begin_email_order(uuid, text, text, text, integer)
  from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon',
       'public.begin_email_order(uuid, text, text, text, integer)', 'execute') then
    raise exception 'begin_email_order is callable by anon';
  end if;
  if has_table_privilege('anon', 'public.email_free_grants', 'select') then
    raise exception 'email_free_grants is readable by anon';
  end if;
  if has_table_privilege('authenticated', 'public.email_free_grants', 'select') then
    raise exception 'email_free_grants is readable by authenticated';
  end if;
  -- The tombstone is worthless if it can be deleted with the account.
  if exists (
    select 1 from pg_constraint
     where conrelid = 'public.email_free_grants'::regclass and contype = 'f'
  ) then
    raise exception 'email_free_grants has a foreign key — it must not cascade';
  end if;
end $$;
