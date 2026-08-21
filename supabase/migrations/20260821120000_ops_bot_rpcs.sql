begin;

-- ops bot RPCs (2026-08-21) — six read-only snapshot functions backing the
-- Telegram command overhaul: /trials /failures /support /now /lines /route.
--
-- All are SECURITY DEFINER + STABLE + search_path pinned, and all are revoked
-- from PUBLIC (CREATE FUNCTION grants EXECUTE to PUBLIC by default, and
-- anon/authenticated are members of PUBLIC — revoking only from those two
-- roles is a no-op; see CLAUDE.md).
--
-- Dev-account exclusion predicate is copied verbatim from ops_snapshot:
--   user_id <> '825688de-6117-4251-9f90-93b83b41b572'::uuid
--
-- ⚠️ `public.orders` HAS NO CLOSE-REASON / ERROR COLUMN. Columns are:
--   id user_id service_id country_id smspva_id smspva_number cost_credits
--   status otp raw_message created_at expires_at arrived_at closed_at provider
--   actual_cost_cents smspool_pool tier late_watch_until route_physical_count
--   operator_used pool_rate_pct pool_pinned from_default late_release_attempts
-- So ops_failures cannot report WHY an order never got a number. Measured
-- 2026-08-21 over 30 days: every numberless order is status='canceled' with
-- actual_cost_cents null and cost_credits > 0 (charged then refunded), i.e.
-- stockout / margin_too_low / provider fault are indistinguishable at the row
-- level. The `reasons` array therefore carries ONE derived bucket,
-- 'no_numbers_available', and says so. Do not read it as a provider verdict.

-- ---------------------------------------------------------------------------
-- ops_trials() — subscription conversion timeline (line + mail families)
-- ---------------------------------------------------------------------------
create or replace function public.ops_trials()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
raw as (
  select 'line'::text as family, s.original_transaction_id, s.user_id,
         s.product_id, s.state::text as state, s.auto_renew, s.environment,
         s.price_milli, s.currency, s.storefront,
         s.created_at as started_at, s.expires_at, s.grace_expires_at
    from public.line_subscriptions s
   where s.user_id is distinct from (select id from dev)
  union all
  select 'mail'::text, s.original_transaction_id, s.user_id,
         s.product_id, s.state::text, s.auto_renew, s.environment,
         s.price_milli, s.currency, s.storefront,
         s.created_at, s.expires_at, s.grace_expires_at
    from public.email_subscriptions s
   where s.user_id is distinct from (select id from dev)
),
-- Recently-lapsed subs are shown too (flagged by state), per the contract.
win as (
  select * from raw
   where greatest(expires_at, coalesce(grace_expires_at, expires_at))
         > now() - interval '30 days'
),
prod as (
  select w.*,
         replace(w.product_id, 'com.anthersystems.VirtualSIM.', '') as product_short
    from win w
),
enriched as (
  select p.*,
         (p.price_milli = 0
          and p.state in ('active','grace')
          and p.product_short like '%.yearly') as is_trial,
         (p.auto_renew
          and p.state in ('active','grace')
          and now() < p.expires_at) as converts,
         case
           when p.price_milli > 0 then p.price_milli
           when p.product_short = 'line.yearly'  then 99990
           when p.product_short = 'line.monthly' then  9990
           when p.product_short = 'mail.yearly'  then 29990
           when p.product_short = 'mail.monthly' then  2990
           else null
         end::bigint as expected_gross_milli
    from prod p
),
joined as (
  select e.*, l.e164 as line_e164, l.status::text as line_status
    from enriched e
    left join lateral (
      select pl.e164, pl.status from public.phone_lines pl
       where e.family = 'line'
         and pl.original_transaction_id = e.original_transaction_id
       order by pl.created_at desc limit 1
    ) l on true
   where e.environment = 'Production'
),
sandbox as (
  select count(*)::int n from enriched where environment <> 'Production'
),
by_cur as (
  select currency, sum(expected_gross_milli)::bigint gross_milli
    from joined
   where converts and expires_at <= now() + interval '7 days'
   group by 1 order by 2 desc
)
select jsonb_build_object(
  'now', to_jsonb(now()),
  'subs', coalesce((
    select jsonb_agg(jsonb_build_object(
      'original_transaction_id', j.original_transaction_id,
      'user_id', j.user_id,
      'product', j.product_short,
      'family', j.family,
      'state', j.state,
      'auto_renew', j.auto_renew,
      'is_trial', j.is_trial,
      'price_milli', j.price_milli,
      'currency', j.currency,
      'storefront', j.storefront,
      'started_at', to_jsonb(j.started_at),
      'expires_at', to_jsonb(j.expires_at),
      'grace_expires_at', to_jsonb(j.grace_expires_at),
      'line_e164', j.line_e164,
      'line_status', j.line_status,
      'converts', j.converts,
      'expected_gross_milli', j.expected_gross_milli
    ) order by j.expires_at asc) from joined j), '[]'::jsonb),
  'summary', jsonb_build_object(
    'trials_on',  (select count(*)::int from joined where is_trial and auto_renew),
    'trials_off', (select count(*)::int from joined where is_trial and not auto_renew),
    'paid_active',(select count(*)::int from joined
                    where not is_trial and state in ('active','grace') and expires_at > now()),
    'next_event_at', (select to_jsonb(min(expires_at)) from joined where expires_at > now()),
    'expected_gross_milli_7d', coalesce((select sum(expected_gross_milli)::bigint from joined
       where converts and expires_at <= now() + interval '7 days'), 0),
    'by_currency_7d', coalesce((select jsonb_agg(jsonb_build_object(
        'currency', currency, 'gross_milli', gross_milli)) from by_cur), '[]'::jsonb),
    'sandbox_hidden', (select n from sandbox)
  )
);
$fn$;

