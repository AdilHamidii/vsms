-- Phase I:
--   1) Expand countries from 10 -> ~40
--   2) Bump base cost for premium services
--   3) Populate routes.retail_credits so popular service+country combos
--      cost more (e.g. WhatsApp+US, PayPal+UK)
--
-- Pricing model:
--   service.cost           = "base" cost for this service across most countries
--   routes.retail_credits  = override for a specific (service, country) pair;
--                            NULL means use the service's base cost
--   create-order picks route.retail_credits ?? service.cost at charge time.

-- 1) Reseed countries
delete from public.routes;
delete from public.countries;

insert into public.countries (id, name, smspva_code, dial_code, flag, stock, avg_seconds, sort_order) values
    -- Tier 1 (high stock, premium markets)
    ('us', 'United States',  'US',  '+1',   '🇺🇸', 'high',   25,  10),
    ('uk', 'United Kingdom', 'UK',  '+44',  '🇬🇧', 'high',   30,  20),
    ('ca', 'Canada',         'CA',  '+1',   '🇨🇦', 'high',   28,  30),
    ('au', 'Australia',      'AU',  '+61',  '🇦🇺', 'high',   32,  40),
    ('de', 'Germany',        'DE',  '+49',  '🇩🇪', 'high',   28,  50),
    ('fr', 'France',         'FR',  '+33',  '🇫🇷', 'high',   30,  60),
    ('nl', 'Netherlands',    'NL',  '+31',  '🇳🇱', 'high',   30,  70),
    ('it', 'Italy',          'IT',  '+39',  '🇮🇹', 'medium', 35,  80),
    ('es', 'Spain',          'ES',  '+34',  '🇪🇸', 'medium', 35,  90),
    -- EU + Eastern Europe
    ('pl', 'Poland',         'PL',  '+48',  '🇵🇱', 'high',   30, 100),
    ('se', 'Sweden',         'SE',  '+46',  '🇸🇪', 'medium', 32, 110),
    ('no', 'Norway',         'NO',  '+47',  '🇳🇴', 'medium', 34, 120),
    ('fi', 'Finland',        'FI',  '+358', '🇫🇮', 'medium', 36, 130),
    ('dk', 'Denmark',        'DK',  '+45',  '🇩🇰', 'medium', 32, 140),
    ('be', 'Belgium',        'BE',  '+32',  '🇧🇪', 'medium', 34, 150),
    ('at', 'Austria',        'AT',  '+43',  '🇦🇹', 'medium', 33, 160),
    ('ch', 'Switzerland',    'CH',  '+41',  '🇨🇭', 'medium', 35, 170),
    ('cz', 'Czechia',        'CZ',  '+420', '🇨🇿', 'medium', 36, 180),
    ('pt', 'Portugal',       'PT',  '+351', '🇵🇹', 'medium', 38, 190),
    ('ro', 'Romania',        'RO',  '+40',  '🇷🇴', 'medium', 40, 200),
    ('ie', 'Ireland',        'IE',  '+353', '🇮🇪', 'medium', 33, 210),
    -- CIS
    ('ru', 'Russia',         'RU',  '+7',   '🇷🇺', 'high',   35, 220),
    ('ua', 'Ukraine',        'UA',  '+380', '🇺🇦', 'high',   38, 230),
    ('kz', 'Kazakhstan',     'KZ',  '+7',   '🇰🇿', 'high',   40, 240),
    ('by', 'Belarus',        'BY',  '+375', '🇧🇾', 'medium', 42, 250),
    -- Latin America
    ('mx', 'Mexico',         'MX',  '+52',  '🇲🇽', 'high',   38, 260),
    ('br', 'Brazil',         'BR',  '+55',  '🇧🇷', 'high',   42, 270),
    ('ar', 'Argentina',      'AR',  '+54',  '🇦🇷', 'medium', 44, 280),
    ('co', 'Colombia',       'CO',  '+57',  '🇨🇴', 'medium', 45, 290),
    ('cl', 'Chile',          'CL',  '+56',  '🇨🇱', 'medium', 46, 300),
    -- MENA
    ('tr', 'Turkey',         'TR',  '+90',  '🇹🇷', 'high',   40, 310),
    ('ae', 'UAE',            'AE',  '+971', '🇦🇪', 'medium', 38, 320),
    ('sa', 'Saudi Arabia',   'SA',  '+966', '🇸🇦', 'medium', 42, 330),
    ('eg', 'Egypt',          'EG',  '+20',  '🇪🇬', 'medium', 45, 340),
    ('il', 'Israel',         'IL',  '+972', '🇮🇱', 'medium', 36, 350),
    ('za', 'South Africa',   'ZA',  '+27',  '🇿🇦', 'medium', 48, 360),
    ('ng', 'Nigeria',        'NG',  '+234', '🇳🇬', 'medium', 50, 370),
    ('ke', 'Kenya',          'KE',  '+254', '🇰🇪', 'medium', 52, 380),
    ('ma', 'Morocco',        'MA',  '+212', '🇲🇦', 'medium', 48, 390),
    -- Asia Pacific
    ('in', 'India',          'IN',  '+91',  '🇮🇳', 'high',   38, 400),
    ('id', 'Indonesia',      'ID',  '+62',  '🇮🇩', 'high',   42, 410),
    ('ph', 'Philippines',    'PH',  '+63',  '🇵🇭', 'high',   45, 420),
    ('vn', 'Vietnam',        'VN',  '+84',  '🇻🇳', 'medium', 46, 430),
    ('th', 'Thailand',       'TH',  '+66',  '🇹🇭', 'medium', 44, 440),
    ('my', 'Malaysia',       'MY',  '+60',  '🇲🇾', 'medium', 42, 450),
    ('sg', 'Singapore',      'SG',  '+65',  '🇸🇬', 'medium', 36, 460),
    ('jp', 'Japan',          'JP',  '+81',  '🇯🇵', 'low',    50, 470),
    ('kr', 'South Korea',    'KR',  '+82',  '🇰🇷', 'medium', 42, 480),
    ('hk', 'Hong Kong',      'HK',  '+852', '🇭🇰', 'medium', 40, 490),
    ('tw', 'Taiwan',         'TW',  '+886', '🇹🇼', 'medium', 42, 500),
    ('cn', 'China',          'CN',  '+86',  '🇨🇳', 'low',    55, 510);

