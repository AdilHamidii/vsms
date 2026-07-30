-- HeroSMS mapping: provider identifiers + CHECK constraints.
--
-- Stage 1 of the SMSPVA -> HeroSMS replacement. Adds identifiers ONLY; nothing
-- routes to HeroSMS until providerOrder() is flipped. Zero user impact.
--
-- HeroSMS speaks SMS-Activate's handler_api: numeric country ids and short
-- service codes. `services.smspva_code` shares ZERO values with it, so this is a
-- full remap, not a rename. Mapping was built from HeroSMS's own UNAUTHENTICATED
-- getCountries/getServicesList (195 countries, 808 services), so the codes are
-- authoritative rather than inferred from docs.
--
-- Coverage measured 2026-07-30: 69/69 countries, 150/265 services, and
-- 99.4% of all lifetime orders. The unmapped services are long-tail with ~zero
-- volume; they simply cannot route to HeroSMS, which is why the CHECK below
-- keeps 'smspva' legal.
--
-- Both CHECK constraints enumerate providers and reject 'herosms' today. The
-- orders one is the dangerous one: begin_order charges BEFORE create-order's
-- final UPDATE, so a rejected value surfaces as a charged order that fails
-- order_persist_failed and refunds -- an invisible-looking 500.

alter table public.services  add column if not exists herosms_code text;
alter table public.countries add column if not exists herosms_id   integer;

comment on column public.services.herosms_code is
  'HeroSMS/SMS-Activate short service code (ig, wa, do=leboncoin). Null = not sellable via HeroSMS.';
comment on column public.countries.herosms_id is
  'HeroSMS/SMS-Activate numeric country id (16=UK, 187=USA, 33=Colombia).';

alter table public.routes drop constraint if exists routes_provider_check;
alter table public.routes add  constraint routes_provider_check
  check (provider in ('smspva','smspool','virtualsms','herosms'));
alter table public.orders drop constraint if exists orders_provider_check;
alter table public.orders add  constraint orders_provider_check
  check (provider in ('smspva','smspool','virtualsms','herosms'));

-- ── countries (69) ─────────────────────────────────────────────
update public.countries set herosms_id=155 where id='al';
update public.countries set herosms_id=39 where id='ar';
update public.countries set herosms_id=50 where id='at';
update public.countries set herosms_id=175 where id='au';
update public.countries set herosms_id=108 where id='ba';
update public.countries set herosms_id=60 where id='bd';
update public.countries set herosms_id=82 where id='be';
update public.countries set herosms_id=83 where id='bg';
update public.countries set herosms_id=92 where id='bo';
update public.countries set herosms_id=73 where id='br';
update public.countries set herosms_id=36 where id='ca';
update public.countries set herosms_id=173 where id='ch';
update public.countries set herosms_id=151 where id='cl';
update public.countries set herosms_id=41 where id='cm';
update public.countries set herosms_id=33 where id='co';
update public.countries set herosms_id=93 where id='cr';
update public.countries set herosms_id=77 where id='cy';
update public.countries set herosms_id=63 where id='cz';
update public.countries set herosms_id=43 where id='de';
update public.countries set herosms_id=172 where id='dk';
update public.countries set herosms_id=109 where id='do';
update public.countries set herosms_id=34 where id='ee';
update public.countries set herosms_id=56 where id='es';
update public.countries set herosms_id=163 where id='fi';
update public.countries set herosms_id=78 where id='fr';
update public.countries set herosms_id=128 where id='ge';
update public.countries set herosms_id=201 where id='gi';
update public.countries set herosms_id=129 where id='gr';
update public.countries set herosms_id=14 where id='hk';
update public.countries set herosms_id=45 where id='hr';
update public.countries set herosms_id=84 where id='hu';
update public.countries set herosms_id=6 where id='id';
update public.countries set herosms_id=23 where id='ie';
update public.countries set herosms_id=13 where id='il';
update public.countries set herosms_id=86 where id='it';
update public.countries set herosms_id=182 where id='jp';
update public.countries set herosms_id=8 where id='ke';
update public.countries set herosms_id=11 where id='kg';
update public.countries set herosms_id=24 where id='kh';
update public.countries set herosms_id=2 where id='kz';
update public.countries set herosms_id=44 where id='lt';
update public.countries set herosms_id=49 where id='lv';
update public.countries set herosms_id=37 where id='ma';
update public.countries set herosms_id=85 where id='md';
update public.countries set herosms_id=183 where id='mk';
update public.countries set herosms_id=199 where id='mt';
update public.countries set herosms_id=54 where id='mx';
update public.countries set herosms_id=7 where id='my';
update public.countries set herosms_id=48 where id='nl';
update public.countries set herosms_id=67 where id='nz';
update public.countries set herosms_id=4 where id='ph';
update public.countries set herosms_id=66 where id='pk';
update public.countries set herosms_id=15 where id='pl';
update public.countries set herosms_id=117 where id='pt';
update public.countries set herosms_id=87 where id='py';
update public.countries set herosms_id=32 where id='ro';
update public.countries set herosms_id=29 where id='rs';
update public.countries set herosms_id=46 where id='se';
update public.countries set herosms_id=196 where id='sg';
update public.countries set herosms_id=59 where id='si';
update public.countries set herosms_id=141 where id='sk';
update public.countries set herosms_id=52 where id='th';
update public.countries set herosms_id=62 where id='tr';
update public.countries set herosms_id=9 where id='tz';
update public.countries set herosms_id=1 where id='ua';
update public.countries set herosms_id=16 where id='uk';
update public.countries set herosms_id=187 where id='us';
update public.countries set herosms_id=10 where id='vn';
update public.countries set herosms_id=31 where id='za';

