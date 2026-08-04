-- Batch 2: another 100 recognisable services 5sim already carries.
--
-- Follows 20260804200000, which added the first 100 and documents the four
-- traps in full. This file repeats the same shape; read that one for the
-- reasoning. Catalog goes 368 -> 468 services; ~930 5sim products remain after
-- this. Generated and validated by scripts/gen-fivesim-services.py, which
-- refuses to emit SQL unless every product exists in 5sim's live catalog, is
-- not already mapped, and does not collide with an existing services.id.
--
-- Short version of the four, because each fails SILENTLY:
--   1. routes must be seeded here -- sync-5sim only ever UPDATES rows it read;
--   2. seed status 'hidden' and provider '5sim', never the column defaults
--      ('active' / 'smspva'), because providerOrder() reads routes.provider;
--   3. smspva_code is '' and NOT null -- Service.swift declares it
--      non-optional, so a null takes the whole catalog down on shipped builds;
--   4. the id check is what catches brands we already carry under a different
--      5sim slug -- four did in batch 1.
--
-- Two categories here are used more heavily than in batch 1 -- Dating (8) and
-- Crypto (5). Both already exist in the catalog (15 and 5 rows), so no new
-- category string is introduced and the client's grouping is unaffected.
--
-- sort_order starts at 11000, above batch 1's 10000-10990 and every original
-- service (max 9840): 100 more untested services must not displace measured
-- ones in the browse list. They are reachable by search, which is how they are
-- actually found.