revoke execute on function public.ops_trials() from public, anon, authenticated;
grant execute on function public.ops_trials() to service_role;

-- ---------------------------------------------------------------------------
-- ops_failures(interval) — what failed in the window, and on which route
-- ---------------------------------------------------------------------------
create or replace function public.ops_failures(p_window interval default '24 hours')
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
since as (select now() - p_window as t),
blocked as (
  select coalesce(value, '[]'::jsonb) as v from public.app_config where key = 'blocked_routes'
),
scoped as (
  select * from public.orders
   where created_at >= (select t from since)
     and user_id <> (select id from dev)
),
-- never reserved a number: terminal, smspva_number null.
nonum as (
  select * from scoped
   where smspva_number is null and status <> 'waiting'
),
nonum_routes as (
  select service_id, country_id, provider, count(*)::int n,
         count(distinct user_id)::int users, max(created_at) last_at
    from nonum group by 1,2,3 order by n desc limit 15
),
-- numbered but no code, settled or cancelled.
nocode as (
  select * from scoped
   where smspva_number is not null and otp is null
     and status in ('expired','canceled')
),
nocode_routes as (
  select service_id, country_id, provider, count(*)::int n,
         0::int codes,
         (percentile_cont(0.5) within group (
            order by extract(epoch from (coalesce(closed_at, expires_at, now()) - created_at))
          ))::int median_held_s
    from nocode
   where coalesce(from_default, false) = false
   group by 1,2,3 order by n desc limit 15
),
mail as (
  select * from public.email_orders
   where created_at >= (select t from since) and user_id <> (select id from dev)
),
esim as (
  select * from public.esim_orders
   where created_at >= (select t from since) and user_id <> (select id from dev)
),
calls as (
  select * from public.line_calls
   where created_at >= (select t from since) and user_id <> (select id from dev)
)
select jsonb_build_object(
  'window_hours', round((extract(epoch from p_window)/3600.0)::numeric, 2),
  'no_number', jsonb_build_object(
    'total', (select count(*)::int from nonum),
    'users', (select count(distinct user_id)::int from nonum),
    'by_route', coalesce((select jsonb_agg(jsonb_build_object(
        'service_id', r.service_id, 'country_id', r.country_id,
        'provider', r.provider, 'n', r.n, 'users', r.users,
        -- orders has no close-reason column; single derived bucket. See header.
        'reasons', jsonb_build_array(jsonb_build_object(
            'reason', 'no_numbers_available', 'n', r.n)),
        'last_at', to_jsonb(r.last_at),
        'route_status', (select rt.status from public.routes rt
                          where rt.service_id = r.service_id and rt.country_id = r.country_id),
        'blocked', (select v from blocked) ? (r.service_id || '|' || r.country_id)
      ) order by r.n desc) from nonum_routes r), '[]'::jsonb)
  ),
  'no_code', jsonb_build_object(
    'total', (select count(*)::int from nocode),
    'settled_expired', (select count(*)::int from nocode where status = 'expired'),
    'canceled', (select count(*)::int from nocode where status = 'canceled'),
    'default_landed', (select count(*)::int from nocode where coalesce(from_default,false)),
    'by_route', coalesce((select jsonb_agg(jsonb_build_object(
        'service_id', r.service_id, 'country_id', r.country_id,
        'provider', r.provider, 'n', r.n, 'codes', r.codes,
        'median_held_s', r.median_held_s
      ) order by r.n desc) from nocode_routes r), '[]'::jsonb)
  ),
  'email', jsonb_build_object(
    'failed', (select count(*)::int from mail where status = 'failed'),
    'expired_no_code', (select count(*)::int from mail where status = 'expired' and code is null),
    'by_domain', coalesce((select jsonb_agg(jsonb_build_object('domain', domain, 'n', n))
      from (select domain, count(*)::int n from mail
             where status in ('failed','expired') and code is null
             group by 1 order by 2 desc limit 15) q), '[]'::jsonb)
  ),
  'esim', jsonb_build_object(
    'failed', (select count(*)::int from esim where status = 'failed')
  ),
  'calls', jsonb_build_object(
    'failed', (select count(*)::int from calls where status in ('failed','busy','missed')),
    'unreached', (select count(*)::int from calls where hangup_cause = 'no_cdr_unreached')
  ),
  -- only the blocked routes that actually failed in this window
  'blocked_routes', coalesce((select jsonb_agg(distinct k) from (
      select (r.service_id || '|' || r.country_id) k from nonum_routes r
       where (select v from blocked) ? (r.service_id || '|' || r.country_id)
    ) b), '[]'::jsonb),
  -- nothing persists a 429 cancel_too_early refusal; null = not measured.
  'refusals', jsonb_build_object('cancel_too_early_429', null)
);
$fn$;

