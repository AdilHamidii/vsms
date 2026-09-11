-- /revenue and /profit reported MAIL subscription money as LINE money.
--
-- `line_notifications` is a misnomer: Apple posts EVERY product there — credit
-- packs, line subscriptions and mail subscriptions alike. `lines_money_snapshot`
-- selected `notification_type in ('SUBSCRIBED','DID_RENEW')` with no product
-- filter at all, so every mail.monthly / mail.yearly payment was counted into
-- `payments`, `first_buys`, `renewals` and `by_currency` and then rendered under
-- the "📞 Second numbers" heading. Measured 2026-09-11: 28 line payment events
-- against 15 mail ones, so more than a third of what that block reported as the
-- second-number business was the $2.99 mail plan.
--
-- Meanwhile `active`, `renewing` and `mrr_milli` read `line_subscriptions`
-- directly and were correctly line-only — so the block mixed two populations in
-- one panel and the two halves could never be reconciled against each other.
--
-- This is the SQL instance of the rule CLAUDE.md already states for TypeScript:
-- `subscriptionFamily(productId)` must resolve to "line" or "mail" and must
-- never be treated as a single yes/no. Top-level keys are now line-only; mail
-- gets its own object of the same shape. Nothing is dropped — the grand total
-- across both blocks is unchanged, only its attribution.
--
-- `other` (credit packs, which are ONE_TIME_CHARGE and never SUBSCRIBED /
-- DID_RENEW) is computed but deliberately not returned: /revenue already reads
-- pack money from `revenue_snapshot`, and returning it here would double-count
-- it if a future caller summed the blocks.

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
           tx->>'productId' as product,
           -- Matched on the product id segment, the same discriminator
           -- `_shared/iap.ts` uses. An id that matches NEITHER family lands in
           -- 'other' and is reported nowhere, which is the safe direction: a
           -- new product shows up as missing money rather than being silently
           -- added to whichever family it textually resembles.
           case when tx->>'productId' like '%.line.%' then 'line'
                when tx->>'productId' like '%.mail.%' then 'mail'
                else 'other' end as family
      from pay
      -- The dev account's own test subscriptions are excluded from revenue for
      -- the same reason as everywhere else: they are not customer money. Both
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
                       where released_at is null and billing = 'credits'),

    -- ── The temp-e-mail plan, same shape, its own population ─────────────
    -- Mail has NO per-number cost to report: the domains it sells addresses on
    -- are free, so there is no equivalent of `rent_run_rate_cents` and none is
    -- invented here.
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
      'mrr_milli', coalesce((
        select sum(case when product_id like '%.yearly' then price_milli / 12.0
                        else price_milli end)::bigint
          from public.email_subscriptions
         where state = 'active' and auto_renew and environment = 'Production'
           and coalesce(price_milli, 0) > 0), 0),
      'mrr_currency', (select currency from public.email_subscriptions
                        where state = 'active' and auto_renew
                          and environment = 'Production'
                          and coalesce(price_milli,0) > 0
                        limit 1)
    )
  );
$$;

-- `create or replace` preserves the existing ACL, so the SECURITY DEFINER
-- exposure is unchanged. Asserted rather than assumed — see CLAUDE.md on
-- `revoke execute … from anon` being a no-op while PUBLIC holds the grant.
revoke all on function public.lines_money_snapshot(interval) from public;
revoke all on function public.lines_money_snapshot(interval) from anon, authenticated;
grant execute on function public.lines_money_snapshot(interval) to service_role;
