-- 5sim.net mapping: our catalog ids -> 5sim's own product/country slugs.
--
-- 5sim is becoming the sole SMS provider (owner decision, 2026-08-03). The reason
-- is that its public, UNAUTHENTICATED price feed publishes a per-POOL delivery
-- rate, which no provider we have used has ever exposed by API:
--
--   GET https://5sim.net/v1/guest/prices
--   -> country -> product -> operator -> {cost, count, rate, rate1, rate3,
--                                         rate24, rate72, rate168, rate720}
--
-- (suffix = hours; 155 countries, 1,573 products, 171,803 rows, 53,277 in stock).
-- That lets create-order buy from the best-delivering pool instead of whatever
-- the provider happens to hand back, which is the single lever we have never had.
--
-- COVERAGE, measured 2026-08-03 against the live feed:
--   services  150 of 268 mapped        countries  61 of 69 mapped
--   sellable (service,country) pairs on 5sim: 5,289
--
-- The 118 unmapped services are genuinely ABSENT from 5sim, not a matcher
-- failure -- qiwi, avito, vk, ozon, coinbase, payoneer, binance, klarna,
-- cashapp, neteller, okcupid and vonage were each probed by hand against the
-- full 1,573-product list and none exists. But they carry almost no demand:
-- 5sim covers 96.1% of every order ever placed (249 of 259, dev excluded).
--
-- KNOWN LOSSES, listed rather than discovered later:
--   ggbet         9 orders   no 5sim product
--   yandex        1 order    5sim has only 'yandexmoney', a different service
--   Switzerland  14 orders (5 codes)  not a 5sim country
--   Turkey        8 orders (0 codes)  not a 5sim country
--   ba, gi, jp, mt, nz, sg               not 5sim countries, zero order history
-- Their routes are NOT deleted -- they keep their existing provider and simply
-- have no 5sim code, which is exactly what NULL means here.
--
-- Shared products are legal and expected: apple-id and apple-music both map to
-- 'apple', the same fan-out HeroSMS needed for 'wx'. sync-5sim writes one route
-- per (service, country), so both services get their own row from one quote.

alter table public.services  add column if not exists fivesim_product text;
alter table public.countries add column if not exists fivesim_country text;

comment on column public.services.fivesim_product is
  '5sim product slug (facebook, leboncoin, tencentqq). NULL = not sellable via 5sim.';
comment on column public.countries.fivesim_country is
  '5sim country slug (usa, england, czech, dominicana). Text, not an integer -- unlike countries.herosms_id. NULL = not sellable via 5sim.';

-- Both CHECK constraints must admit the new name. orders_provider_check is the
-- dangerous half: begin_order charges BEFORE create-order writes the provider,
-- so a rejected value is a charged order, order_persist_failed, and a refund.
alter table public.routes drop constraint if exists routes_provider_check;
alter table public.routes add constraint routes_provider_check
  check (provider in ('smspva','smspool','virtualsms','herosms','5sim'));
alter table public.orders drop constraint if exists orders_provider_check;
alter table public.orders add constraint orders_provider_check
  check (provider in ('smspva','smspool','virtualsms','herosms','5sim'));