revoke execute on function public.ops_failures(interval) from public, anon, authenticated;
grant execute on function public.ops_failures(interval) to service_role;

-- ---------------------------------------------------------------------------
-- ops_support() — the support queue
-- ---------------------------------------------------------------------------
create or replace function public.ops_support()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
t as (
  select * from public.support_threads
   where user_id <> (select id from dev)
),
live as (
  select th.*,
         case when th.last_sender = 'user' then th.last_message_at end as waiting_since
    from t th where th.status in ('open','assigned')
),
picked as (
  select l.*,
         (select p.display_name from public.profiles p where p.user_id = l.user_id) as display_name,
         (select count(*)::int from public.support_messages m where m.thread_id = l.id) as messages,
         (select left(m.body, 120) from public.support_messages m
           where m.thread_id = l.id order by m.created_at desc limit 1) as last_body
    from live l
   order by (l.waiting_since is null), l.waiting_since asc nulls last, l.last_message_at asc
   limit 10
)
select jsonb_build_object(
  'open',      (select count(*)::int from t where status = 'open'),
  'assigned',  (select count(*)::int from t where status = 'assigned'),
  'closed_7d', (select count(*)::int from t
                 where status = 'closed' and coalesce(closed_at, last_message_at) >= now() - interval '7 days'),
  'threads', coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'user_id', r.user_id, 'display_name', r.display_name,
      'status', r.status, 'last_sender', r.last_sender,
      'last_message_at', to_jsonb(r.last_message_at),
      'created_at', to_jsonb(r.created_at),
      'messages', r.messages,
      'waiting_since', to_jsonb(r.waiting_since),
      'last_body', r.last_body
    ) order by (r.waiting_since is null), r.waiting_since asc, r.last_message_at asc)
    from picked r), '[]'::jsonb),
  'oldest_unanswered_at', (select to_jsonb(min(waiting_since)) from live)
);
$fn$;

revoke execute on function public.ops_support() from public, anon, authenticated;
grant execute on function public.ops_support() to service_role;

