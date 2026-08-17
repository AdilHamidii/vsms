-- Subscription revenue counted PER PAYMENT, including renewals.
--
-- 🔴 THE BUG IN MY OWN FIRST VERSION. 20260817140000 summed
-- `line_subscriptions.price_milli`, and that table holds ONE ROW PER
-- SUBSCRIPTION. A renewal updates that row, it does not add one — so a
-- subscriber who renews twelve times would still contribute a single $9.99 and
-- the lifetime figure would be understated by the entire renewal history. It
-- happened to look right today only because nothing has renewed yet: all five
-- subscribers cancelled auto-renew within 16 minutes of paying.
--
-- The correct source is the NOTIFICATION STREAM. Apple sends one signed event
-- per payment — `SUBSCRIBED` for the first, `DID_RENEW` for each renewal — and
-- `line_notifications.raw_payload` keeps every one with its own signed price.
-- That is exactly what `iap_receipts` is for consumables: a row per payment,
-- never a row per product.
--
-- Verified by decoding the live rows: 3 × yearly at price 0 (free trials) and
-- 2 × monthly at 9990 milli = $19.98, which matches what was actually taken.
--
-- ⚠️ The price is read from the SIGNED transaction, never from a price table.
-- The store bills by storefront — `credits.12` is $4.99 in the USA and €5.99 in
-- France — so a hardcoded ladder would misprice every non-USD sale. Same rule
-- `revenue_snapshot` already follows.

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
  -- One row per PAYMENT EVENT. `SUBSCRIBED` is the first charge, `DID_RENEW`
  -- every subsequent one; both carry their own signed price, so this sums
  -- correctly across renewals and across price changes.
  pay as (
    select n.notification_type,
           (public.jws_payload(
              public.jws_payload(n.raw_payload)->'data'->>'signedTransactionInfo')) as tx,
           n.original_transaction_id as otx
      from public.line_notifications n
     where n.notification_type in ('SUBSCRIBED', 'DID_RENEW')
       and n.created_at >= (select t from since)
  ),
  paid as (
    select notification_type,
           coalesce(tx->>'currency', '?') as currency,
           coalesce((tx->>'price')::numeric, 0) as price_milli,
           tx->>'productId' as product
      from pay
      -- The dev account's own test subscriptions are excluded from revenue for
      -- the same reason as everywhere else: they are not customer money.
     where coalesce(otx, '') not in (
             select coalesce(original_transaction_id, '')
               from public.line_subscriptions
              where user_id = (select id from dev))
       and coalesce(tx->>'environment', 'Production') = 'Production'
  )
  select jsonb_build_object(
    'window_hours', case when p_window is null then null
                         else round(extract(epoch from p_window) / 3600.0, 1) end,

    'by_currency', coalesce((
      select jsonb_agg(jsonb_build_object(
               'currency', c, 'gross_milli', g, 'count', n) order by g desc)
        from (select currency as c, sum(price_milli) as g, count(*)::int as n
                from paid where price_milli > 0
               group by 1) t), '[]'::jsonb),

    -- Split so a renewal is visible AS a renewal. "3 payments" hides whether
    -- the business is selling or recurring, which is the single most useful
    -- distinction on this product.
    'payments',   (select count(*)::int from paid where price_milli > 0),
    'first_buys', (select count(*)::int from paid
                    where price_milli > 0 and notification_type = 'SUBSCRIBED'),
    'renewals',   (select count(*)::int from paid
                    where price_milli > 0 and notification_type = 'DID_RENEW'),
    -- A free trial IS a subscription that paid nothing. Counted apart so
    -- "5 subscribers" can never read as "5 paying subscribers".
    'trials',     (select count(*)::int from paid where price_milli = 0),

    -- ── What recurs ──────────────────────────────────────────────────────
    -- `auto_renew` is owned by Apple's notifications and a client re-verify
    -- never overwrites it, so this is what will genuinely bill again.
    'active',   (select count(*)::int from public.line_subscriptions
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

    -- ── What the numbers cost ────────────────────────────────────────────
    -- A RUN RATE, not settled cash: Telnyx bills per number per month and we
    -- carry the float ~45 days ahead of Apple's payout.
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