-- ---- countries (61) ----
update public.countries set fivesim_country = 'albania' where id = 'al';
update public.countries set fivesim_country = 'argentina' where id = 'ar';
update public.countries set fivesim_country = 'austria' where id = 'at';
update public.countries set fivesim_country = 'australia' where id = 'au';
update public.countries set fivesim_country = 'bangladesh' where id = 'bd';
update public.countries set fivesim_country = 'belgium' where id = 'be';
update public.countries set fivesim_country = 'bulgaria' where id = 'bg';
update public.countries set fivesim_country = 'bolivia' where id = 'bo';
update public.countries set fivesim_country = 'brazil' where id = 'br';
update public.countries set fivesim_country = 'canada' where id = 'ca';
update public.countries set fivesim_country = 'chile' where id = 'cl';
update public.countries set fivesim_country = 'cameroon' where id = 'cm';
update public.countries set fivesim_country = 'colombia' where id = 'co';
update public.countries set fivesim_country = 'costarica' where id = 'cr';
update public.countries set fivesim_country = 'cyprus' where id = 'cy';
update public.countries set fivesim_country = 'czech' where id = 'cz';
update public.countries set fivesim_country = 'germany' where id = 'de';
update public.countries set fivesim_country = 'denmark' where id = 'dk';
update public.countries set fivesim_country = 'dominicana' where id = 'do';
update public.countries set fivesim_country = 'estonia' where id = 'ee';
update public.countries set fivesim_country = 'spain' where id = 'es';
update public.countries set fivesim_country = 'finland' where id = 'fi';
update public.countries set fivesim_country = 'france' where id = 'fr';
update public.countries set fivesim_country = 'georgia' where id = 'ge';
update public.countries set fivesim_country = 'greece' where id = 'gr';
update public.countries set fivesim_country = 'hongkong' where id = 'hk';
update public.countries set fivesim_country = 'croatia' where id = 'hr';
update public.countries set fivesim_country = 'hungary' where id = 'hu';
update public.countries set fivesim_country = 'indonesia' where id = 'id';
update public.countries set fivesim_country = 'ireland' where id = 'ie';
update public.countries set fivesim_country = 'israel' where id = 'il';
update public.countries set fivesim_country = 'italy' where id = 'it';
update public.countries set fivesim_country = 'kenya' where id = 'ke';
update public.countries set fivesim_country = 'kyrgyzstan' where id = 'kg';
update public.countries set fivesim_country = 'cambodia' where id = 'kh';
update public.countries set fivesim_country = 'kazakhstan' where id = 'kz';
update public.countries set fivesim_country = 'lithuania' where id = 'lt';
update public.countries set fivesim_country = 'latvia' where id = 'lv';
update public.countries set fivesim_country = 'morocco' where id = 'ma';
update public.countries set fivesim_country = 'moldova' where id = 'md';
update public.countries set fivesim_country = 'northmacedonia' where id = 'mk';
update public.countries set fivesim_country = 'mexico' where id = 'mx';
update public.countries set fivesim_country = 'malaysia' where id = 'my';
update public.countries set fivesim_country = 'netherlands' where id = 'nl';
update public.countries set fivesim_country = 'philippines' where id = 'ph';
update public.countries set fivesim_country = 'pakistan' where id = 'pk';
update public.countries set fivesim_country = 'poland' where id = 'pl';
update public.countries set fivesim_country = 'portugal' where id = 'pt';
update public.countries set fivesim_country = 'paraguay' where id = 'py';
update public.countries set fivesim_country = 'romania' where id = 'ro';
update public.countries set fivesim_country = 'serbia' where id = 'rs';
update public.countries set fivesim_country = 'sweden' where id = 'se';
update public.countries set fivesim_country = 'slovenia' where id = 'si';
update public.countries set fivesim_country = 'slovakia' where id = 'sk';
update public.countries set fivesim_country = 'thailand' where id = 'th';
update public.countries set fivesim_country = 'tanzania' where id = 'tz';
update public.countries set fivesim_country = 'ukraine' where id = 'ua';
update public.countries set fivesim_country = 'england' where id = 'uk';
update public.countries set fivesim_country = 'usa' where id = 'us';
update public.countries set fivesim_country = 'vietnam' where id = 'vn';
update public.countries set fivesim_country = 'southafrica' where id = 'za';

