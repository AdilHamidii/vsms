-- Add 100 recognisable services that 5sim already carries and we never listed.
--
-- WHY. 5sim offers 1,276 products; we mapped 147 and sold 146. The other 1,133
-- were absent not because 5sim withholds them but because `services` is a
-- hand-built 268-row catalog. Search is this app's ENTIRE acquisition channel
-- (20,884 impressions / 143 downloads, all App Store search, zero browse), so
-- an unlisted service is a term we cannot rank for and a user who finds
-- nothing. Wholesale on these reads $0.01-$0.05, i.e. 1-2 credits retail.
--
-- NO APP RELEASE IS NEEDED. The catalog is fetched from the server, and
-- ServiceLogo falls back to the DuckDuckGo/Google favicon cascade for any
-- domain not in BundledLogos, so these render on shipped 1.7 and 1.8. Run
-- scripts/fetch-bundled-assets.sh --refresh before the next release to bundle
-- the new logos; until then they come over the network.
--
-- ROUTES MUST BE SEEDED HERE. sync-5sim builds its write set from routes it
-- has READ -- "this sync only ever updates -- it never inserts, and never
-- deletes" -- so a service with no route rows would be invisible to it
-- forever. 60 countries carry a fivesim_country mapping, so this creates
-- 100 x 60 = 6,000 rows.
--
-- SEEDED `hidden`, NOT `active`. routes.status DEFAULTS to 'active' and
-- provider DEFAULTS to 'smspva' -- both wrong here, and both silent. An
-- unpriced active route has retail_credits NULL, which the client renders as
-- "Unavailable"; worse, a default provider of 'smspva' would hand ownership to
-- a provider that has no code for these services, and providerOrder() resolves
-- ownership from routes.provider. They go live only when sync-5sim (hourly
-- :07) finds real stock at an acceptable price -- it sets status itself, and
-- app_config.fivesim_live is already true.
--
-- SORT ORDER STARTS AT 10000, above every existing service (max 9840), so 100
-- untested services cannot displace measured ones in the browse list. They are
-- still fully reachable by search, which is how they will actually be found.
-- apply_measured_service_ranking rewrites sort_order once a service has >= 8
-- conclusive attempts, so this ordering is a starting point, not a verdict.
--
-- success_rate/cost/eta_seconds are LEFT TO THEIR DEFAULTS (95/1/30) rather
-- than invented per service. All three are seed data; the client renders only
-- measured evidence and shows "Not tested" until a route has real attempts, so
-- these values never reach a user. Do not start quoting them.
--
--
-- `smspva_code` IS SET TO THE EMPTY STRING, NOT NULL, AND THAT IS LOAD-BEARING.
-- The column is NOT NULL (a leftover from when SMSPVA was the only provider)
-- and the obvious fix -- dropping the constraint -- would break the LIVE app:
-- Service.swift declares `let smspvaCode: String`, non-optional, so a null
-- makes the catalog decode THROW. Per the decode rule, one bad field does not
-- degrade gracefully; the whole catalog fails and every service on shipped 1.7
-- and 1.8 renders "Unavailable". Empty string decodes fine and is falsy in the
-- router, so it can never be mistaken for a real SMSPVA code. If that Swift
-- field ever becomes `String?`, the constraint can be dropped -- client first,
-- schema second, as with every other column change here.
--
-- Every product slug below was validated against 5sim's live
-- guest/products/any/any before this file was written: all 100 exist, none was
-- already mapped, no duplicate ids. A typo would create a service that can
-- never be priced and would sit in the catalog reading "Unavailable" forever.

