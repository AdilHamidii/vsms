-- attribution_summary(): add the SUBSCRIPTION half.
--
-- The function joined ASA installs to credit-pack receipts only, so a campaign
-- bought to sell SECOND NUMBERS (owner brief 2026-09-05, docs/asa-second-
-- number-plan.md) could never be evaluated against its own goal — every
-- subscriber would read as "installed, bought nothing". Two columns:
--
--   line_subs   users with ANY line_subscriptions row (trials included)
--   line_paid   users with a row where price_milli > 0 (a real charge)
--
-- Both are per-user existence counts, not row counts, so a user who churned
-- and re-subscribed is one subscriber, matching `buyers`.
--
-- DROP + CREATE because the RETURNS TABLE shape changes; `create or replace`
-- refuses a return-type change. Service-role only, as before.

drop function if exists public.attribution_summary();

create function public.attribution_summary()
returns table (
  campaign_id bigint,
  keyword_id  bigint,
  attributed  boolean,
  installs    bigint,
  buyers      bigint,
  purchases   bigint,
  credits     bigint,
  line_subs   bigint,
  line_paid   bigint
)
language sql
security definer
set search_path to 'public'
as $function$
    with buys as (
        select r.user_id,
               count(*)                          as purchases,
               coalesce(sum(r.granted_credits),0) as credits
        from public.iap_receipts r
        where r.environment = 'Production'
          and coalesce(r.granted_credits, 0) > 0
        group by r.user_id
    ),
    subs as (
        select s.user_id,
               bool_or(coalesce(s.price_milli, 0) > 0
                       and coalesce(s.environment, 'Production') = 'Production') as paid
        from public.line_subscriptions s
        group by s.user_id
    )
    select a.campaign_id,
           a.keyword_id,
           a.attributed,
           count(*)                                       as installs,
           count(b.user_id)                               as buyers,
           coalesce(sum(b.purchases), 0)::bigint          as purchases,
           coalesce(sum(b.credits), 0)::bigint            as credits,
           count(s.user_id)                               as line_subs,
           count(s.user_id) filter (where s.paid)         as line_paid
    from public.install_attributions a
    left join buys b on b.user_id = a.user_id
    left join subs s on s.user_id = a.user_id
    group by a.campaign_id, a.keyword_id, a.attributed
    order by line_paid desc, credits desc, installs desc;
$function$;

revoke execute on function public.attribution_summary() from public, anon, authenticated;
