-- Repoint the "Top success rates" card at 5sim.
--
-- service_country_ranks held 387 rows collected from HeroSMS's dashboard by
-- hand. HeroSMS no longer serves SMS (cutover 2026-08-03), so both surfaces
-- that read this table — CountrySheet's "Top success rates" card and
-- RecoveryScreen's ranked retry suggestion — were showing a RETIRED provider's
-- numbers as if they described the route the user is about to buy. That is the
-- same class of error as the 305 seeded SMSPVA rates stranded on HeroSMS routes
-- (20260803121000): evidence must describe the provider that serves the NEXT
-- order.
--
-- The replacement is derived, not collected. Every active 5sim route already
-- carries `pool_rate_pct` — the 30-day published rate of the exact pool
-- create-order will pin — so the top-10 card is now just a projection of the
-- same number the row itself shows. No second data source, no weekly manual
-- browser run, and the card can never disagree with the row beneath it.
--
-- ⚠️ The client caption still reads "Network-wide rates from the last 24h".
-- With 5sim it is a 30-DAY window (rate720). The string needs updating in the
-- next client release along with its six translations; it is left alone here
-- rather than silently changing meaning under a shipped build.

create or replace function public.refresh_service_country_ranks_fivesim()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare n_ins int;
begin
  -- Delete-then-insert, scoped to this provider: a service whose routes all
  -- lost their rate must end up with NO rows rather than keeping last week's.
  delete from public.service_country_ranks where provider = '5sim';

  with ranked as (
    select r.service_id, r.country_id, r.pool_rate_pct::numeric(5,2) as pct,
           row_number() over (partition by r.service_id
                              order by r.pool_rate_pct desc, r.retail_credits asc) as rn
      from public.routes r
     where r.provider = '5sim'
       and r.status = 'active'
       and r.pool_rate_pct is not null
       and r.retail_credits is not null
  )
  insert into public.service_country_ranks
    (service_id, country_id, vendor_percent, vendor_rank, provider, updated_at)
  select service_id, country_id, pct, rn, '5sim', now()
    from ranked where rn <= 10;
  get diagnostics n_ins = row_count;

  -- The HeroSMS rows are removed here and not repopulated: nothing collects
  -- them any more, and leaving them would let a retired provider's number win
  -- the client's rankIndex, which is keyed only on (service, country).
  delete from public.service_country_ranks where provider = 'herosms';

  return jsonb_build_object('provider', '5sim', 'rows', n_ins, 'at', now());
end;
$function$;

revoke execute on function public.refresh_service_country_ranks_fivesim()
  from public, anon, authenticated;

select public.refresh_service_country_ranks_fivesim();
