-- Backing query for the Telegram /orders command: what actually happened to
-- every order in a window, one row each, plus the totals to read them against.
--
-- Deliberately NOT built on ops_snapshot. That answers "how is the business
-- doing" in aggregate; this answers "show me the individual orders and whether
-- each one worked", which is a different question and needs the per-row detail
-- (route, provider, tier, how long it was held, what we actually paid).
--
-- The dev account is INCLUDED here and flagged `is_dev`, unlike every analytics
-- surface which excludes it. This is an operational view — when the owner places
-- a test order, "did my test order work" is exactly the question being asked,
-- and silently hiding it would look like the order vanished.
--
-- `got_code` is `otp is not null`, never `status = 'received'` — a code rescued
-- after a cancel lives on a `canceled` row (see the late-code rescue). Using
-- status here would report a delivered code as a failure.
create or replace function public.orders_recent(p_window interval default '24 hours')
returns jsonb
language sql
security definer
set search_path to 'public'
as $$
  with o as (
    select
      o.created_at,
      o.status::text                                  as status,
      o.service_id,
      o.country_id,
      coalesce(o.provider, '?')                       as provider,
      o.tier::text                                    as tier,
      o.cost_credits,
      o.actual_cost_cents,
      (o.otp is not null)                             as got_code,
      (o.smspva_number is not null)                   as got_number,
      (o.user_id = '825688de-6117-4251-9f90-93b83b41b572'::uuid) as is_dev,
      extract(epoch from (coalesce(o.closed_at, now()) - o.created_at))::int as held_s
    from public.orders o
    where o.created_at >= now() - p_window
  )
  select jsonb_build_object(
    'total',      (select count(*) from o),
    'numbered',   (select count(*) from o where got_number),
    'delivered',  (select count(*) from o where got_code),
    'waiting',    (select count(*) from o where status = 'waiting'),
    'cancelled',  (select count(*) from o where status = 'canceled'),
    'expired',    (select count(*) from o where status = 'expired'),
    -- Orders that never held a number closed inside create-order (stockout,
    -- margin_too_low, provider fault). They are charge-and-refund events, not
    -- delivery failures, and must be counted apart or they drag the rate down.
    'no_number',  (select count(*) from o where not got_number and status <> 'waiting'),
    'spend_cents',(select coalesce(sum(actual_cost_cents), 0) from o),
    'rows',       (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
                     from o x),
    'email',      (select jsonb_build_object(
                     'total', count(*),
                     'received', count(*) filter (where code is not null))
                   from public.email_orders where created_at >= now() - p_window),
    'esim',       (select jsonb_build_object('total', count(*))
                   from public.esim_orders where created_at >= now() - p_window)
  );
$$;

revoke execute on function public.orders_recent(interval) from public, anon, authenticated;
