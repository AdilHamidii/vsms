-- email-domain-<domain> only pages for a domain that is STILL TAKING ORDERS.
--
-- gmail.com was removed from sale on 2026-08-26 (deleted from both PRICING
-- maps — the icloud precedent) because its pool delivered 1 code in 36 orders
-- since ~08-10. Without this amendment the check would keep paging every 6h
-- about the removed domain until its historical orders aged out of the 14-day
-- window (~2026-09-09) — alert fatigue about a decision already taken, which
-- is exactly how the next real page gets ignored.
--
-- The added condition: the domain's most recent order in the window must be
-- within 72 hours. A domain still on sale keeps generating orders, so a dead
-- pool that is still SOLD keeps paging (the point of the check); a domain
-- pulled from sale stops generating orders and the check goes quiet within
-- three days on its own. Accepted residual: a dead domain that users simply
-- stopped trying also goes quiet — acceptable, because "nobody is being sold
-- failures any more" is the condition the page exists to create.
--
-- Everything else in watchdog_delivery_checks is byte-identical to
-- 20260826140000 (regenerated from the live pg_get_functiondef, diffed:
-- exactly one added predicate in the email CTE's HAVING-equivalent WHERE).

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
     -- Still being sold: quiet within 72h once a domain is pulled from PRICING.
     and a.last_order_at >= now() - interval '72 hours'
     and exists (select 1 from agg b where b.codes > 0);

  fails := fails || coalesce(v_email, '[]'::jsonb);

  return fails;
end;
$function$;

revoke execute on function public.watchdog_delivery_checks() from public, anon, authenticated;