with ins as (
  insert into public.services
    (id, name, category, domain, tint_hex, glyph, icon, sort_order, fivesim_product, smspva_code)
  values
  ('lowes', 'Lowe''s', 'Commerce', 'lowes.com', '#004990', 'L', 'bag.fill', 11000, 'lowes', ''),
  ('samsclub', 'Sam''s Club', 'Commerce', 'samsclub.com', '#0067A0', 'S', 'bag.fill', 11010, 'samsclub', ''),
  ('publix', 'Publix', 'Commerce', 'publix.com', '#007A33', 'P', 'bag.fill', 11020, 'publix', ''),
  ('coles', 'Coles', 'Commerce', 'coles.com.au', '#E01A22', 'C', 'bag.fill', 11030, 'coles', ''),
  ('auchan', 'Auchan', 'Commerce', 'auchan.fr', '#E2001A', 'A', 'bag.fill', 11040, 'auchan', ''),
  ('metro', 'Metro', 'Commerce', 'metro.de', '#003D7D', 'M', 'bag.fill', 11050, 'metro', ''),
  ('boots', 'Boots', 'Commerce', 'boots.com', '#05054B', 'B', 'bag.fill', 11060, 'boots', ''),
  ('watsons', 'Watsons', 'Commerce', 'watsons.com', '#00A5A5', 'W', 'bag.fill', 11070, 'watsons', ''),
  ('jbhifi', 'JB Hi-Fi', 'Commerce', 'jbhifi.com.au', '#FFF200', 'J', 'bag.fill', 11080, 'jbhifi', ''),
  ('catawiki', 'Catawiki', 'Commerce', 'catawiki.com', '#0B4EA2', 'C', 'bag.fill', 11090, 'catawiki', ''),
  ('vestiaire', 'Vestiaire Collective', 'Commerce', 'vestiairecollective.com', '#000000', 'V', 'bag.fill', 11100, 'vestiairecollective', ''),
  ('willhaben', 'willhaben', 'Commerce', 'willhaben.at', '#F58220', 'W', 'bag.fill', 11110, 'willhaben', ''),
  ('shpock', 'Shpock', 'Commerce', 'shpock.com', '#00B3A4', 'S', 'bag.fill', 11120, 'shpock', ''),
  ('donedeal', 'DoneDeal', 'Commerce', 'donedeal.ie', '#E5322D', 'D', 'bag.fill', 11130, 'donedeal', ''),
  ('xianyu', 'Xianyu', 'Commerce', 'goofish.com', '#FFCC00', 'X', 'bag.fill', 11140, 'xianyu', ''),
  ('weidian', 'Weidian', 'Commerce', 'weidian.com', '#FF6F00', 'W', 'bag.fill', 11150, 'weidian', ''),
  ('alibaba-1688', '1688', 'Commerce', '1688.com', '#FF6A00', '1', 'bag.fill', 11160, '1688', ''),
  ('miravia', 'Miravia', 'Commerce', 'miravia.es', '#FF4D4D', 'M', 'bag.fill', 11170, 'miravia', ''),
  ('bigbasket', 'BigBasket', 'Commerce', 'bigbasket.com', '#84C225', 'B', 'bag.fill', 11180, 'bigbasket', ''),
  ('zepto', 'Zepto', 'Commerce', 'zeptonow.com', '#5C2D91', 'Z', 'bag.fill', 11190, 'zepto', ''),
  ('meituan', 'Meituan', 'Delivery', 'meituan.com', '#FFD100', 'M', 'takeoutbag.and.cup.and.straw.fill', 11200, 'meituan', ''),
  ('eleme', 'Ele.me', 'Delivery', 'ele.me', '#0099FF', 'E', 'takeoutbag.and.cup.and.straw.fill', 11210, 'eleme', ''),
  ('keeta', 'Keeta', 'Delivery', 'keeta.com', '#FFD100', 'K', 'takeoutbag.and.cup.and.straw.fill', 11220, 'keeta', ''),
  ('gopuff', 'Gopuff', 'Delivery', 'gopuff.com', '#00B2A9', 'G', 'takeoutbag.and.cup.and.straw.fill', 11230, 'gopuff', ''),
  ('picnic', 'Picnic', 'Delivery', 'picnic.app', '#E1071B', 'P', 'takeoutbag.and.cup.and.straw.fill', 11240, 'picnic', ''),
  ('flink', 'Flink', 'Delivery', 'goflink.com', '#FF5A00', 'F', 'takeoutbag.and.cup.and.straw.fill', 11250, 'flink', ''),
  ('hungerstation', 'HungerStation', 'Delivery', 'hungerstation.com', '#F9A01B', 'H', 'takeoutbag.and.cup.and.straw.fill', 11260, 'hungerstation', ''),
  ('snappfood', 'SnappFood', 'Delivery', 'snappfood.ir', '#FF00A6', 'S', 'takeoutbag.and.cup.and.straw.fill', 11270, 'snappfood', ''),
  ('nandos', 'Nando''s', 'Delivery', 'nandos.com', '#D51D29', 'N', 'takeoutbag.and.cup.and.straw.fill', 11280, 'nandos', ''),
  ('greggs', 'Greggs', 'Delivery', 'greggs.co.uk', '#00539F', 'G', 'takeoutbag.and.cup.and.straw.fill', 11290, 'greggs', ''),
  ('yango', 'Yango', 'Transport', 'yango.com', '#FFDD00', 'Y', 'car.fill', 11300, 'yango', ''),
  ('uklon', 'Uklon', 'Transport', 'uklon.com.ua', '#00A3E0', 'U', 'car.fill', 11310, 'uklon', ''),
  ('bykea', 'Bykea', 'Transport', 'bykea.com', '#00B140', 'B', 'car.fill', 11320, 'bykea', ''),
  ('swvl', 'Swvl', 'Transport', 'swvl.com', '#E4002B', 'S', 'car.fill', 11330, 'swvl', ''),
  ('dott', 'Dott', 'Transport', 'ridedott.com', '#1E3A8A', 'D', 'car.fill', 11340, 'dott', ''),
  ('tier', 'TIER', 'Transport', 'tier.app', '#00E676', 'T', 'car.fill', 11350, 'tier', ''),
  ('voi', 'Voi', 'Transport', 'voi.com', '#F26B5E', 'V', 'car.fill', 11360, 'voi', ''),
  ('tada', 'TADA', 'Transport', 'tada.global', '#00C4B3', 'T', 'car.fill', 11370, 'tada', ''),
  ('trip', 'Trip.com', 'Travel', 'trip.com', '#287DFA', 'T', 'airplane', 11380, 'trip', ''),
  ('tujia', 'Tujia', 'Travel', 'tujia.com', '#00B0A6', 'T', 'airplane', 11390, 'tujia', ''),
  ('tongcheng', 'Tongcheng Travel', 'Travel', 'ly.com', '#1E90FF', 'T', 'airplane', 11400, 'tongchengtravel', ''),
  ('vfsglobal', 'VFS Global', 'Travel', 'vfsglobal.com', '#003865', 'V', 'airplane', 11410, 'vfsglobal', ''),
  ('immoscout24', 'ImmoScout24', 'Travel', 'immobilienscout24.de', '#FF7300', 'I', 'airplane', 11420, 'immoscout24', ''),
  ('seloger', 'SeLoger', 'Travel', 'seloger.com', '#E2001A', 'S', 'airplane', 11430, 'seloger', ''),
  ('fotocasa', 'Fotocasa', 'Travel', 'fotocasa.es', '#00A0DF', 'F', 'airplane', 11440, 'fotocasa', ''),
  ('likee', 'Likee', 'Social', 'likee.video', '#FFCC00', 'L', 'person.2.fill', 11450, 'likee', ''),
  ('kwai', 'Kwai', 'Social', 'kwai.com', '#FF5000', 'K', 'person.2.fill', 11460, 'kwai', ''),
  ('lemon8', 'Lemon8', 'Social', 'lemon8-app.com', '#FFE411', 'L', 'person.2.fill', 11470, 'lemon8', ''),
  ('azar', 'Azar', 'Social', 'azarlive.com', '#3E5BFF', 'A', 'person.2.fill', 11480, 'azar', ''),
  ('band', 'BAND', 'Social', 'band.us', '#00C73C', 'B', 'person.2.fill', 11490, 'band', ''),
  ('tamtam', 'TamTam', 'Messaging', 'tamtam.chat', '#04A8F5', 'T', 'bubble.left.and.bubble.right.fill', 11500, 'tamtam', ''),
  ('botim', 'BOTIM', 'Messaging', 'botim.me', '#00B0FF', 'B', 'bubble.left.and.bubble.right.fill', 11510, 'botim', ''),
  ('dingtalk', 'DingTalk', 'Messaging', 'dingtalk.com', '#3296FA', 'D', 'bubble.left.and.bubble.right.fill', 11520, 'dingtalk', ''),
  ('blued', 'Blued', 'Social', 'blued.com', '#2D6CDF', 'B', 'person.2.fill', 11530, 'blued', ''),
  ('weverse', 'Weverse', 'Social', 'weverse.io', '#07F064', 'W', 'person.2.fill', 11540, 'weverse', ''),
  ('tantan', 'Tantan', 'Dating', 'tantanapp.com', '#FF4E6A', 'T', 'heart.fill', 11550, 'tantan', ''),
  ('hily', 'Hily', 'Dating', 'hily.com', '#7B2FF7', 'H', 'heart.fill', 11560, 'hily', ''),
  ('lovoo', 'LOVOO', 'Dating', 'lovoo.com', '#00A6E0', 'L', 'heart.fill', 11570, 'lovoo', ''),
  ('meetic', 'Meetic', 'Dating', 'meetic.fr', '#E6007E', 'M', 'heart.fill', 11580, 'meetic', ''),
  ('meetme', 'MeetMe', 'Dating', 'meetme.com', '#00AEEF', 'M', 'heart.fill', 11590, 'meetme', ''),
  ('taimi', 'Taimi', 'Dating', 'taimi.com', '#8E44AD', 'T', 'heart.fill', 11600, 'taimi', ''),
  ('muzz', 'Muzz', 'Dating', 'muzz.com', '#00B894', 'M', 'heart.fill', 11610, 'muzz', ''),
  ('ashleymadison', 'Ashley Madison', 'Dating', 'ashleymadison.com', '#B01116', 'A', 'heart.fill', 11620, 'ashleymadison', ''),
  ('iqiyi', 'iQIYI', 'Entertainment', 'iqiyi.com', '#00BE06', 'I', 'gamecontroller.fill', 11630, 'iqiyi', ''),
  ('wetv', 'WeTV', 'Entertainment', 'wetv.vip', '#FF6A00', 'W', 'gamecontroller.fill', 11640, 'wetv', ''),
  ('sonyliv', 'SonyLIV', 'Entertainment', 'sonyliv.com', '#00A3E0', 'S', 'gamecontroller.fill', 11650, 'sonyliv', ''),
  ('vidio', 'Vidio', 'Entertainment', 'vidio.com', '#00B0FF', 'V', 'gamecontroller.fill', 11660, 'vidio', ''),
  ('megogo', 'MEGOGO', 'Entertainment', 'megogo.net', '#7B1FA2', 'M', 'gamecontroller.fill', 11670, 'megogo', ''),
  ('ximalaya', 'Ximalaya', 'Entertainment', 'ximalaya.com', '#FF4B33', 'X', 'gamecontroller.fill', 11680, 'ximalaya', ''),
  ('huya', 'HUYA', 'Entertainment', 'huya.com', '#FF6600', 'H', 'gamecontroller.fill', 11690, 'huya', ''),
  ('douyu', 'DouYu', 'Entertainment', 'douyu.com', '#FF5D23', 'D', 'gamecontroller.fill', 11700, 'douyu', ''),
  ('bigolive', 'BIGO LIVE', 'Entertainment', 'bigo.tv', '#00C2FF', 'B', 'gamecontroller.fill', 11710, 'bigolive', ''),
  ('hoyoverse', 'HoYoverse', 'Entertainment', 'hoyoverse.com', '#4A90D9', 'H', 'gamecontroller.fill', 11720, 'hoyoverse', ''),
  ('supercell', 'Supercell', 'Entertainment', 'supercell.com', '#F4B223', 'S', 'gamecontroller.fill', 11730, 'supercell', ''),
  ('activision', 'Activision', 'Entertainment', 'activision.com', '#000000', 'A', 'gamecontroller.fill', 11740, 'activision', ''),
  ('g2g', 'G2G', 'Commerce', 'g2g.com', '#FF6B00', 'G', 'bag.fill', 11750, 'g2g', ''),
  ('cdkeys', 'CDKeys', 'Commerce', 'cdkeys.com', '#F5A623', 'C', 'bag.fill', 11760, 'cdkeys', ''),
  ('tcgplayer', 'TCGplayer', 'Commerce', 'tcgplayer.com', '#F37021', 'T', 'bag.fill', 11770, 'tcgplayer', ''),
  ('playerauctions', 'PlayerAuctions', 'Commerce', 'playerauctions.com', '#0F5B9E', 'P', 'bag.fill', 11780, 'playerauctions', ''),
  ('cryptocom', 'Crypto.com', 'Crypto', 'crypto.com', '#03316C', 'C', 'bitcoinsign.circle.fill', 11790, 'cryptocom', ''),
  ('gemini-exchange', 'Gemini', 'Crypto', 'gemini.com', '#00DCFA', 'G', 'bitcoinsign.circle.fill', 11800, 'gemini', ''),
  ('blockchain', 'Blockchain.com', 'Crypto', 'blockchain.com', '#1656E3', 'B', 'bitcoinsign.circle.fill', 11810, 'blockchain', ''),
  ('paxful', 'Paxful', 'Crypto', 'paxful.com', '#4A90E2', 'P', 'bitcoinsign.circle.fill', 11820, 'paxful', ''),
  ('bitso', 'Bitso', 'Crypto', 'bitso.com', '#0A2C4E', 'B', 'bitcoinsign.circle.fill', 11830, 'bitso', ''),
  ('polymarket', 'Polymarket', 'Finance', 'polymarket.com', '#1652F0', 'P', 'creditcard.fill', 11840, 'polymarket', ''),
  ('moomoo', 'moomoo', 'Finance', 'moomoo.com', '#FF6B00', 'M', 'creditcard.fill', 11850, 'moomoo', ''),
  ('mobikwik', 'MobiKwik', 'Finance', 'mobikwik.com', '#2C3E82', 'M', 'creditcard.fill', 11860, 'mobikwik', ''),
  ('gcash', 'GCash', 'Finance', 'gcash.com', '#007DFE', 'G', 'creditcard.fill', 11870, 'gcash', ''),
  ('maya', 'Maya', 'Finance', 'maya.ph', '#4CC55B', 'M', 'creditcard.fill', 11880, 'paymaya', ''),
  ('dana', 'DANA', 'Finance', 'dana.id', '#118EEA', 'D', 'creditcard.fill', 11890, 'dana', ''),
  ('monobank', 'monobank', 'Finance', 'monobank.ua', '#000000', 'M', 'creditcard.fill', 11900, 'monobank', ''),
  ('oraclecloud', 'Oracle Cloud', 'Tech', 'oracle.com', '#C74634', 'O', 'desktopcomputer', 11910, 'oraclecloud', ''),
  ('alibabacloud', 'Alibaba Cloud', 'Tech', 'alibabacloud.com', '#FF6A00', 'A', 'desktopcomputer', 11920, 'alibabacloud', ''),
  ('byteplus', 'BytePlus', 'Tech', 'byteplus.com', '#1664FF', 'B', 'desktopcomputer', 11930, 'byteplus', ''),
  ('okta', 'Okta', 'Tech', 'okta.com', '#007DC1', 'O', 'desktopcomputer', 11940, 'okta', ''),
  ('authy', 'Authy', 'Tech', 'authy.com', '#EC1C24', 'A', 'desktopcomputer', 11950, 'authy', ''),
  ('kaggle', 'Kaggle', 'Tech', 'kaggle.com', '#20BEFF', 'K', 'desktopcomputer', 11960, 'kaggle', ''),
  ('heygen', 'HeyGen', 'AI', 'heygen.com', '#7C3AED', 'H', 'sparkles', 11970, 'heygen', ''),
  ('codeium', 'Codeium', 'AI', 'codeium.com', '#09B6A2', 'C', 'sparkles', 11980, 'codeium', ''),
  ('genspark', 'Genspark', 'AI', 'genspark.ai', '#FF5A1F', 'G', 'sparkles', 11990, 'genspark', '')
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
  v_services integer; v_routes integer; v_bad integer; v_countries integer;
begin
  select count(*) into v_services
    from public.services where sort_order >= 11000 and fivesim_product is not null;
  select count(*) into v_countries
    from public.countries where fivesim_country is not null;
  select count(*) into v_routes
    from public.routes r join public.services s on s.id = r.service_id
   where s.sort_order >= 11000 and r.provider = '5sim';

  if v_services <> 100 then
    raise exception 'expected 100 new services, found %', v_services;
  end if;
  if v_routes <> 100 * v_countries then
    raise exception 'expected % routes, found %', 100 * v_countries, v_routes;
  end if;

  select count(*) into v_bad
    from public.routes r join public.services s on s.id = r.service_id
   where s.sort_order >= 11000 and (r.status <> 'hidden' or r.provider <> '5sim');
  if v_bad <> 0 then
    raise exception '% new routes are not hidden/5sim', v_bad;
  end if;

  -- No null smspva_code anywhere: one is enough to break catalog decode for
  -- every user on a shipped build.
  select count(*) into v_bad from public.services where smspva_code is null;
  if v_bad <> 0 then
    raise exception '% services have a null smspva_code', v_bad;
  end if;

  raise notice 'batch 2: added % services and % routes', v_services, v_routes;
end $$;
