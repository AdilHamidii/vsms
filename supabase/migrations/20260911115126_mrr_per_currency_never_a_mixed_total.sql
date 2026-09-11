-- MRR was a SUM ACROSS CURRENCIES carried by a single arbitrary currency label,
-- and `opsFormat.formatLinesMoney` then converted that whole sum at that one
-- label's FX rate.
--
-- Live values at the moment of this migration make the size of it plain: the
-- mail block summed one NGN subscription (4,900,000 milli = ₦4,900) together
-- with two USD ones (2,990 milli each) into `mrr_milli` 4,902,990, and
-- `mrr_currency` — `select currency ... limit 1`, with no ORDER BY, so it is
-- whichever row Postgres hands back first — said "USD". Rendered, that is
-- "$4,903/mo recurring" against a true figure near six dollars. The line block
-- had the identical shape with INR.
--
-- CLAUDE.md already states the rule this broke: "Mixed currencies are never
-- silently totalled", the same reason /revenue decodes the signed price and
-- storefront per receipt instead of applying a USD ladder. The fix is to stop
-- producing a cross-currency total at all: `mrr_by_currency` is an array, and
-- the caller converts each currency at its own rate. `mrr_milli` and
-- `mrr_currency` are REMOVED rather than left beside it, because a wrong number
-- that still parses is exactly what gets read by the next caller.
--
-- Supersedes the `mrr_milli`/`mrr_currency` half of 20260911115007, applied
-- minutes earlier; the product-family split that migration introduced is
-- carried forward here unchanged.

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
           -- Matched on the product id segment, the same discriminator
           -- `_shared/iap.ts` uses. An id matching NEITHER family lands in
           -- 'other' and is reported nowhere, which is the safe direction: a
           -- new product shows up as missing money rather than being silently
           -- added to whichever family it textually resembles.
           case when tx->>'productId' like '%.line.%' then 'line'
                when tx->>'productId' like '%.mail.%' then 'mail'
                else 'other' end as family
      from pay
      -- The dev account's own test subscriptions are excluded from revenue for
      -- the same reason as everywhere else: they are not customer money. BOTH
      -- subscription tables are checked — checking only `line_subscriptions`
      -- would let a dev mail subscription through into the mail block.
     where coalesce(otx, '') not in (
             select coalesce(original_transaction_id, '')
               from public.line_subscriptions
              where user_id = (select id from dev)
             union all
             select coalesce(original_transaction_id, '')
               from public.email_subscriptions
              where user_id = (select id from dev))
       and coalesce(tx->>'environment', 'Production') = 'Production'
  ),
  -- What will genuinely bill again, per currency and per family. `auto_renew`
  -- is owned by Apple's notifications and a client re-verify never overwrites
  -- it. A yearly plan is divided by 12 to reach a monthly figure; that division
  -- happens INSIDE its own currency, never across a total.
  recur as (
    select 'line' as family, currency,
           sum(case when product_id like '%.yearly' then price_milli / 12.0
                    else price_milli end)::bigint as milli
      from public.line_subscriptions
     where state = 'active' and auto_renew and environment = 'Production'
       and coalesce(price_milli, 0) > 0 and currency is not null
     group by 2
    union all
    select 'mail', currency,
           sum(case when product_id like '%.yearly' then price_milli / 12.0
                    else price_milli end)::bigint
      from public.email_subscriptions
     where state = 'active' and auto_renew and environment = 'Production'
       and coalesce(price_milli, 0) > 0 and currency is not null
     group by 2
  )
  select jsonb_build_object(
    'window_hours', case when p_window is null then null
                         else round(extract(epoch from p_window) / 3600.0, 1) end,

    'by_currency', coalesce((
      select jsonb_agg(jsonb_build_object(
               'currency', c, 'gross_milli', g, 'count', n) order by g desc)
        from (select currency as c, sum(price_milli) as g, count(*)::int as n
                from paid where price_milli > 0 and family = 'line'
               group by 1) t), '[]'::jsonb),

    -- Split so a renewal is visible AS a renewal. "3 payments" hides whether
    -- the business is selling or recurring, which is the single most useful
    -- distinction on this product.
    'payments',   (select count(*)::int from paid
                    where price_milli > 0 and family = 'line'),
    'first_buys', (select count(*)::int from paid
                    where price_milli > 0 and family = 'line'
                      and notification_type = 'SUBSCRIBED'),
    'renewals',   (select count(*)::int from paid
                    where price_milli > 0 and family = 'line'
                      and notification_type = 'DID_RENEW'),
    -- A free trial IS a subscription that paid nothing. Counted apart so
    -- "5 subscribers" can never read as "5 paying subscribers".
    'trials',     (select count(*)::int from paid
                    where price_milli = 0 and family = 'line'),

    'active',   (select count(*)::int from public.line_subscriptions
                  where state = 'active' and environment = 'Production'),
    'renewing', (select count(*)::int from public.line_subscriptions
                  where state = 'active' and auto_renew and environment = 'Production'),
    'mrr_by_currency', coalesce((
      select jsonb_agg(jsonb_build_object('currency', currency, 'milli', milli)
                       order by milli desc)
        from recur where family = 'line'), '[]'::jsonb),

    -- What the numbers cost. A RUN RATE, not settled cash: Telnyx bills per
    -- number per month and we carry the float ~45 days ahead of Apple's payout.
    'numbers_live', (select count(*)::int from public.phone_lines
                      where released_at is null),
    'rent_run_rate_cents', coalesce((
      select sum(monthly_cost_cents)::int from public.phone_lines
       where released_at is null), 0),
    'credit_rented', (select count(*)::int from public.phone_lines
                       where released_at is null and billing = 'credits'),

    -- The temp-e-mail plan: same shape, its own population. Mail has NO
    -- per-number cost to report — the domains it sells addresses on are free,
    -- so there is no equivalent of `rent_run_rate_cents` and none is invented.
    'mail', jsonb_build_object(
      'by_currency', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'currency', c, 'gross_milli', g, 'count', n) order by g desc)
          from (select currency as c, sum(price_milli) as g, count(*)::int as n
                  from paid where price_milli > 0 and family = 'mail'
                 group by 1) t), '[]'::jsonb),
      'payments',   (select count(*)::int from paid
                      where price_milli > 0 and family = 'mail'),
      'first_buys', (select count(*)::int from paid
                      where price_milli > 0 and family = 'mail'
                        and notification_type = 'SUBSCRIBED'),
      'renewals',   (select count(*)::int from paid
                      where price_milli > 0 and family = 'mail'
                        and notification_type = 'DID_RENEW'),
      'trials',     (select count(*)::int from paid
                      where price_milli = 0 and family = 'mail'),
      'active',     (select count(*)::int from public.email_subscriptions
                      where state = 'active' and environment = 'Production'),
      'renewing',   (select count(*)::int from public.email_subscriptions
                      where state = 'active' and auto_renew
                        and environment = 'Production'),
      'mrr_by_currency', coalesce((
        select jsonb_agg(jsonb_build_object('currency', currency, 'milli', milli)
                         order by milli desc)
          from recur where family = 'mail'), '[]'::jsonb)
    )
  );
$$;

revoke all on function public.lines_money_snapshot(interval) from public;
revoke all on function public.lines_money_snapshot(interval) from anon, authenticated;
grant execute on function public.lines_money_snapshot(interval) to service_role;
