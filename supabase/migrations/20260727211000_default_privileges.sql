-- MUST BE RUN AS THE GRANTOR (postgres / supabase_admin), not via
-- `supabase db query --linked`, which mints a temp login role and fails with
-- "42501: permission denied to change default privileges". Run it from the
-- Supabase SQL editor, or via the Supabase MCP apply_migration tool.
--
-- ── S2. Default privileges: the highest-leverage fix in this file.
--
-- anon and authenticated currently hold `arwdDxtm` (INSERT/SELECT/UPDATE/DELETE/
-- TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) on every FUTURE table in public, and
-- EXECUTE on every FUTURE function. So the next migration that adds a table and
-- forgets `enable row level security` ships a world-readable AND world-WRITABLE
-- table at /rest/v1/<table>, and the next SECURITY DEFINER function that forgets
-- its `revoke` is callable at /rest/v1/rpc/<name>.
--
-- That is not hypothetical: it is exactly how run_watchdog became publicly
-- callable. The codebase compensates with 64 hand-written `revoke execute`
-- lines across 35 migrations — discipline as the only control, one omission
-- from a breach.
--
-- SELECT is deliberately retained: the catalog tables (services, countries,
-- routes, esim_plans) rely on it, and RLS still governs row visibility.
alter default privileges in schema public
  revoke insert, update, delete, truncate on tables from anon, authenticated;
alter default privileges in schema public
  revoke execute on functions from anon, authenticated;
alter default privileges for role supabase_admin in schema public
  revoke insert, update, delete, truncate on tables from anon, authenticated;
alter default privileges for role supabase_admin in schema public
  revoke execute on functions from anon, authenticated;

