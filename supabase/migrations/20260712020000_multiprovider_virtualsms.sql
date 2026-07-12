-- Multi-provider migration: add virtualsms.io (real-SIM) alongside SMSPVA.
-- Adds provider columns + per-provider codes. Order-routing (create/check/
-- cancel/poll) will prefer virtualsms where it has a code and fall back to
-- SMSPVA on failure/'Provider temporarily unavailable'. Pricing stays 5x
-- (credits = ceil(cost/0.10)) → ~65% net at Apple's 15% Small-Business fee.
-- 30 services mapped to virtualsms short codes; 69 countries to ISO alpha-2.

alter table public.services  add column if not exists virtualsms_code text;
alter table public.countries add column if not exists virtualsms_code text;
alter table public.orders    add column if not exists provider text not null default 'smspva';
alter table public.routes    add column if not exists provider text not null default 'smspva';
alter table public.routes    add column if not exists stock int;

-- service code mappings
update public.services set virtualsms_code='am' where id='amazon';
update public.services set virtualsms_code='ap' where id='apple-id';
update public.services set virtualsms_code='bn' where id='binance';
update public.services set virtualsms_code='bm' where id='bumble';
update public.services set virtualsms_code='ca' where id='cashapp';
update public.services set virtualsms_code='cb' where id='coinbase';
update public.services set virtualsms_code='dc' where id='discord';
update public.services set virtualsms_code='dd' where id='doordash';
update public.services set virtualsms_code='fb' where id='facebook';
update public.services set virtualsms_code='gm' where id='google';
update public.services set virtualsms_code='hn' where id='hinge';
update public.services set virtualsms_code='ig' where id='instagram';
update public.services set virtualsms_code='li' where id='linkedin';
update public.services set virtualsms_code='ly' where id='lyft';
update public.services set virtualsms_code='ms' where id='microsoft';
update public.services set virtualsms_code='nf' where id='netflix';
update public.services set virtualsms_code='ok' where id='okx';
update public.services set virtualsms_code='ai' where id='openai';
update public.services set virtualsms_code='pp' where id='paypal';
update public.services set virtualsms_code='sc' where id='snapchat';
update public.services set virtualsms_code='st' where id='steam';
update public.services set virtualsms_code='tg' where id='telegram';
update public.services set virtualsms_code='tt' where id='tiktok';
update public.services set virtualsms_code='td' where id='tinder';
update public.services set virtualsms_code='tw' where id='twitter-x';
update public.services set virtualsms_code='ub' where id='uber';
update public.services set virtualsms_code='vm' where id='venmo';
update public.services set virtualsms_code='wm' where id='walmart';
update public.services set virtualsms_code='wa' where id='whatsapp';
update public.services set virtualsms_code='yh' where id='yahoo';

-- country code mappings (ISO alpha-2)
update public.countries set virtualsms_code='AL' where id='al';
update public.countries set virtualsms_code='AR' where id='ar';
update public.countries set virtualsms_code='AT' where id='at';
update public.countries set virtualsms_code='AU' where id='au';
update public.countries set virtualsms_code='BA' where id='ba';
update public.countries set virtualsms_code='BD' where id='bd';
update public.countries set virtualsms_code='BE' where id='be';
update public.countries set virtualsms_code='BG' where id='bg';
update public.countries set virtualsms_code='BO' where id='bo';
update public.countries set virtualsms_code='BR' where id='br';
update public.countries set virtualsms_code='CA' where id='ca';
update public.countries set virtualsms_code='CH' where id='ch';
update public.countries set virtualsms_code='CL' where id='cl';
update public.countries set virtualsms_code='CM' where id='cm';
update public.countries set virtualsms_code='CO' where id='co';
update public.countries set virtualsms_code='CR' where id='cr';
update public.countries set virtualsms_code='CY' where id='cy';
update public.countries set virtualsms_code='CZ' where id='cz';
update public.countries set virtualsms_code='DE' where id='de';
update public.countries set virtualsms_code='DK' where id='dk';
update public.countries set virtualsms_code='DO' where id='do';
update public.countries set virtualsms_code='EE' where id='ee';
update public.countries set virtualsms_code='ES' where id='es';
update public.countries set virtualsms_code='FI' where id='fi';
update public.countries set virtualsms_code='FR' where id='fr';
update public.countries set virtualsms_code='GE' where id='ge';
update public.countries set virtualsms_code='GI' where id='gi';
update public.countries set virtualsms_code='GR' where id='gr';
update public.countries set virtualsms_code='HK' where id='hk';
update public.countries set virtualsms_code='HR' where id='hr';
update public.countries set virtualsms_code='HU' where id='hu';
update public.countries set virtualsms_code='ID' where id='id';
update public.countries set virtualsms_code='IE' where id='ie';
update public.countries set virtualsms_code='IL' where id='il';
update public.countries set virtualsms_code='IT' where id='it';
update public.countries set virtualsms_code='JP' where id='jp';
update public.countries set virtualsms_code='KE' where id='ke';
update public.countries set virtualsms_code='KG' where id='kg';
update public.countries set virtualsms_code='KH' where id='kh';
update public.countries set virtualsms_code='KZ' where id='kz';
update public.countries set virtualsms_code='LT' where id='lt';
update public.countries set virtualsms_code='LV' where id='lv';
update public.countries set virtualsms_code='MA' where id='ma';
update public.countries set virtualsms_code='MD' where id='md';
update public.countries set virtualsms_code='MK' where id='mk';
update public.countries set virtualsms_code='MT' where id='mt';
update public.countries set virtualsms_code='MX' where id='mx';
update public.countries set virtualsms_code='MY' where id='my';
update public.countries set virtualsms_code='NL' where id='nl';
update public.countries set virtualsms_code='NZ' where id='nz';
update public.countries set virtualsms_code='PH' where id='ph';
update public.countries set virtualsms_code='PK' where id='pk';
update public.countries set virtualsms_code='PL' where id='pl';
update public.countries set virtualsms_code='PT' where id='pt';
update public.countries set virtualsms_code='PY' where id='py';
update public.countries set virtualsms_code='RO' where id='ro';
update public.countries set virtualsms_code='RS' where id='rs';
update public.countries set virtualsms_code='SE' where id='se';
update public.countries set virtualsms_code='SG' where id='sg';
update public.countries set virtualsms_code='SI' where id='si';
update public.countries set virtualsms_code='SK' where id='sk';
update public.countries set virtualsms_code='TH' where id='th';
update public.countries set virtualsms_code='TR' where id='tr';
update public.countries set virtualsms_code='TZ' where id='tz';
update public.countries set virtualsms_code='UA' where id='ua';
update public.countries set virtualsms_code='GB' where id='uk';
update public.countries set virtualsms_code='US' where id='us';
update public.countries set virtualsms_code='VN' where id='vn';
update public.countries set virtualsms_code='ZA' where id='za';