-- ---- services (150) ----
update public.services set fivesim_product = 'abbott' where id = 'abbott';
update public.services set fivesim_product = 'airbnb' where id = 'airbnb';
update public.services set fivesim_product = 'alibaba' where id = 'alibaba';
update public.services set fivesim_product = 'amazon' where id = 'amazon';
update public.services set fivesim_product = 'aol' where id = 'aol';
update public.services set fivesim_product = 'apple' where id = 'apple-id';
update public.services set fivesim_product = 'apple' where id = 'apple-music';
update public.services set fivesim_product = 'astropay' where id = 'astropay';
update public.services set fivesim_product = 'badoo' where id = 'badoo';
update public.services set fivesim_product = 'bazos' where id = 'bazos';
update public.services set fivesim_product = 'bcgame' where id = 'bc-game';
update public.services set fivesim_product = 'bestbuy' where id = 'best-buy';
update public.services set fivesim_product = 'bet365' where id = 'bet365';
update public.services set fivesim_product = 'betano' where id = 'betano';
update public.services set fivesim_product = 'betfair' where id = 'betfair';
update public.services set fivesim_product = 'blizzard' where id = 'blizzard';
update public.services set fivesim_product = 'bolt' where id = 'bolt';
update public.services set fivesim_product = 'brevo' where id = 'brevo';
update public.services set fivesim_product = 'bumble' where id = 'bumble';
update public.services set fivesim_product = 'bwin' where id = 'bwin';
update public.services set fivesim_product = 'capitaloneshopping' where id = 'capital-one';
update public.services set fivesim_product = 'careem' where id = 'careem';
update public.services set fivesim_product = '888casino' where id = 'cas-888';
update public.services set fivesim_product = 'casinoplus' where id = 'casino-plus';
update public.services set fivesim_product = 'chotot' where id = 'chotot';
update public.services set fivesim_product = 'clubhouse' where id = 'clubhouse';
update public.services set fivesim_product = 'craigslist' where id = 'craigslist';
update public.services set fivesim_product = 'deliveroo' where id = 'deliveroo';
update public.services set fivesim_product = 'didi' where id = 'didi';
update public.services set fivesim_product = 'discord' where id = 'discord';
update public.services set fivesim_product = 'distrokid' where id = 'distrokid';
update public.services set fivesim_product = 'doordash' where id = 'doordash';
update public.services set fivesim_product = 'dundle' where id = 'dundle';
update public.services set fivesim_product = 'easypay' where id = 'easypay';
update public.services set fivesim_product = 'eneba' where id = 'eneba';
update public.services set fivesim_product = 'eurobet' where id = 'eurobet';
update public.services set fivesim_product = 'facebook' where id = 'facebook';
update public.services set fivesim_product = 'fastmail' where id = 'fastmail';
update public.services set fivesim_product = 'feeld' where id = 'feeld';
update public.services set fivesim_product = 'foodora' where id = 'foodora';
update public.services set fivesim_product = 'foodpanda' where id = 'foodpanda';
update public.services set fivesim_product = 'gameflip' where id = 'gameflip';
update public.services set fivesim_product = 'offgamers' where id = 'gamers-set';
update public.services set fivesim_product = 'ggpoker' where id = 'ggpoker';
update public.services set fivesim_product = 'glovo' where id = 'glovo';
update public.services set fivesim_product = 'goldbet' where id = 'goldbet';
update public.services set fivesim_product = 'google' where id = 'google';
update public.services set fivesim_product = 'googlevoice' where id = 'google-voice';
update public.services set fivesim_product = 'grailed' where id = 'grailed';
update public.services set fivesim_product = 'grindr' where id = 'grindr';
update public.services set fivesim_product = 'happn' where id = 'happn';
update public.services set fivesim_product = 'hellotalk' where id = 'hellotalk';
update public.services set fivesim_product = 'hinge' where id = 'hinge';
update public.services set fivesim_product = 'hopper' where id = 'hopper';
update public.services set fivesim_product = 'huawei' where id = 'huawei';
update public.services set fivesim_product = 'icard' where id = 'icard';
update public.services set fivesim_product = 'idealista' where id = 'idealista';
update public.services set fivesim_product = 'ifood' where id = 'ifood';
update public.services set fivesim_product = 'imo' where id = 'imo';
update public.services set fivesim_product = 'inboxlv' where id = 'inbox-lv';
update public.services set fivesim_product = 'instagram' where id = 'instagram';
update public.services set fivesim_product = 'iqos' where id = 'iqos';
update public.services set fivesim_product = 'kakaotalk' where id = 'kakaotalk';
update public.services set fivesim_product = 'kwiff' where id = 'kwiff';
update public.services set fivesim_product = 'lalamove' where id = 'lalamove';
update public.services set fivesim_product = 'laposte' where id = 'laposte';
update public.services set fivesim_product = 'lazada' where id = 'lazada';
update public.services set fivesim_product = 'leboncoin' where id = 'leboncoin';
update public.services set fivesim_product = 'line' where id = 'line';
update public.services set fivesim_product = 'linkedin' where id = 'linkedin';
update public.services set fivesim_product = 'linode' where id = 'linode';
update public.services set fivesim_product = 'livescore' where id = 'livescore';
update public.services set fivesim_product = 'lyft' where id = 'lyft';
update public.services set fivesim_product = 'marktplaats' where id = 'marktplaats';
update public.services set fivesim_product = 'match' where id = 'match';
update public.services set fivesim_product = 'mercari' where id = 'mercari';
update public.services set fivesim_product = 'michat' where id = 'michat';
update public.services set fivesim_product = 'microsoft' where id = 'microsoft';
update public.services set fivesim_product = 'mobilede' where id = 'mobile-de';
update public.services set fivesim_product = 'momo' where id = 'momo';
update public.services set fivesim_product = 'monese' where id = 'monese';
update public.services set fivesim_product = 'moneylion' where id = 'moneylion';
update public.services set fivesim_product = 'monsterenergy' where id = 'monster-energy';
update public.services set fivesim_product = 'mrgreen' where id = 'mrgreen';
update public.services set fivesim_product = 'naver' where id = 'naver';
update public.services set fivesim_product = 'netflix' where id = 'netflix';
update public.services set fivesim_product = 'offerup' where id = 'offerup';
update public.services set fivesim_product = 'okx' where id = 'okx';
update public.services set fivesim_product = 'olx' where id = 'olx';
update public.services set fivesim_product = 'onet' where id = 'onet';
update public.services set fivesim_product = 'openai' where id = 'openai';
update public.services set fivesim_product = 'outlier' where id = 'outlier';
update public.services set fivesim_product = 'paddypower' where id = 'paddy-power';
update public.services set fivesim_product = 'parimatch' where id = 'parimatch';
update public.services set fivesim_product = 'paypal' where id = 'paypal';
update public.services set fivesim_product = 'paysafecard' where id = 'paysafecard';
update public.services set fivesim_product = 'paysend' where id = 'paysend';
update public.services set fivesim_product = 'pof' where id = 'pof';
update public.services set fivesim_product = 'protonmail' where id = 'protonmail';
update public.services set fivesim_product = 'radquest' where id = 'radquest';
update public.services set fivesim_product = 'reddit' where id = 'reddit';
update public.services set fivesim_product = 'revolut' where id = 'revolut';
update public.services set fivesim_product = 'shopee' where id = 'shopee';
update public.services set fivesim_product = 'signal' where id = 'signal';
update public.services set fivesim_product = 'sisal' where id = 'sisal';
update public.services set fivesim_product = 'skelbiu' where id = 'skelbiu';
update public.services set fivesim_product = 'skout' where id = 'skout';
update public.services set fivesim_product = 'skrill' where id = 'skrill';
update public.services set fivesim_product = 'snapchat' where id = 'snapchat';
update public.services set fivesim_product = 'snkrdunk' where id = 'snkrdunk';
update public.services set fivesim_product = 'steam' where id = 'steam';
update public.services set fivesim_product = 'subito' where id = 'subito';
update public.services set fivesim_product = 'superbet' where id = 'superbet';
update public.services set fivesim_product = 'swagbucks' where id = 'swagbucks';
update public.services set fivesim_product = 'tango' where id = 'tango';
update public.services set fivesim_product = 'telegram' where id = 'telegram';
update public.services set fivesim_product = 'tencentqq' where id = 'tencent-qq';
update public.services set fivesim_product = 'ticketmaster' where id = 'ticketmaster';
update public.services set fivesim_product = 'tiktok' where id = 'tiktok';
update public.services set fivesim_product = 'tinder' where id = 'tinder';
update public.services set fivesim_product = 'truecaller' where id = 'truecaller';
update public.services set fivesim_product = 'truthsocial' where id = 'truth-social';
update public.services set fivesim_product = 'twilio' where id = 'twilio';
update public.services set fivesim_product = 'twitch' where id = 'twitch';
update public.services set fivesim_product = 'twitch' where id = 'twitch-ent';
update public.services set fivesim_product = 'twitter' where id = 'twitter-x';
update public.services set fivesim_product = 'uber' where id = 'uber';
update public.services set fivesim_product = 'venmo' where id = 'venmo';
update public.services set fivesim_product = 'verse' where id = 'verse';
update public.services set fivesim_product = 'viber' where id = 'viber';
update public.services set fivesim_product = 'vinted' where id = 'vinted';
update public.services set fivesim_product = 'voovmeeting' where id = 'voov';
update public.services set fivesim_product = 'walmart' where id = 'walmart';
update public.services set fivesim_product = 'webde' where id = 'web-de';
update public.services set fivesim_product = 'webmoney' where id = 'webmoney';
update public.services set fivesim_product = 'wechat' where id = 'wechat';
update public.services set fivesim_product = 'weststein' where id = 'weststein';
update public.services set fivesim_product = 'whatnot' where id = 'whatnot';
update public.services set fivesim_product = 'whatsapp' where id = 'whatsapp';
update public.services set fivesim_product = 'wingmoney' where id = 'wing-money';
update public.services set fivesim_product = 'wise' where id = 'wise';
update public.services set fivesim_product = 'wolt' where id = 'wolt';
update public.services set fivesim_product = 'wooplus' where id = 'wooplus';
update public.services set fivesim_product = 'yahoo' where id = 'yahoo';
update public.services set fivesim_product = 'yandexmoney' where id = 'yandex-money';
update public.services set fivesim_product = 'zalo' where id = 'zalo';
update public.services set fivesim_product = 'zasilkovna' where id = 'zasilkovna';
update public.services set fivesim_product = 'zoho' where id = 'zoho';
update public.services set fivesim_product = 'zoho' where id = 'zoho-prod';
update public.services set fivesim_product = 'zoominfo' where id = 'zoominfo';

-- Assertions raise rather than warn: a silent mapping regression is how a
-- provider switch loses inventory nobody notices for days.
do $$
declare n_c int; n_s int;
begin
  select count(*) into n_c from public.countries where fivesim_country is not null;
  select count(*) into n_s from public.services  where fivesim_product is not null;
  if n_c <> 61 then raise exception 'country mapping regressed: % mapped, expected 61', n_c; end if;
  if n_s <> 150 then raise exception 'service mapping regressed: % mapped, expected 150', n_s; end if;
  -- Every service that has EVER been ordered must be mapped, or be a listed loss.
  if exists (
    select 1 from public.services s
    where s.fivesim_product is null
      and exists (select 1 from public.orders o where o.service_id = s.id)
      and s.id not in ('ggbet','yandex')
  ) then
    raise exception 'a service with order history is unmapped and not a declared loss';
  end if;
end $$;