-- ---------------------------------------------------------------------------
-- ops_now() — one-screen status
-- ---------------------------------------------------------------------------
create or replace function public.ops_now()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
-- midnight Europe/Paris, per the design brief
day0 as (
  select (date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris') as t
),
health as (
  select replace(key, '_health', '') as provider,
         (value->>'balance_usd')::numeric as usd,
         (value->>'checked_at')::timestamptz as checked_at
    from public.app_config
   where key in ('5sim_health','herosms_health','esimaccess_health','telnyx_health')
),
-- SAME burn query watchdog_money_checks uses: 7-day gross wholesale on
-- orders that actually reserved a number, per provider, divided by 7.
burn as (
  select provider,
         coalesce(sum(actual_cost_cents),0)/100.0/7.0 as per_day
    from public.orders
   where smspva_number is not null and created_at >= now() - interval '7 days'
   group by 1
),
rent as (
  select coalesce(sum(monthly_cost_cents),0)/100.0 as usd
    from public.phone_lines
   where status in ('provisioning','active','grace','past_due','suspended','releasing')
),
bal as (
  select jsonb_object_agg(h.provider, jsonb_build_object(
    'usd', h.usd,
    'checked_at', to_jsonb(h.checked_at),
    'runway_days', case when coalesce(b.per_day,0) > 0
                        then round(h.usd / b.per_day, 1) else null end
  ) || case when h.provider = 'telnyx'
            then jsonb_build_object('rent_per_month_usd', (select usd from rent))
            else '{}'::jsonb end) as v
  from health h left join burn b on b.provider = h.provider
),
wd as (select value as v, updated_at from public.app_config where key = 'watchdog'),
o as (
  select * from public.orders
   where created_at >= (select t from day0) and user_id <> (select id from dev)
),
sub_trials as (
  select s.original_transaction_id, s.expires_at, s.auto_renew, s.state, s.price_milli,
         s.product_id,
         (select pl.e164 from public.phone_lines pl
           where pl.original_transaction_id = s.original_transaction_id
           order by pl.created_at desc limit 1) as e164
    from public.line_subscriptions s
   where s.environment = 'Production'
     and s.user_id <> (select id from dev)
     and s.price_milli = 0 and s.state in ('active','grace')
     and s.product_id like '%.yearly' and s.auto_renew and s.expires_at > now()
),
sup as (
  select count(*) filter (where status = 'open')::int as open,
         count(*) filter (where status = 'assigned')::int as assigned,
         min(case when last_sender = 'user' and status in ('open','assigned')
                  then last_message_at end) as oldest
    from public.support_threads where user_id <> (select id from dev)
)
select jsonb_build_object(
  'now', to_jsonb(now()),
  'balances', coalesce((select v from bal), '{}'::jsonb),
  'watchdog', jsonb_build_object(
    -- The row's `updated_at` is NOT when run_watchdog last ran: telegram-notify
    -- writes `last_alert_at`/`alerted` back onto the same row on every page and
    -- every all-clear, which fires app_config_touch. A dead watchdog plus one
    -- 6-hourly re-page would therefore read as "ran just now". Every other
    -- consumer (/balance, /alerts, telegram-notify) reads value->>'checked_at';
    -- `updated_at` is only the fallback for a verdict written before that field
    -- existed.
    'checked_at', coalesce((select v->'checked_at' from wd),
                           to_jsonb((select updated_at from wd))),
    'failing', coalesce((select v->'failing' from wd), '[]'::jsonb)
  ),
  'paused', jsonb_build_object(
    'lines', coalesce((select value::text = 'true' from public.app_config where key='lines_paused'), false),
    'esim',  coalesce((select value::text = 'true' from public.app_config where key='esim_paused'), false),
    'email_sub_enforced', coalesce((select value::text = 'true' from public.app_config where key='email_subscription_enforced'), false)
  ),
  'today', jsonb_build_object(
    'signups', (select count(*)::int from auth.users
                 where created_at >= (select t from day0) and id <> (select id from dev)),
    'orders',   (select count(*)::int from o),
    'numbered', (select count(*)::int from o where smspva_number is not null),
    'codes',    (select count(*)::int from o where otp is not null),
    'purchases', (select count(*)::int from public.iap_receipts
                   where created_at >= (select t from day0) and user_id <> (select id from dev)
                     and environment = 'Production'),
    'purchase_credits', (select coalesce(sum(granted_credits),0)::int from public.iap_receipts
                   where created_at >= (select t from day0) and user_id <> (select id from dev)
                     and environment = 'Production'),
    'emails', (select count(*)::int from public.email_orders
                where created_at >= (select t from day0) and user_id <> (select id from dev)),
    'email_codes', (select count(*)::int from public.email_orders
                where created_at >= (select t from day0) and user_id <> (select id from dev)
                  and code is not null)
  ),
  'lines', jsonb_build_object(
    'live', (select count(*)::int from public.phone_lines
              where status in ('active','grace','past_due')
                and user_id <> (select id from dev)),
    'trials_converting_24h', (select count(*)::int from sub_trials
                               where expires_at <= now() + interval '24 hours'),
    'next_conversion_at',   (select to_jsonb(expires_at) from sub_trials order by expires_at limit 1),
    'next_conversion_e164', (select e164 from sub_trials order by expires_at limit 1),
    'swaps_pending_release', (select count(*)::int from public.line_number_swaps
                               where state = 'done' and old_provider_number_id is not null
                                 and old_released_at is null),
    'stuck_provisioning', (select count(*)::int from public.phone_lines
                            where status = 'provisioning' and created_at < now() - interval '30 minutes'),
    'releasing_stale', (select count(*)::int from public.phone_lines
                         where status = 'releasing' and updated_at < now() - interval '6 hours')
  ),
  'support', jsonb_build_object(
    'open', (select open from sup),
    'assigned', (select assigned from sup),
    'oldest_unanswered_at', (select to_jsonb(oldest) from sup)
  ),
  'alerts_active', coalesce((select v->'alerted' from wd), '[]'::jsonb)
);
$fn$;

revoke execute on function public.ops_now() from public, anon, authenticated;
grant execute on function public.ops_now() to service_role;

-- ---------------------------------------------------------------------------
-- ops_lines() — the rented-number fleet
-- ---------------------------------------------------------------------------
create or replace function public.ops_lines()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
l as (
  select * from public.phone_lines
   where status <> 'released' and user_id <> (select id from dev)
),
picked as (
  select l.*,
         s.state::text as sub_state, s.auto_renew as sub_auto_renew,
         s.expires_at as sub_expires_at, s.price_milli, s.product_id,
         (select count(*)::int from public.line_messages m
           where m.line_id = l.id and m.direction = 'inbound'
             and m.created_at >= now() - interval '30 days') as inbound_msgs_30d,
         (select count(*)::int from public.line_calls c
           where c.line_id = l.id and c.created_at >= now() - interval '30 days') as calls_30d,
         (select count(*)::int from public.line_number_swaps w where w.line_id = l.id) as swaps
    from l
    left join public.line_subscriptions s
      on s.original_transaction_id = l.original_transaction_id
)
select jsonb_build_object(
  'paused', coalesce((select value::text = 'true' from public.app_config where key='lines_paused'), false),
  'live', (select count(*)::int from l where status in ('active','grace','past_due')),
  'lines', coalesce((select jsonb_agg(jsonb_build_object(
      'e164', r.e164, 'status', r.status::text, 'billing', r.billing,
      'user_id', r.user_id, 'activated_at', to_jsonb(r.activated_at),
      'sms_used', r.sms_used, 'sms_allowance', r.sms_allowance,
      'voice_used_seconds', r.voice_used_seconds,
      'voice_allowance_seconds', r.voice_allowance_seconds,
      'inbound_msgs_30d', r.inbound_msgs_30d,
      'calls_30d', r.calls_30d,
      'swaps', r.swaps,
      'sub_state', r.sub_state,
      'sub_auto_renew', r.sub_auto_renew,
      'sub_expires_at', to_jsonb(r.sub_expires_at),
      -- same trial rule as ops_trials: $0 billed on a yearly product
      'sub_is_trial', (r.price_milli = 0 and r.product_id like '%.yearly'
                       and r.sub_state in ('active','grace')),
      'voice_attached', r.provider_voice_attached,
      'monthly_cost_cents', r.monthly_cost_cents
    ) order by r.activated_at desc nulls last) from picked r), '[]'::jsonb),
  -- what we pay the provider per month for every non-released line
  'rent_per_month_usd', (select coalesce(sum(monthly_cost_cents),0)/100.0 from l),
  'swaps', jsonb_build_object(
    'total', (select count(*)::int from public.line_number_swaps),
    'pending_release', (select count(*)::int from public.line_number_swaps
                         where state = 'done' and old_provider_number_id is not null
                           and old_released_at is null),
    'failed', (select count(*)::int from public.line_number_swaps where state = 'failed')
  )
);
$fn$;

revoke execute on function public.ops_lines() from public, anon, authenticated;
grant execute on function public.ops_lines() to service_role;

-- ---------------------------------------------------------------------------
-- ops_route(service, country) — why is X unavailable
-- ---------------------------------------------------------------------------
create or replace function public.ops_route(p_service text, p_country text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
blocked as (
  select coalesce(value, '[]'::jsonb) as v from public.app_config where key = 'blocked_routes'
),
svc as (select * from public.services where id = lower(trim(p_service))),
r as (
  select rt.* from public.routes rt
   where rt.service_id = (select id from svc)
     and (p_country is null or rt.country_id = lower(trim(p_country)))
),
agg as (
  select service_id, country_id,
         count(*)::int n,
         count(*) filter (where otp is not null)::int codes
    from public.orders
   where service_id = (select id from svc)
     and created_at >= now() - interval '7 days'
     and user_id <> (select id from dev)
   group by 1,2
),
ranked as (
  select r.*, coalesce(a.n,0) orders_7d, coalesce(a.codes,0) codes_7d
    from r left join agg a
      on a.service_id = r.service_id and a.country_id = r.country_id
   order by (r.status = 'active') desc, r.pool_rate_pct desc nulls last, r.retail_credits asc
   limit 25
)
select case when (select count(*) from svc) = 0 then
  jsonb_build_object(
    'error', 'unknown_service',
    'suggestions', coalesce((select jsonb_agg(id order by id) from (
        select id from public.services
         -- `%` and `_` are LIKE wildcards, and this pattern is built from
         -- whatever the owner typed: escape both, or `/route %` lists ten
         -- arbitrary services as if they were near-matches.
         -- `!` as the escape char, not a backslash: `\` in a literal depends
         -- on standard_conforming_strings, `!` never does.
         where id ilike '%' || replace(replace(replace(
                 lower(trim(p_service)), '!', '!!'), '%', '!%'), '_', '!_') || '%'
              escape '!'
         order by id limit 10) s), '[]'::jsonb)
  )
else
  jsonb_build_object(
    'service', (select jsonb_build_object('id', id, 'name', name,
                  'visible', visible, 'domain', domain) from svc),
    'country', p_country,
    'routes_total', (select count(*)::int from r),
    -- Bookable over ALL routes for the service, not over the 25 `ranked` keeps.
    -- The formatter used to count the rows it was handed, so the headline was
    -- an artifact of the LIMIT (59 active rendered as "25 of 69").
    -- Bookable = active AND, where this provider publishes a stock figure at
    -- all, that figure is non-zero. `coalesce(...,1)` is "no stock column
    -- populated" — unknown, not empty — which is exactly how the row renders.
    'routes_active', (select count(*)::int from r
                       where r.status = 'active'
                         and coalesce(r.stock, r.fivesim_stock,
                                      r.herosms_total_count, 1) <> 0),
    'routes', coalesce((select jsonb_agg(jsonb_build_object(
        'country_id', k.country_id,
        'provider', k.provider,
        'status', k.status,
        'retail_credits', k.retail_credits,
        'premium_credits', k.premium_credits,
        'pool_rate_pct', k.pool_rate_pct,
        'pool_operator', k.pool_operator,
        -- `routes` carries several stock readings; none is canonical.
        'stock', k.stock,
        'fivesim_stock', k.fivesim_stock,
        'herosms_total_count', k.herosms_total_count,
        'herosms_physical_count', k.herosms_physical_count,
        'last_checked_at', to_jsonb(k.last_checked_at),
        'blocked', (select v from blocked) ? (k.service_id || '|' || k.country_id),
        'real_sim_only', k.real_sim_only,
        'success_codes', k.success_codes,
        'success_sample', k.success_sample,
        'rate_source', k.rate_source,
        'orders_7d', k.orders_7d,
        'codes_7d', k.codes_7d
      ) order by (k.status = 'active') desc, k.pool_rate_pct desc nulls last,
                 k.retail_credits asc) from ranked k), '[]'::jsonb)
  )
end;
$fn$;

revoke execute on function public.ops_route(text, text) from public, anon, authenticated;
grant execute on function public.ops_route(text, text) to service_role;

commit;
