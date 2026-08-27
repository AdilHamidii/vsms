-- US + PR localities for the line store. Until now line_localities held only
-- the 7 Canadian seed cities, so a US/PR search had no city step and fell
-- back to country-wide — the user got "a random number" (observed: Las Vegas
-- and Bremen IN on the first US search, 2026-08-27). Same rule as the CA
-- seed: area codes ordered MOST-LIKELY-TO-HAVE-STOCK FIRST, i.e. newer
-- overlay codes before the exhausted prestige codes (437 before 416 was the
-- CA precedent; 929 before 212 here for the same reason).
--
-- Pure data: no deploy and no client release — search-line-numbers walks
-- these rows live and the shipped city step renders whatever comes back.

insert into public.line_localities (id, country_code, label, region_label, area_codes, sort_order) values
  ('new-york',      'US', 'New York',       'New York',             array['929','347','646','917','718','212'], 10),
  ('los-angeles',   'US', 'Los Angeles',    'California',           array['424','323','213','310','818'],       20),
  ('chicago',       'US', 'Chicago',        'Illinois',             array['872','773','312'],                   30),
  ('houston',       'US', 'Houston',        'Texas',                array['832','281','713'],                   40),
  ('miami',         'US', 'Miami',          'Florida',              array['786','305'],                         50),
  ('san-francisco', 'US', 'San Francisco',  'California',           array['628','415'],                         60),
  ('dallas',        'US', 'Dallas',         'Texas',                array['469','972','214'],                   70),
  ('atlanta',       'US', 'Atlanta',        'Georgia',              array['470','678','404'],                   80),
  ('seattle',       'US', 'Seattle',        'Washington',           array['425','253','206'],                   90),
  ('las-vegas',     'US', 'Las Vegas',      'Nevada',               array['725','702'],                        100),
  ('phoenix',       'US', 'Phoenix',        'Arizona',              array['623','480','602'],                  110),
  ('boston',        'US', 'Boston',         'Massachusetts',        array['857','617'],                        120),
  ('denver',        'US', 'Denver',         'Colorado',             array['720','303'],                        130),
  ('washington-dc', 'US', 'Washington, DC', 'District of Columbia', array['771','202'],                        140),
  ('san-juan',      'PR', 'San Juan',       'Puerto Rico',          array['939','787'],                         10)
on conflict (id) do nothing;
