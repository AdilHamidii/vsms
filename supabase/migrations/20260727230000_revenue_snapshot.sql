-- revenue_snapshot(interval) — money in, money out, for the /revenue bot command.
--
-- WHY THIS READS APPLE'S SIGNED PAYLOAD RATHER THAN A PRICE TABLE
--
-- iap_receipts stores product_id but no price, so the obvious implementation is
-- a product -> USD map next to PRODUCT_TO_CREDITS in _shared/iap.ts. That is
-- wrong, and measurably so: the live store charges by STOREFRONT, and ours is
-- not one price.
--
--   credits.12  $4.99 USA   vs  EUR 5.99 FRA
--   credits.30  $11.99 USA  vs  EUR 12.99 ESP/FRA
--
-- Purchases so far span USA, FRA, ESP, SVK and BGR in two currencies. A
-- hardcoded USD ladder would have overstated US revenue by ~17% and silently
-- mispriced every EUR sale. (Note CLAUDE.md's documented ladder — $5.99/$12.99
-- — is the EUR tier, not what a US buyer is charged.)
--
-- Apple's JWS transaction payload carries `price` (in MILLIUNITS, so 4990 =
-- 4.99), `currency` and `storefront`. That is the amount actually billed, it is
-- signed, and it self-corrects when prices change in App Store Connect. We
-- already persist the whole JWS in raw_jws, so this costs one base64url decode
-- per receipt and no new writes.
--
-- Currency conversion is deliberately NOT done here. The function returns
-- per-currency subtotals; the caller applies FX and shows the rate it used, so
-- a mixed-currency total can never masquerade as an exact figure.
--
-- Sandbox/Xcode receipts are excluded — they are genuine Apple-signed
-- transactions that cost the buyer $0 (see the iap-verify gate in CLAUDE.md).
-- ops_snapshot's `buys` does NOT filter environment and therefore counts the
-- one Sandbox receipt as a purchase; this function does not repeat that.

-- Safe base64url -> jsonb. A single malformed or truncated raw_jws must not
-- take down the operator's revenue command, so decode failures return null and
-- are counted as `unpriced` rather than raised.
create or replace function public.jws_payload(p_jws text)
returns jsonb
language plpgsql
immutable
as $$
declare part text;
begin
  if p_jws is null then return null; end if;
  part := split_part(p_jws, '.', 2);
  if part = '' then return null; end if;
  return convert_from(
    decode(translate(part, '-_', '+/') ||
           repeat('=', (4 - length(part) % 4) % 4), 'base64'), 'UTF8')::jsonb;
exception when others then
  return null;
end;
$$;

revoke execute on function public.jws_payload(text) from anon, authenticated;

-- p_window null = lifetime.
create or replace function public.revenue_snapshot(p_window interval default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  since as (
    select case when p_window is null then '-infinity'::timestamptz
                else now() - p_window end as t
  ),
  rc as (
    select r.user_id, r.granted_credits,
           replace(r.product_id, 'com.anthersystems.VirtualSIM.', '') as product,
           public.jws_payload(r.raw_jws) as j
    from public.iap_receipts r
    where r.environment = 'Production'
      and r.user_id <> (select id from dev)
      and r.created_at >= (select t from since)
  ),
  cur as (
    select coalesce(j->>'currency', '?') as currency,
           sum((j->>'price')::numeric)   as gross_milli,
           count(*)::int                 as n
    from rc where j->>'price' is not null
    group by 1
  ),
  prod as (
    select product, count(*)::int as n, coalesce(sum(granted_credits),0)::int as credits
    from rc group by 1
  ),
  -- SMS wholesale. `untracked` counts orders that DID reserve a number (so we
  -- really paid for it) but carry no actual_cost_cents — 50 such orders exist
  -- before 2026-07-13, when cost recording started. Orders that never got a
  -- number are correctly excluded: nothing was reserved, nothing was paid.
  sms as (
    select coalesce(sum(actual_cost_cents), 0)::int as cents,
           count(*) filter (where actual_cost_cents is not null)::int as tracked,
           count(*) filter (where actual_cost_cents is null
                              and smspva_number is not null)::int as untracked
    from public.orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  esm as (
    select coalesce(sum(actual_cost_cents), 0)::int as cents,
           count(*) filter (where actual_cost_cents is not null)::int as tracked,
           count(*) filter (where actual_cost_cents is null
                              and status <> 'failed')::int as untracked
    from public.esim_orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  -- The dev account buys no credits but its orders spend real provider money.
  -- Broken out so it is subtracted from cash profit without being mistaken for
  -- a cost of serving customers.
  devc as (
    select
      coalesce((select sum(actual_cost_cents) from public.orders
                 where created_at >= (select t from since)
                   and user_id = (select id from dev)), 0)::int
    + coalesce((select sum(actual_cost_cents) from public.esim_orders
                 where created_at >= (select t from since)
                   and user_id = (select id from dev)), 0)::int as cents
  )
  select jsonb_build_object(
    'lifetime',     p_window is null,
    'window_hours', case when p_window is null then null
                         else round(extract(epoch from p_window) / 3600.0, 1) end,
    'since',        case when p_window is null then null
                         else (select t from since) end,
    'revenue', jsonb_build_object(
      'by_currency', coalesce((select jsonb_agg(jsonb_build_object(
                        'currency', currency, 'gross_milli', gross_milli, 'count', n)
                        order by gross_milli desc) from cur), '[]'::jsonb),
      'by_product',  coalesce((select jsonb_agg(jsonb_build_object(
                        'product', product, 'count', n, 'credits', credits)
                        order by product) from prod), '[]'::jsonb),
      'purchases',   (select count(*)::int from rc),
      'buyers',      (select count(distinct user_id)::int from rc),
      'credits',     (select coalesce(sum(granted_credits),0)::int from rc),
      'unpriced',    (select count(*)::int from rc where j->>'price' is null)
    ),
    'cost', jsonb_build_object(
      'sms_cents',      (select cents from sms),
      'sms_tracked',    (select tracked from sms),
      'sms_untracked',  (select untracked from sms),
      'esim_cents',     (select cents from esm),
      'esim_tracked',   (select tracked from esm),
      'esim_untracked', (select untracked from esm),
      'dev_cents',      (select cents from devc)
    )
  );
$$;

revoke execute on function public.revenue_snapshot(interval) from anon, authenticated;
