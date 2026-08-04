-- Re-home Claude, Grab and Hepsiburada to 5sim (owner decision, 2026-08-04).
--
-- These three were already in the catalog on HeroSMS, with no fivesim_product,
-- so they surfaced as id collisions while adding the 100 new 5sim services
-- (20260804200000). 5sim carries all three, and setting the mapping hands them
-- to the provider that actually serves our SMS traffic.
--
-- WHAT THIS ACTUALLY DOES, because it is not just a label: sync-5sim builds its
-- write set from any route whose service has a 5sim slug, and while
-- app_config.fivesim_live is true it writes `provider`, `status` AND
-- `retail_credits` on every one of them. So this re-homes EVERY route of these
-- services away from HeroSMS, reprices them with 5sim's divisor, and hides any
-- where 5sim has no stock. It is a provider switch scoped to three services.
--
-- MEASURED BEFORE APPLYING, against 5sim's guest/prices intersected with our 60
-- fivesim-mapped countries:
--
--   service       active today            5sim overlap with our countries
--   claude        7  (all herosms)        44
--   grab          6  (all herosms)        58
--   hepsiburada   5  (all herosms)        57
--
-- Each gains far more than it can lose, which is the only reason this is safe
-- to do in one step.
--
-- ⚠️ g2a IS DELIBERATELY EXCLUDED. It was the fourth collision and it does
-- exist on 5sim -- but in exactly ONE of our 60 countries, against 9 active
-- routes it serves today on SMSPVA. Re-homing it would cut it from 9 bookable
-- countries to 1. "The provider carries it" is not sufficient; the country
-- overlap is what decides, and for g2a it is disqualifying. Leave it on SMSPVA
-- until 5sim's coverage changes.
--
-- ROLLBACK: set fivesim_product back to null for these three and re-run
-- sync-herosms; their routes return to HeroSMS on the next run. Their
-- herosms_code is untouched precisely so this stays a one-statement revert.

update public.services
   set fivesim_product = case id
                           when 'claude'      then 'claudeai'
                           when 'grab'        then 'grabtaxi'
                           when 'hepsiburada' then 'hepsiburadacom'
                         end
 where id in ('claude', 'grab', 'hepsiburada');

do $$
declare
  v_mapped integer;
  v_g2a    text;
  v_hero   integer;
begin
  select count(*) into v_mapped
    from public.services
   where id in ('claude','grab','hepsiburada') and fivesim_product is not null;
  if v_mapped <> 3 then
    raise exception 'expected 3 services mapped to 5sim, found %', v_mapped;
  end if;

  -- g2a must NOT have been mapped by this migration.
  select fivesim_product into v_g2a from public.services where id = 'g2a';
  if v_g2a is not null then
    raise exception 'g2a was mapped to 5sim (%), which this migration must not do', v_g2a;
  end if;

  -- The rollback path must survive: herosms_code is what sends them back.
  select count(*) into v_hero
    from public.services
   where id in ('claude','grab','hepsiburada') and herosms_code is not null;
  if v_hero <> 3 then
    raise exception 'only % of 3 kept a herosms_code; rollback would be lossy', v_hero;
  end if;

  raise notice 'mapped 3 services to 5sim; g2a left on its current provider';
end $$;
