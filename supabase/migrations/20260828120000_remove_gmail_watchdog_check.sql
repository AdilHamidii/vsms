-- Remove the email-domain-gmail.com watchdog check (owner decision 2026-08-28).
-- gmail.com was pulled from sale on 2026-08-26 (dead pool — 0 codes in its last
-- 36 orders); the per-domain delivery check kept paging about a decision already
-- taken until its 72h recency condition drained. The owner asked for it gone
-- now, so gmail.com is excluded from the per-domain aggregation explicitly.
--
-- ⚠️ If gmail.com is ever re-added to PRICING, DELETE this exclusion in the
-- same commit — the watchdog evidence is the documented recovery signal for
-- re-adding the tier, and with this exclusion in place it cannot fire.
--
-- Regenerated from pg_get_functiondef 2026-08-28 and diffed: exactly one hunk
-- (the `a.domain <> 'gmail.com'` predicate); every other clause byte-identical.

create or replace function public.watchdog_delivery_checks()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  fails jsonb := '[]'::jsonb;
  v_reached int;
  v_matched boolean;
  v_oldest timestamptz;
  v_email jsonb;
  v_dev uuid := '825688de-6117-4251-9f90-93b83b41b572';
begin
  select count(*), min(created_at)
    into v_reached, v_oldest
    from line_calls
   where created_at < now() - interval '24 hours'
     and created_at > now() - interval '30 days'
     and (provider_call_session_id is not null
          or provider_call_leg_id is not null);

  select exists (
    select 1 from line_calls
     where allowance_settled = true
       and (provider_call_session_id is not null
            or provider_call_leg_id is not null)
       and hangup_cause is not null
       and hangup_cause not like 'no\_cdr%'
  ) into v_matched;

  if coalesce(v_reached, 0) > 0 and not v_matched then
    fails := fails || jsonb_build_object(
      'check', 'cdr-never-matched',
      'detail', v_reached || ' call(s) reached Telnyx (oldest ' ||
                coalesce(v_oldest::text, '?') ||
                ') and sync-telnyx-cdr has never matched a single detail ' ||
                'record — every call is billed its flat reservation by the 6h backstop');
  end if;

  with agg as (
    select domain,
           count(*)                                  as n,
           count(*) filter (where code is not null)  as codes,
           max(created_at)                           as last_order_at
      from email_orders
     where created_at >= now() - interval '14 days'
       and created_at <  now() - interval '1 hour'
       and user_id <> v_dev
     group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'check', 'email-domain-' || a.domain,
           'detail', a.domain || ' delivered 0 codes in ' || a.n ||
                     ' orders over 14 days while other domains delivered — ' ||
                     'the address pool is dead, not the users')), '[]'::jsonb)
    into v_email
    from agg a
   where a.codes = 0
     and a.n >= 8
     and a.domain <> 'gmail.com'
     and a.last_order_at >= now() - interval '72 hours'
     and exists (select 1 from agg b where b.codes > 0);

  fails := fails || coalesce(v_email, '[]'::jsonb);

  return fails;
end;
$function$;

revoke execute on function public.watchdog_delivery_checks() from public, anon, authenticated;

-- Clear any lingering downtime stamp for the retired check so /alerts stops
-- listing it. watchdog_since is a service-role-only key; absent is fine.
update public.app_config
   set value = value - 'email-domain-gmail.com'
 where key = 'watchdog_since'
   and value ? 'email-domain-gmail.com';
