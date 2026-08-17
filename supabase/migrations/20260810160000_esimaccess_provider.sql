-- eSIM provider switch: SMSPool → eSIM Access (2026-08-10).
--
-- The eSIM line stays PAUSED (app_config.esim_paused = true) through this
-- migration and the function deploys — that is what makes the window race-free:
-- create-esim-order refuses every plan while nothing is 'active', so nothing
-- can order against a half-deployed stack.
--
-- Old SMSPool esim_plans rows (numeric ids) are KEPT, hidden, forever:
-- esim_orders.plan_id FKs them and historical orders resolve display names
-- from the catalog. New plan ids are 'ea:<packageCode>' — collision-proof
-- against the numeric SMSPool ids (the esim_plans PK landmine).
--
-- Accepted debt, deliberate: ops_snapshot still reads app_config.smspool_health
-- as smspool_usd, which has had no writer since the SMS surface was deleted —
-- it stays null/stale. Editing ops_snapshot means regenerating a SECURITY
-- DEFINER function under the pg_get_functiondef/clause-diff rule for zero user
-- value; /balance + the minutely pager carry eSIM Access monitoring instead.

-- 1. Provider-keyed columns on esim_orders. smspool_tx stays for the 12 legacy
--    rows (check-esim-usage routes on `provider` and serves them verbatim).
--    ea_tran_no is the provider's STABLE per-eSIM key (ICCIDs are reused).
--    The shipped client fetches esim_orders with select=* and ignores unknown
--    keys, so new columns are invisible to it.
alter table public.esim_orders
  add column if not exists ea_order_no text,
  add column if not exists ea_tran_no  text,
  add column if not exists iccid       text;

-- Mirror esim_orders_smspool_tx_key: one order row per provider order/profile.
-- (No code path uses ON CONFLICT against these — they are integrity backstops,
-- so the partial-index-needs-predicate trap does not apply.)
create unique index if not exists esim_orders_ea_order_no_once
  on public.esim_orders (ea_order_no) where ea_order_no is not null;
create unique index if not exists esim_orders_ea_tran_no_once
  on public.esim_orders (ea_tran_no) where ea_tran_no is not null;

-- 2. begin_esim_order — byte-identical to 20260727200000 EXCEPT the insert
--    stamps provider = 'esimaccess'. Without this every new order would carry
--    the column default 'smspool' and check-esim-usage would route it down the
--    LEGACY path (create-esim-order also writes provider explicitly on its
--    first post-purchase update, as belt-and-braces for deploy-window skew).
create or replace function public.begin_esim_order(
  p_user uuid, p_plan text, p_credits integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order uuid;
  v_ok    boolean;
begin
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  -- Same-plan dedupe: a double-tap must not buy two eSIMs.
  if exists (
    select 1 from public.esim_orders o
    where o.user_id = p_user and o.plan_id = p_plan
      and o.created_at >= now() - interval '2 minutes'
      and o.status in ('provisioning', 'installed', 'active')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  insert into public.esim_orders (user_id, plan_id, cost_credits, status, provider)
  values (p_user, p_plan, p_credits, 'provisioning', 'esimaccess')
  returning id into v_order;

  select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
  if not coalesce(v_ok, false) then
    delete from public.esim_orders where id = v_order;
    return jsonb_build_object('ok', false, 'reason', 'insufficient');
  end if;

  -- Attach the spend to its order so the ledger reconciles. wallet_spend has no
  -- esim-aware overload, so stamp the row it just wrote.
  update public.wallet_transactions
     set esim_order_id = v_order
   where id = (
     select id from public.wallet_transactions
      where user_id = p_user and reason = 'spend' and esim_order_id is null
        and order_id is null
      order by created_at desc limit 1);

  return jsonb_build_object('ok', true, 'order_id', v_order);
end;
$function$;

-- CREATE OR REPLACE preserves the existing ACL, but restate the revoke anyway:
-- a function that leaks to PUBLIC is the trap 20260727240000 closed, and the
-- restatement is free.
revoke execute on function public.begin_esim_order(uuid, text, integer)
  from public, anon, authenticated;

-- 3. Resurrection guard. set_esim_paused(false) — the /esim on the owner will
--    eventually run — re-activates hidden rows with retail_credits non-null
--    AND last_checked_at >= now() - interval '3 days'. The new sync stamps
--    only 'ea:' rows, but if the owner resumes within 3 days of the LAST
--    SMSPool-era sync run, the old rows would still qualify and come back on
--    sale against a provider with no code path. Nulling the stamp makes them
--    permanently ineligible; the rows themselves are kept (FK target +
--    historical display).
update public.esim_plans set last_checked_at = null where id not like 'ea:%';
