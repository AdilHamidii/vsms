-- The second-number line's money, which `/revenue` and `/profit` cannot see.
--
-- 🔴 THE FALSEHOOD THIS FIXES. Subscription purchases are recorded in
-- `line_subscriptions` and NEVER in `iap_receipts`, and `revenue_snapshot`
-- reads only `iap_receipts`. So the one product that bills MONTHLY reports
-- exactly $0 in the owner's revenue command — verified 2026-08-17:
-- `select count(*) from iap_receipts where product_id like '%line%'` = 0, while
-- `line_subscriptions` holds 5 Production rows worth $19.98.
--
-- Same shape as the documented "e-mail is in ops_snapshot but not
-- revenue_snapshot" gap, except on a $9.99–$99.99 product rather than a
-- 1-credit one.
--
-- ⚠️ DELIBERATELY A SEPARATE FUNCTION, not a rewrite of `revenue_snapshot`.
-- That function is ~100 lines of working money arithmetic, and this repo has
-- already had a one-line refactor of a large function silently narrow a
-- watchdog threshold and delete a branch. Adding a caller is reversible;
-- regenerating a money function from `pg_get_functiondef` is how clauses go
-- missing.
--
-- ── Why MRR is the number that matters here ──────────────────────────────
-- Collected revenue answers "what came in". It does NOT answer "what recurs",
-- and on this product those are wildly different: every subscriber so far
-- turned auto-renew off within 16 minutes of paying. Reporting $19.98 without
-- saying that NONE of it renews would be true and deeply misleading — which is
-- precisely the kind of confident-but-wrong figure this command set is being
-- cleaned up to remove. MRR counts only subscriptions that will actually bill
-- again, with a yearly plan divided by 12 rather than counted at face value.

create or replace function public.lines_money_snapshot(p_window interval default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  since as (
    select case when p_window is null then '-infinity'::timestamptz
                else now() - p_window end as t
  ),
  s as (
    select * from public.line_subscriptions
     where environment = 'Production'
       and user_id <> (select id from dev)
       and created_at >= (select t from since)
  )
  select jsonb_build_object(
    'window_hours', case when p_window is null then null
                         else round(extract(epoch from p_window) / 3600.0, 1) end,

    -- What customers actually paid for subscriptions, per currency. Read from
    -- the SIGNED `price_milli` on the transaction, exactly as `revenue_snapshot`
    -- does — never a hardcoded price table, because the store bills by
    -- storefront and a USD ladder would misprice every EUR sale.
    -- Grouped in an inner select: `jsonb_agg(... sum() ...)` is a nested
    -- aggregate and Postgres rejects it outright.
    'by_currency', coalesce((
      select jsonb_agg(jsonb_build_object(
               'currency', c, 'gross_milli', g, 'count', n) order by g desc)
        from (select coalesce(currency, '?') as c,
                     sum(price_milli) as g,
                     count(*)::int as n
                from s where coalesce(price_milli, 0) > 0
               group by 1) t), '[]'::jsonb),

    'purchases', (select count(*)::int from s where coalesce(price_milli,0) > 0),

    -- A free trial is a SUBSCRIPTION that paid nothing. Counted separately so
    -- "5 subscribers" can never be read as "5 paying subscribers".
    'trials', (select count(*)::int from s where coalesce(price_milli,0) = 0),

    -- ── The recurring picture ────────────────────────────────────────────
    -- `auto_renew` is authoritative and owned by Apple's notifications; a
    -- re-verify never overwrites it (see 20260815100000). So this is what will
    -- genuinely bill again, not what was sold once.
    'active', (select count(*)::int from public.line_subscriptions
                where state = 'active' and environment = 'Production'),
    'renewing', (select count(*)::int from public.line_subscriptions
                  where state = 'active' and auto_renew and environment = 'Production'),
    'mrr_milli', coalesce((
      select sum(case when product_id like '%.yearly' then price_milli / 12.0
                      else price_milli end)::bigint
        from public.line_subscriptions
       where state = 'active' and auto_renew and environment = 'Production'
         and coalesce(price_milli, 0) > 0), 0),
    'mrr_currency', (select currency from public.line_subscriptions
                      where state = 'active' and auto_renew
                        and environment = 'Production' and coalesce(price_milli,0) > 0
                      limit 1),

    -- ── What the numbers cost us ─────────────────────────────────────────
    -- Rent is a RUN RATE, not settled cash: Telnyx bills per number per month
    -- and we hold the float ~45 days ahead of Apple's payout. Labelled as such
    -- rather than folded into profit, because a number we cannot verify was
    -- actually charged does not belong in a P&L line.
    'numbers_live', (select count(*)::int from public.phone_lines
                      where released_at is null),
    'rent_run_rate_cents', coalesce((
      select sum(monthly_cost_cents)::int from public.phone_lines
       where released_at is null), 0),
    'credit_rented', (select count(*)::int from public.phone_lines
                       where released_at is null and billing = 'credits')
  );
$$;

revoke execute on function public.lines_money_snapshot(interval)
  from public, anon, authenticated;