-- ── services (150) ──────────────────────────────────────────────
update public.services set herosms_code='uk' where id='airbnb';
update public.services set herosms_code='hw' where id='alibaba';
update public.services set herosms_code='am' where id='amazon';
update public.services set herosms_code='pm' where id='aol';
update public.services set herosms_code='wx' where id='apple-id';
update public.services set herosms_code='wx' where id='apple-music';
update public.services set herosms_code='gr' where id='astropay';
update public.services set herosms_code='qv' where id='badoo';
update public.services set herosms_code='cb' where id='bazos';
update public.services set herosms_code='ov' where id='beget';
update public.services set herosms_code='ie' where id='bet365';
update public.services set herosms_code='agl' where id='betano';
update public.services set herosms_code='vd' where id='betfair';
update public.services set herosms_code='bz' where id='blizzard';
update public.services set herosms_code='tx' where id='bolt';
update public.services set herosms_code='aiz' where id='brevo';
update public.services set herosms_code='mo' where id='bumble';
update public.services set herosms_code='ahe' where id='bunq';
update public.services set herosms_code='apr' where id='capital-one';
update public.services set herosms_code='ls' where id='careem';
update public.services set herosms_code='brc' where id='casa-it';
update public.services set herosms_code='azy' where id='casa-pariurilor';
update public.services set herosms_code='boo' where id='casino-plus';
update public.services set herosms_code='acz' where id='claude';
update public.services set herosms_code='et' where id='clubhouse';
update public.services set herosms_code='re' where id='coinbase';
update public.services set herosms_code='wc' where id='craigslist';
update public.services set herosms_code='aje' where id='cupidmedia';
update public.services set herosms_code='zk' where id='deliveroo';
update public.services set herosms_code='xk' where id='didi';
update public.services set herosms_code='ds' where id='discord';
update public.services set herosms_code='ac' where id='doordash';
update public.services set herosms_code='we' where id='drug-vokrug';
update public.services set herosms_code='uf' where id='eneba';
update public.services set herosms_code='bcr' where id='esx';
update public.services set herosms_code='bhz' where id='eurobet';
update public.services set herosms_code='fb' where id='facebook';
update public.services set herosms_code='ws' where id='feeld';
update public.services set herosms_code='abe' where id='foodora';
update public.services set herosms_code='nz' where id='foodpanda';
update public.services set herosms_code='uz' where id='gamers-set';
update public.services set herosms_code='aq' where id='glovo';
update public.services set herosms_code='go' where id='google';
update public.services set herosms_code='ccu' where id='google-chat';
update public.services set herosms_code='ccx' where id='google-messenger';
update public.services set herosms_code='gf' where id='google-voice';
update public.services set herosms_code='jg' where id='grab';
update public.services set herosms_code='agd' where id='grailed';
update public.services set herosms_code='yw' where id='grindr';
update public.services set herosms_code='df' where id='happn';
update public.services set herosms_code='gx' where id='hepsiburada';
update public.services set herosms_code='vz' where id='hinge';
update public.services set herosms_code='kk' where id='idealista';
update public.services set herosms_code='pd' where id='ifood';
update public.services set herosms_code='im' where id='imo';
update public.services set herosms_code='ig' where id='instagram';
update public.services set herosms_code='il' where id='iqos';
update public.services set herosms_code='za' where id='jd-com';
update public.services set herosms_code='kt' where id='kakaotalk';
update public.services set herosms_code='afz' where id='klarna';
update public.services set herosms_code='aop' where id='kleinanzeigen';
update public.services set herosms_code='aid' where id='kwiff';
update public.services set herosms_code='fh' where id='lalamove';
update public.services set herosms_code='dl' where id='lazada';
update public.services set herosms_code='do' where id='leboncoin';
update public.services set herosms_code='me' where id='line';
update public.services set herosms_code='tn' where id='linkedin';
update public.services set herosms_code='ex' where id='linode';
update public.services set herosms_code='tu' where id='lyft';
update public.services set herosms_code='mg' where id='magnit';
update public.services set herosms_code='ma' where id='mail-ru';
update public.services set herosms_code='fd' where id='mamba';
update public.services set herosms_code='agj' where id='marktplaats';
update public.services set herosms_code='axr' where id='match';
update public.services set herosms_code='bpq' where id='michat';
update public.services set herosms_code='mm' where id='microsoft';
update public.services set herosms_code='bry' where id='mobile-de';
update public.services set herosms_code='hc' where id='momo';
update public.services set herosms_code='py' where id='monese';
update public.services set herosms_code='qo' where id='moneylion';
update public.services set herosms_code='nv' where id='naver';
update public.services set herosms_code='aok' where id='neteller';
update public.services set herosms_code='nf' where id='netflix';
update public.services set herosms_code='zm' where id='offerup';
update public.services set herosms_code='vm' where id='okcupid';
update public.services set herosms_code='aor' where id='okx';
update public.services set herosms_code='sn' where id='olx';
update public.services set herosms_code='ue' where id='onet';
update public.services set herosms_code='dr' where id='openai';
update public.services set herosms_code='auz' where id='outlier';
update public.services set herosms_code='sg' where id='ozon';
update public.services set herosms_code='cw' where id='paddy-power';
update public.services set herosms_code='bla' where id='parions-sport';
update public.services set herosms_code='nc' where id='payoneer';
update public.services set herosms_code='ts' where id='paypal';
update public.services set herosms_code='jq' where id='paysafecard';
update public.services set herosms_code='tr' where id='paysend';
update public.services set herosms_code='pf' where id='pof';
update public.services set herosms_code='alo' where id='profee';
update public.services set herosms_code='dp' where id='protonmail';
update public.services set herosms_code='aga' where id='publi24';
update public.services set herosms_code='bnl' where id='reddit';
update public.services set herosms_code='aiv' where id='remitly';
update public.services set herosms_code='ij' where id='revolut';
update public.services set herosms_code='afn' where id='roomster';
update public.services set herosms_code='jr' where id='samokat';
update public.services set herosms_code='ka' where id='shopee';
update public.services set herosms_code='bw' where id='signal';
update public.services set herosms_code='bmi' where id='sisal';
update public.services set herosms_code='aps' where id='skelbiu';
update public.services set herosms_code='wg' where id='skout';
update public.services set herosms_code='aqt' where id='skrill';
update public.services set herosms_code='fu' where id='snapchat';
update public.services set herosms_code='bai' where id='snkrdunk';
update public.services set herosms_code='mt' where id='steam';
update public.services set herosms_code='lc' where id='subito';
update public.services set herosms_code='avj' where id='sumup';
update public.services set herosms_code='ayr' where id='superbet';
update public.services set herosms_code='xr' where id='tango';
update public.services set herosms_code='tg' where id='telegram';
update public.services set herosms_code='qq' where id='tencent-qq';
update public.services set herosms_code='gp' where id='ticketmaster';
update public.services set herosms_code='lf' where id='tiktok';
update public.services set herosms_code='oi' where id='tinder';
update public.services set herosms_code='mw' where id='transfergo';
update public.services set herosms_code='tl' where id='truecaller';
update public.services set herosms_code='ada' where id='truth-social';
update public.services set herosms_code='ee' where id='twilio';
update public.services set herosms_code='hb' where id='twitch';
update public.services set herosms_code='hb' where id='twitch-ent';
update public.services set herosms_code='tw' where id='twitter-x';
update public.services set herosms_code='ub' where id='uber';
update public.services set herosms_code='vi' where id='viber';
update public.services set herosms_code='kc' where id='vinted';
update public.services set herosms_code='atp' where id='vonage';
update public.services set herosms_code='bmd' where id='voov';
update public.services set herosms_code='bbr' where id='walletub';
update public.services set herosms_code='wr' where id='walmart';
update public.services set herosms_code='abo' where id='web-de';
update public.services set herosms_code='wb' where id='wechat';
update public.services set herosms_code='bex' where id='whatnot';
update public.services set herosms_code='wa' where id='whatsapp';
update public.services set herosms_code='qj' where id='whoosh';
update public.services set herosms_code='bo' where id='wise';
update public.services set herosms_code='rr' where id='wolt';
update public.services set herosms_code='ama' where id='wooplus';
update public.services set herosms_code='mb' where id='yahoo';
update public.services set herosms_code='ya' where id='yandex';
update public.services set herosms_code='zh' where id='zoho';
update public.services set herosms_code='zh' where id='zoho-prod';

-- Assertions. Fail loudly here rather than at order time.
do $$
declare n_c int; n_s int; n_vol int;
begin
  select count(*) into n_c from public.countries where herosms_id is null;
  select count(*) into n_s from public.services  where herosms_code is null;
  select count(*) into n_vol from public.services s
   where s.herosms_code is null
     and exists (select 1 from public.orders o where o.service_id = s.id);
  raise notice 'herosms mapping: % countries unmapped, % services unmapped, % of them have order history', n_c, n_s, n_vol;
  if n_c > 1 then
    raise exception 'country mapping regressed: % unmapped (expected at most 1)', n_c;
  end if;
end $$;