-- 2) Bump base cost for premium services
update public.services
set cost = 2
where id in ('whatsapp', 'telegram', 'apple-id', 'openai',
             'paypal', 'venmo', 'cashapp', 'revolut', 'wise',
             'binance', 'coinbase', 'crypto-com', 'kraken', 'kucoin',
             'icloud');

-- 3) Recreate all (service, country) routes as active
insert into public.routes (service_id, country_id, status)
select s.id, c.id, 'active'
from public.services s
cross join public.countries c;

-- 4) Tiered pricing overrides

-- Tier-A countries (most expensive routes anywhere)
with tier_a as (select unnest(array['us','uk','ca','au','de','fr','nl']) as id),
     tier_b as (select unnest(array['it','es','se','no','fi','dk','be','at','ch','ie','jp','kr','sg','hk','il','ae']) as id)

update public.routes r
set retail_credits = case
    -- Premium service in Tier-A country: base+1 (so 3 cr if base is 2)
    when r.service_id in ('whatsapp','telegram','apple-id','openai','paypal','venmo','cashapp','revolut','wise','binance','coinbase','crypto-com','kraken','kucoin','icloud')
         and r.country_id in (select id from tier_a)
        then 3
    -- Premium service in Tier-B: keep base (2)
    when r.service_id in ('whatsapp','telegram','apple-id','openai','paypal','venmo','cashapp','revolut','wise','binance','coinbase','crypto-com','kraken','kucoin','icloud')
         and r.country_id in (select id from tier_b)
        then 2
    -- Standard service in Tier-A: 2 cr (so they show as +1 over base)
    when r.country_id in (select id from tier_a)
        then 2
    -- Otherwise: null = use service base cost
    else null
end;

-- A few hand-tuned spikes for the very most popular combos
update public.routes set retail_credits = 4
    where service_id = 'whatsapp' and country_id in ('us','uk');
update public.routes set retail_credits = 4
    where service_id = 'telegram' and country_id in ('us','uk','de');
update public.routes set retail_credits = 4
    where service_id = 'apple-id' and country_id in ('us','uk');
update public.routes set retail_credits = 3
    where service_id = 'instagram' and country_id in ('us','uk','de','fr');
update public.routes set retail_credits = 3
    where service_id = 'tiktok' and country_id in ('us','uk');

-- Mark a few low-stock / unreliable routes as hidden
update public.routes set status = 'hidden' where country_id = 'cn';