with ins as (
  insert into public.services
    (id, name, category, domain, tint_hex, glyph, icon, sort_order, fivesim_product, smspva_code)
  values
  ('ebay', 'eBay', 'Commerce', 'ebay.com', '#E53238', 'E', 'bag.fill', 10000, 'ebay', ''),
  ('etsy', 'Etsy', 'Commerce', 'etsy.com', '#F1641E', 'E', 'bag.fill', 10010, 'etsy', ''),
  ('aliexpress', 'AliExpress', 'Commerce', 'aliexpress.com', '#E62E04', 'A', 'bag.fill', 10020, 'aliexpress', ''),
  ('temu', 'Temu', 'Commerce', 'temu.com', '#FB7701', 'T', 'bag.fill', 10030, 'temu', ''),
  ('shein', 'SHEIN', 'Commerce', 'shein.com', '#000000', 'S', 'bag.fill', 10040, 'shein', ''),
  ('wish', 'Wish', 'Commerce', 'wish.com', '#2FB7EC', 'W', 'bag.fill', 10050, 'wish', ''),
  ('taobao', 'Taobao', 'Commerce', 'taobao.com', '#FF4400', 'T', 'bag.fill', 10060, 'taobao', ''),
  ('jd', 'JD.com', 'Commerce', 'jd.com', '#E1251B', 'J', 'bag.fill', 10070, 'jd', ''),
  ('pinduoduo', 'Pinduoduo', 'Commerce', 'pinduoduo.com', '#E22E1F', 'P', 'bag.fill', 10080, 'pinduoduo', ''),
  ('rakuten', 'Rakuten', 'Commerce', 'rakuten.com', '#BF0000', 'R', 'bag.fill', 10090, 'rakuten', ''),
  ('allegro', 'Allegro', 'Commerce', 'allegro.pl', '#FF5A00', 'A', 'bag.fill', 10100, 'allegro', ''),
  ('emag', 'eMAG', 'Commerce', 'emag.ro', '#0071BC', 'E', 'bag.fill', 10110, 'emag', ''),
  ('rozetka', 'Rozetka', 'Commerce', 'rozetka.com.ua', '#00A046', 'R', 'bag.fill', 10120, 'rozetka', ''),
  ('trendyol', 'Trendyol', 'Commerce', 'trendyol.com', '#F27A1A', 'T', 'bag.fill', 10130, 'trendyol', ''),
  ('baidu', 'Baidu', 'Tech', 'baidu.com', '#2932E1', 'B', 'desktopcomputer', 10140, 'baidu', ''),
  ('flipkart', 'Flipkart', 'Commerce', 'flipkart.com', '#2874F0', 'F', 'bag.fill', 10150, 'flipkart', ''),
  ('myntra', 'Myntra', 'Commerce', 'myntra.com', '#FF3F6C', 'M', 'bag.fill', 10160, 'myntra', ''),
  ('meesho', 'Meesho', 'Commerce', 'meesho.com', '#F43397', 'M', 'bag.fill', 10170, 'meesho', ''),
  ('tokopedia', 'Tokopedia', 'Commerce', 'tokopedia.com', '#42B549', 'T', 'bag.fill', 10180, 'tokopedia', ''),
  ('bukalapak', 'Bukalapak', 'Commerce', 'bukalapak.com', '#E31E52', 'B', 'bag.fill', 10190, 'bukalapak', ''),
  ('coupang', 'Coupang', 'Commerce', 'coupang.com', '#B12704', 'C', 'bag.fill', 10200, 'coupang', ''),
  ('carousell', 'Carousell', 'Commerce', 'carousell.com', '#FF4F4F', 'C', 'bag.fill', 10210, 'carousell', ''),
  ('noon', 'Noon', 'Commerce', 'noon.com', '#FEEE00', 'N', 'bag.fill', 10220, 'noon', ''),
  ('poshmark', 'Poshmark', 'Commerce', 'poshmark.com', '#731A25', 'P', 'bag.fill', 10230, 'poshmark', ''),
  ('depop', 'Depop', 'Commerce', 'depop.com', '#FF0000', 'D', 'bag.fill', 10240, 'depop', ''),
  ('gumtree', 'Gumtree', 'Commerce', 'gumtree.com', '#72EF36', 'G', 'bag.fill', 10250, 'gumtree', ''),
  ('shopify', 'Shopify', 'Commerce', 'shopify.com', '#95BF47', 'S', 'bag.fill', 10260, 'shopify', ''),
  ('duolingo', 'Duolingo', 'Productivity', 'duolingo.com', '#58CC02', 'D', 'briefcase.fill', 10270, 'duolingo', ''),
  ('humblebundle', 'Humble Bundle', 'Commerce', 'humblebundle.com', '#CC2929', 'H', 'bag.fill', 10280, 'humblebundle', ''),
  ('nike', 'Nike', 'Commerce', 'nike.com', '#111111', 'N', 'bag.fill', 10290, 'nike', ''),
  ('adidas', 'Adidas', 'Commerce', 'adidas.com', '#000000', 'A', 'bag.fill', 10300, 'adidas', ''),
  ('zara', 'Zara', 'Commerce', 'zara.com', '#000000', 'Z', 'bag.fill', 10310, 'zara', ''),
  ('footlocker', 'Foot Locker', 'Commerce', 'footlocker.com', '#E4002B', 'F', 'bag.fill', 10320, 'footlocker', ''),
  ('carrefour', 'Carrefour', 'Commerce', 'carrefour.com', '#004E9F', 'C', 'bag.fill', 10330, 'carrefour', ''),
  ('tesco', 'Tesco', 'Commerce', 'tesco.com', '#00539F', 'T', 'bag.fill', 10340, 'tesco', ''),
  ('lidl', 'Lidl', 'Commerce', 'lidl.com', '#0050AA', 'L', 'bag.fill', 10350, 'lidl', ''),
  ('seven-eleven', '7-Eleven', 'Commerce', '7-eleven.com', '#F37021', '7', 'bag.fill', 10360, '7eleven', ''),
  ('cocacola', 'Coca-Cola', 'Commerce', 'coca-cola.com', '#F40009', 'C', 'bag.fill', 10370, 'cocacola', ''),
  ('mcdonalds', 'McDonald''s', 'Delivery', 'mcdonalds.com', '#FFC72C', 'M', 'takeoutbag.and.cup.and.straw.fill', 10380, 'mcdonalds', ''),
  ('burgerking', 'Burger King', 'Delivery', 'bk.com', '#D62300', 'B', 'takeoutbag.and.cup.and.straw.fill', 10390, 'burgerking', ''),
  ('kfc', 'KFC', 'Delivery', 'kfc.com', '#A50034', 'K', 'takeoutbag.and.cup.and.straw.fill', 10400, 'kfc', ''),
  ('pizzahut', 'Pizza Hut', 'Delivery', 'pizzahut.com', '#EE3A43', 'P', 'takeoutbag.and.cup.and.straw.fill', 10410, 'pizzahut', ''),
  ('dominos', 'Domino''s Pizza', 'Delivery', 'dominos.com', '#006491', 'D', 'takeoutbag.and.cup.and.straw.fill', 10420, 'dominospizza', ''),
  ('dunkin', 'Dunkin''', 'Delivery', 'dunkindonuts.com', '#FF671F', 'D', 'takeoutbag.and.cup.and.straw.fill', 10430, 'dunkin', ''),
  ('justeat', 'Just Eat', 'Delivery', 'just-eat.com', '#FF8000', 'J', 'takeoutbag.and.cup.and.straw.fill', 10440, 'justeat', ''),
  ('zomato', 'Zomato', 'Delivery', 'zomato.com', '#E23744', 'Z', 'takeoutbag.and.cup.and.straw.fill', 10450, 'zomato', ''),
  ('swiggy', 'Swiggy', 'Delivery', 'swiggy.com', '#FC8019', 'S', 'takeoutbag.and.cup.and.straw.fill', 10460, 'swiggy', ''),
  ('talabat', 'Talabat', 'Delivery', 'talabat.com', '#FF5A00', 'T', 'takeoutbag.and.cup.and.straw.fill', 10470, 'talabat', ''),
  ('getir', 'Getir', 'Delivery', 'getir.com', '#5D3EBC', 'G', 'takeoutbag.and.cup.and.straw.fill', 10480, 'getir', ''),
  ('rappi', 'Rappi', 'Delivery', 'rappi.com', '#FF441F', 'R', 'takeoutbag.and.cup.and.straw.fill', 10490, 'rappi', ''),
  ('gojek', 'Gojek', 'Transport', 'gojek.com', '#00AA13', 'G', 'car.fill', 10500, 'gojek', ''),
  ('paytm', 'Paytm', 'Finance', 'paytm.com', '#00BAF2', 'P', 'creditcard.fill', 10510, 'paytm', ''),
  ('blablacar', 'BlaBlaCar', 'Transport', 'blablacar.com', '#00AFF5', 'B', 'car.fill', 10520, 'blablacar', ''),
  ('indriver', 'inDrive', 'Transport', 'indrive.com', '#C1F11D', 'I', 'car.fill', 10530, 'indriver', ''),
  ('rapido', 'Rapido', 'Transport', 'rapido.bike', '#FFCC00', 'R', 'car.fill', 10540, 'rapido', ''),
  ('olacabs', 'Ola', 'Transport', 'olacabs.com', '#B4D22E', 'O', 'car.fill', 10550, 'olacabs', ''),
  ('freenow', 'FREENOW', 'Transport', 'free-now.com', '#FF00FF', 'F', 'car.fill', 10560, 'freenow', ''),
  ('lime', 'Lime', 'Transport', 'li.me', '#00DD00', 'L', 'car.fill', 10570, 'lime', ''),
  ('irctc', 'IRCTC', 'Travel', 'irctc.co.in', '#213B78', 'I', 'airplane', 10580, 'irctc', ''),
  ('redbus', 'redBus', 'Travel', 'redbus.in', '#D84E55', 'R', 'airplane', 10590, 'redbus', ''),
  ('klook', 'Klook', 'Travel', 'klook.com', '#FF5722', 'K', 'airplane', 10600, 'klook', ''),
  ('oyo', 'OYO', 'Travel', 'oyorooms.com', '#EE2E24', 'O', 'airplane', 10610, 'oyo', ''),
  ('qantas', 'Qantas', 'Travel', 'qantas.com', '#E40000', 'Q', 'airplane', 10620, 'qantas', ''),
  ('united-airlines', 'United Airlines', 'Travel', 'united.com', '#002244', 'U', 'airplane', 10630, 'unitedairlines', ''),
  ('airasia', 'AirAsia', 'Travel', 'airasia.com', '#FF0000', 'A', 'airplane', 10640, 'airasia', ''),
  ('nvidia', 'NVIDIA', 'Tech', 'nvidia.com', '#76B900', 'N', 'desktopcomputer', 10650, 'nvidia', ''),
  ('gitlab', 'GitLab', 'Tech', 'gitlab.com', '#FC6D26', 'G', 'desktopcomputer', 10660, 'gitlab', ''),
  ('adobe', 'Adobe', 'Tech', 'adobe.com', '#FF0000', 'A', 'desktopcomputer', 10670, 'adobe', ''),
  ('opera', 'Opera', 'Tech', 'opera.com', '#FF1B2D', 'O', 'desktopcomputer', 10680, 'opera', ''),
  ('proton', 'Proton', 'Tech', 'proton.me', '#6D4AFF', 'P', 'desktopcomputer', 10690, 'proton', ''),
  ('xiaomi', 'Xiaomi', 'Tech', 'mi.com', '#FF6900', 'X', 'desktopcomputer', 10700, 'xiaomi', ''),
  ('razer', 'Razer', 'Tech', 'razer.com', '#44D62C', 'R', 'desktopcomputer', 10710, 'razer', ''),
  ('tradingview', 'TradingView', 'Finance', 'tradingview.com', '#2962FF', 'T', 'creditcard.fill', 10720, 'tradingview', ''),
  ('skype', 'Skype', 'Messaging', 'skype.com', '#00AFF0', 'S', 'bubble.left.and.bubble.right.fill', 10730, 'skype', ''),
  ('instacart', 'Instacart', 'Delivery', 'instacart.com', '#43B02A', 'I', 'takeoutbag.and.cup.and.straw.fill', 10740, 'instacart', ''),
  ('perplexity', 'Perplexity', 'AI', 'perplexity.ai', '#20808D', 'P', 'sparkles', 10750, 'perplexity', ''),
  ('deepseek', 'DeepSeek', 'AI', 'deepseek.com', '#4D6BFE', 'D', 'sparkles', 10760, 'deepseek', ''),
  ('mistral', 'Mistral AI', 'AI', 'mistral.ai', '#FA520F', 'M', 'sparkles', 10770, 'mistralai', ''),
  ('suno', 'Suno', 'AI', 'suno.com', '#000000', 'S', 'sparkles', 10780, 'suno', ''),
  ('roblox', 'Roblox', 'Entertainment', 'roblox.com', '#E2231A', 'R', 'gamecontroller.fill', 10790, 'roblox', ''),
  ('epicgames', 'Epic Games', 'Entertainment', 'epicgames.com', '#2A2A2A', 'E', 'gamecontroller.fill', 10800, 'epicgames', ''),
  ('nintendo', 'Nintendo', 'Entertainment', 'nintendo.com', '#E60012', 'N', 'gamecontroller.fill', 10810, 'nintendo', ''),
  ('ubisoft', 'Ubisoft', 'Entertainment', 'ubisoft.com', '#000000', 'U', 'gamecontroller.fill', 10820, 'ubisoft', ''),
  ('riotgames', 'Riot Games', 'Entertainment', 'riotgames.com', '#D32936', 'R', 'gamecontroller.fill', 10830, 'riotgames', ''),
  ('pubg', 'PUBG', 'Entertainment', 'pubg.com', '#F2A900', 'P', 'gamecontroller.fill', 10840, 'pubg', ''),
  ('garena', 'Garena', 'Entertainment', 'garena.com', '#EE3B33', 'G', 'gamecontroller.fill', 10850, 'garena', ''),
  ('faceit', 'FACEIT', 'Entertainment', 'faceit.com', '#FF5500', 'F', 'gamecontroller.fill', 10860, 'faceit', ''),
  ('bilibili', 'Bilibili', 'Entertainment', 'bilibili.com', '#00A1D6', 'B', 'gamecontroller.fill', 10870, 'bilibili', ''),
  ('spotify', 'Spotify', 'Entertainment', 'spotify.com', '#1DB954', 'S', 'gamecontroller.fill', 10880, 'spotify', ''),
  ('bereal', 'BeReal', 'Social', 'bereal.com', '#000000', 'B', 'person.2.fill', 10890, 'bereal', ''),
  ('bluesky', 'Bluesky', 'Social', 'bsky.app', '#0085FF', 'B', 'person.2.fill', 10900, 'bluesky', ''),
  ('nextdoor', 'Nextdoor', 'Social', 'nextdoor.com', '#8ED500', 'N', 'person.2.fill', 10910, 'nextdoor', ''),
  ('weibo', 'Weibo', 'Social', 'weibo.com', '#E6162D', 'W', 'person.2.fill', 10920, 'weibo', ''),
  ('medium', 'Medium', 'Social', 'medium.com', '#000000', 'M', 'person.2.fill', 10930, 'medium', ''),
  ('substack', 'Substack', 'Social', 'substack.com', '#FF6719', 'S', 'person.2.fill', 10940, 'substack', ''),
  ('upwork', 'Upwork', 'Productivity', 'upwork.com', '#14A800', 'U', 'briefcase.fill', 10950, 'upwork', ''),
  ('fiverr', 'Fiverr', 'Productivity', 'fiverr.com', '#1DBF73', 'F', 'briefcase.fill', 10960, 'fiverr', ''),
  ('indeed', 'Indeed', 'Productivity', 'indeed.com', '#2164F3', 'I', 'briefcase.fill', 10970, 'indeed', ''),
  ('eventbrite', 'Eventbrite', 'Specialty', 'eventbrite.com', '#F05537', 'E', 'star.fill', 10980, 'eventbrite', ''),
  ('gofundme', 'GoFundMe', 'Finance', 'gofundme.com', '#02A95C', 'G', 'creditcard.fill', 10990, 'gofundme', '')
  on conflict (id) do nothing
  returning id
)
insert into public.routes (service_id, country_id, provider, status)
select ins.id, c.id, '5sim', 'hidden'
  from ins
  cross join public.countries c
 where c.fivesim_country is not null
