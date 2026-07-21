-- Order the catalog by what actually delivers a code, not by brand fame.
--
-- The previous ordering was close to inverted against measured outcomes:
--   pos  700-730  Tinder/Bumble/Hinge/Grindr  547 active routes, 0 orders EVER,
--                 and first-hand 2024-2026 reports that all four now block
--                 SMS-verification services outright
--   pos     3190  Leboncoin                   our BEST route, 21/35 = 60%
--   pos     7010  Steam / Blizzard            the only category with positive
--                 first-hand 2026 evidence (Battle.net confirmed working Feb)
--   pos      100  WhatsApp                    0/5 lifetime
--
-- Measured: non-Meta services deliver ~46% vs Meta's ~6%, and demand shifted
-- from 0% Meta orders in June to 84% in July — which is the whole reason the
-- headline delivery rate fell from ~55% to ~11%. Ordering is worth more here
-- than any provider tuning.
--
-- Nothing is hidden: every service stays browsable and searchable. This only
-- changes what a user sees FIRST, which decides whether their first attempt
-- succeeds — and 5 of 17 users who hit a failure never came back.
with promoted(id, pos) as (values
  -- Proven in our own order data (>=1 delivered code)
  ('leboncoin',100),('tiktok',110),('deliveroo',120),
  ('glovo',130),('whatnot',140),('walmart',150),
  -- Evidence-positive elsewhere: marketplaces/classifieds + gaming
  ('vinted',200),('wallapop',210),('subito',220),('olx',230),
  ('steam',240),('blizzard',250),('twitch',260)
)
update public.services s set sort_order = p.pos
from promoted p where s.id = p.id;

with promoted(id) as (values
  ('leboncoin'),('tiktok'),('deliveroo'),('glovo'),('whatnot'),('walmart'),
  ('vinted'),('wallapop'),('subito'),('olx'),('steam'),('blizzard'),('twitch')
)
update public.services s
set sort_order = case
      when s.category in ('Dating')                       then 9000 + (s.sort_order % 1000)
      when s.category in ('Social','Messaging')           then 5000 + (s.sort_order % 1000)
      when s.category in ('Tech','Productivity','AI','Surveys',
                          'Specialty','Finance','Gambling') then 2000 + (s.sort_order % 1000)
      else 1000 + (s.sort_order % 1000)
    end
where s.id not in (select id from promoted);
