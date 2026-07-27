-- `revoke execute ... from anon, authenticated` IS A NO-OP WHILE PUBLIC HOLDS
-- THE GRANT. This is the missing half of 20260727211000_default_privileges.sql,
-- and revenue_snapshot — the first function created after it — is how it
-- surfaced.
--
-- CREATE FUNCTION grants EXECUTE to PUBLIC by default. anon and authenticated
-- are members of PUBLIC, so they inherit it, and revoking the role-specific
-- grant changes nothing. The ACLs tell the story exactly:
--
--   secured   ops_snapshot   postgres=X/postgres | service_role=X/postgres
--   LEAKING   revenue_snapshot  =X/postgres | postgres=X/postgres | service_role=X/postgres
--                               ^^^^^^^^^^^ empty grantee = PUBLIC
--
-- has_function_privilege('anon', 'revenue_snapshot(interval)', 'execute') was
-- TRUE despite the revoke in the migration that created it — i.e. anyone with
-- the publishable key could POST /rest/v1/rpc/revenue_snapshot and read gross
-- revenue, wholesale cost and profit. The function is SECURITY DEFINER, so RLS
-- would not have saved it.
--
-- 20260727211000 revoked the DEFAULT privileges for anon/authenticated but not
-- for PUBLIC, so every future function would keep arriving publicly callable
-- and every hand-written revoke would keep looking correct while doing nothing.
-- Fixed at the default level below so this cannot recur.

-- 1. The two functions this session introduced.
revoke execute on function public.revenue_snapshot(interval) from public, anon, authenticated;
revoke execute on function public.jws_payload(text)          from public, anon, authenticated;

-- 2. Two pre-existing functions carrying the same default PUBLIC grant.
--    Neither is called by the client — Swift only calls daily_credit_status and
--    claim_daily_credit (WalletAPI.swift), both of which hold EXPLICIT grants
--    and are unaffected. touch_app_config is a trigger function; triggers fire
--    in the table owner's context and do not consult EXECUTE on the caller.
revoke execute on function public.daily_credit_amount(integer) from public, anon, authenticated;
revoke execute on function public.touch_app_config()           from public, anon, authenticated;

-- 3. The root cause: stop FUTURE functions arriving publicly callable.
alter default privileges in schema public revoke execute on functions from public;

-- Verify:
--   select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.prokind='f'
--      and has_function_privilege('anon', p.oid, 'execute');   -- expect 0