on conflict (service_id, country_id) do nothing;

do $$
declare
  v_services integer;
  v_routes   integer;
  v_bad      integer;
  v_countries integer;
begin
  select count(*) into v_services
    from public.services where sort_order >= 10000 and fivesim_product is not null;
  select count(*) into v_countries
    from public.countries where fivesim_country is not null;
  select count(*) into v_routes
    from public.routes r
    join public.services s on s.id = r.service_id
   where s.sort_order >= 10000 and r.provider = '5sim';

  if v_services <> 100 then
    raise exception 'expected 100 new services, found %', v_services;
  end if;
  if v_routes <> 100 * v_countries then
    raise exception 'expected % routes (100 x % countries), found %',
      100 * v_countries, v_countries, v_routes;
  end if;

  -- Nothing may be sellable yet: sync-5sim decides that, not this migration.
  select count(*) into v_bad
    from public.routes r
    join public.services s on s.id = r.service_id
   where s.sort_order >= 10000 and r.status <> 'hidden';
  if v_bad <> 0 then
    raise exception '% new routes are not hidden', v_bad;
  end if;

  -- Ownership must be 5sim, never the 'smspva' column default.
  select count(*) into v_bad
    from public.routes r
    join public.services s on s.id = r.service_id
   where s.sort_order >= 10000 and r.provider <> '5sim';
  if v_bad <> 0 then
    raise exception '% new routes have the wrong provider', v_bad;
  end if;

  raise notice 'added % services and % routes (all hidden, provider 5sim)',
    v_services, v_routes;
end $$;
