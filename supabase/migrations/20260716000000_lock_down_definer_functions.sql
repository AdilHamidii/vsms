-- SECURITY (critical): these SECURITY DEFINER functions were callable straight
-- from the REST API by anon/authenticated clients that hold the publishable key
-- (which ships in the app). Two were directly exploitable:
--
--   * wallet_credit(...)      — no internal auth check, arbitrary p_user/p_amount
--                               ⇒ anyone could mint unlimited credits for anyone.
--   * private_cron_secret()   — returns the vault cron_secret in plaintext
--                               ⇒ anyone could read the secret gating the cron
--                                 relays (poll-active-orders, sync-prices, winback).
--
-- expire_order / wallet_spend / winback_candidates / handle_new_user were also
-- reachable (griefing / enumeration). All six are only ever invoked by the edge
-- functions via the service_role key, which bypasses REST EXECUTE grants, and
-- handle_new_user runs as an AFTER-INSERT trigger (also independent of grants),
-- so revoking public execute breaks nothing.
--
-- NB: revoking from anon/authenticated alone is NOT enough — Postgres grants
-- function EXECUTE to PUBLIC by default, and anon/authenticated inherit it via
-- PUBLIC. (That is exactly why the prior winback_candidates revoke, which only
-- named anon/authenticated, left the function wide open.) We revoke PUBLIC too.

revoke execute on function
  public.wallet_credit(uuid, integer, public.wallet_reason, uuid, bigint)
  from public, anon, authenticated;

revoke execute on function
  public.wallet_spend(uuid, integer, public.wallet_reason, uuid)
  from public, anon, authenticated;

revoke execute on function
  public.expire_order(uuid)
  from public, anon, authenticated;

revoke execute on function
  public.private_cron_secret()
  from public, anon, authenticated;

revoke execute on function
  public.winback_candidates(integer)
  from public, anon, authenticated;

revoke execute on function
  public.handle_new_user()
  from public, anon, authenticated;
