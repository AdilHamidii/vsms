-- Phase K: replace the country catalog with the full 68-country list
-- that SMSPVA actually exposes in v2 (per docs.smspva.com activation_v2_lists).
--
-- Countries removed from previous seed (no longer in SMSPVA v2): RU, IN,
-- BY, EG, SA, NG, KR, TW, CN. Cascade drops any orders / routes against
-- those rows.

delete from public.routes;
delete from public.countries;

insert into public.countries (id, name, smspva_code, dial_code, flag, stock, avg_seconds, sort_order) values
    -- Tier-A premium markets
    ('us', 'United States',           'US',  '+1',    '🇺🇸', 'high',    25,  10),
    ('uk', 'United Kingdom',          'UK',  '+44',   '🇬🇧', 'high',    30,  20),
    ('ca', 'Canada',                  'CA',  '+1',    '🇨🇦', 'high',    28,  30),
    ('au', 'Australia',               'AU',  '+61',   '🇦🇺', 'high',    32,  40),
    ('de', 'Germany',                 'DE',  '+49',   '🇩🇪', 'high',    28,  50),
    ('fr', 'France',                  'FR',  '+33',   '🇫🇷', 'high',    30,  60),
    ('nl', 'Netherlands',             'NL',  '+31',   '🇳🇱', 'high',    30,  70),
    ('it', 'Italy',                   'IT',  '+39',   '🇮🇹', 'high',    34,  80),
    ('es', 'Spain',                   'ES',  '+34',   '🇪🇸', 'high',    35,  90),
    ('pl', 'Poland',                  'PL',  '+48',   '🇵🇱', 'high',    30, 100),
    -- Nordics + DACH + Benelux + IE
    ('se', 'Sweden',                  'SE',  '+46',   '🇸🇪', 'high',    32, 110),
    ('dk', 'Denmark',                 'DK',  '+45',   '🇩🇰', 'medium',  32, 120),
    ('fi', 'Finland',                 'FI',  '+358',  '🇫🇮', 'medium',  36, 130),
    ('be', 'Belgium',                 'BE',  '+32',   '🇧🇪', 'medium',  34, 140),
    ('at', 'Austria',                 'AT',  '+43',   '🇦🇹', 'medium',  33, 150),
    ('ch', 'Switzerland',             'CH',  '+41',   '🇨🇭', 'medium',  35, 160),
    ('ie', 'Ireland',                 'IE',  '+353',  '🇮🇪', 'medium',  33, 170),
    -- Southern + Eastern EU
    ('pt', 'Portugal',                'PT',  '+351',  '🇵🇹', 'medium',  38, 180),
    ('ro', 'Romania',                 'RO',  '+40',   '🇷🇴', 'medium',  40, 190),
    ('cz', 'Czech Republic',          'CZ',  '+420',  '🇨🇿', 'medium',  36, 200),
    ('sk', 'Slovakia',                'SK',  '+421',  '🇸🇰', 'medium',  38, 210),
    ('si', 'Slovenia',                'SI',  '+386',  '🇸🇮', 'medium',  38, 220),
    ('hu', 'Hungary',                 'HU',  '+36',   '🇭🇺', 'medium',  36, 230),
    ('hr', 'Croatia',                 'HR',  '+385',  '🇭🇷', 'medium',  38, 240),
    ('bg', 'Bulgaria',                'BG',  '+359',  '🇧🇬', 'medium',  40, 250),
    ('rs', 'Serbia',                  'RS',  '+381',  '🇷🇸', 'medium',  42, 260),
    ('al', 'Albania',                 'AL',  '+355',  '🇦🇱', 'medium',  44, 270),
    ('ba', 'Bosnia and Herzegovina',  'BA',  '+387',  '🇧🇦', 'medium',  44, 280),
    ('mk', 'North Macedonia',         'MK',  '+389',  '🇲🇰', 'medium',  44, 290),
    ('mt', 'Malta',                   'MT',  '+356',  '🇲🇹', 'medium',  40, 300),
    ('cy', 'Cyprus',                  'CY',  '+357',  '🇨🇾', 'medium',  40, 310),
    ('gr', 'Greece',                  'GR',  '+30',   '🇬🇷', 'medium',  38, 320),
    ('gi', 'Gibraltar',               'GI',  '+350',  '🇬🇮', 'low',     46, 330),
    -- Baltics
    ('ee', 'Estonia',                 'EE',  '+372',  '🇪🇪', 'medium',  35, 340),
    ('lv', 'Latvia',                  'LV',  '+371',  '🇱🇻', 'medium',  36, 350),
    ('lt', 'Lithuania',               'LT',  '+370',  '🇱🇹', 'medium',  36, 360),
    -- Caucasus + Central Asia
    ('ge', 'Georgia',                 'GE',  '+995',  '🇬🇪', 'medium',  44, 370),
    ('kz', 'Kazakhstan',              'KZ',  '+7',    '🇰🇿', 'high',    40, 380),
    ('kg', 'Kyrgyzstan',              'KG',  '+996',  '🇰🇬', 'medium',  46, 390),
    ('md', 'Moldova',                 'MD',  '+373',  '🇲🇩', 'medium',  44, 400),
    ('ua', 'Ukraine',                 'UA',  '+380',  '🇺🇦', 'high',    38, 410),
    -- Latin America
    ('mx', 'Mexico',                  'MX',  '+52',   '🇲🇽', 'high',    38, 420),
    ('br', 'Brazil',                  'BR',  '+55',   '🇧🇷', 'high',    42, 430),
    ('ar', 'Argentina',               'AR',  '+54',   '🇦🇷', 'medium',  44, 440),
    ('co', 'Colombia',                'CO',  '+57',   '🇨🇴', 'medium',  45, 450),
    ('cl', 'Chile',                   'CL',  '+56',   '🇨🇱', 'medium',  46, 460),
    ('bo', 'Bolivia',                 'BO',  '+591',  '🇧🇴', 'medium',  48, 470),
    ('py', 'Paraguay',                'PY',  '+595',  '🇵🇾', 'medium',  48, 480),
    ('cr', 'Costa Rica',              'CR',  '+506',  '🇨🇷', 'medium',  46, 490),
    ('do', 'Dominican Republic',      'DO',  '+1',    '🇩🇴', 'medium',  48, 500),
    -- MENA + Middle East
    ('tr', 'Turkey',                  'TR',  '+90',   '🇹🇷', 'high',    40, 510),
    ('il', 'Israel',                  'IL',  '+972',  '🇮🇱', 'medium',  36, 520),
    ('ma', 'Morocco',                 'MA',  '+212',  '🇲🇦', 'medium',  48, 530),
    -- Africa
    ('za', 'South Africa',            'ZA',  '+27',   '🇿🇦', 'medium',  48, 540),
    ('ke', 'Kenya',                   'KE',  '+254',  '🇰🇪', 'medium',  52, 550),
    ('tz', 'Tanzania',                'TZ',  '+255',  '🇹🇿', 'low',     56, 560),
    ('cm', 'Cameroon',                'CM',  '+237',  '🇨🇲', 'low',     58, 570),
    -- Asia
    ('jp', 'Japan',                   'JP',  '+81',   '🇯🇵', 'low',     50, 580),
    ('hk', 'Hong Kong',               'HK',  '+852',  '🇭🇰', 'medium',  40, 590),
    ('sg', 'Singapore',               'SG',  '+65',   '🇸🇬', 'medium',  36, 600),
    ('my', 'Malaysia',                'MY',  '+60',   '🇲🇾', 'medium',  42, 610),
    ('th', 'Thailand',                'TH',  '+66',   '🇹🇭', 'medium',  44, 620),
    ('vn', 'Vietnam',                 'VN',  '+84',   '🇻🇳', 'medium',  46, 630),
    ('ph', 'Philippines',             'PH',  '+63',   '🇵🇭', 'high',    45, 640),
    ('id', 'Indonesia',               'ID',  '+62',   '🇮🇩', 'high',    42, 650),
    ('kh', 'Cambodia',                'KH',  '+855',  '🇰🇭', 'low',     54, 660),
    ('bd', 'Bangladesh',              'BD',  '+880',  '🇧🇩', 'medium',  50, 670),
    ('pk', 'Pakistan',                'PK',  '+92',   '🇵🇰', 'medium',  48, 680),
    ('nz', 'New Zealand',             'NZ',  '+64',   '🇳🇿', 'medium',  38, 690);

-- Recreate all routes as active
insert into public.routes (service_id, country_id, status)
select s.id, c.id, 'active'
from public.services s
cross join public.countries c;

-- Tier-A markets pay premium pricing (same model as Phase I)
with tier_a as (select unnest(array['us','uk','ca','au','de','fr','nl']) as id),
     tier_b as (select unnest(array['it','es','se','no','fi','dk','be','at','ch','ie','jp','sg','hk','il']) as id)
update public.routes r
set retail_credits = case
    when r.service_id in ('whatsapp','telegram','apple-id','openai','paypal','venmo','cashapp','revolut','wise','binance','coinbase','crypto-com','kraken','kucoin','icloud')
         and r.country_id in (select id from tier_a)
        then 3
    when r.service_id in ('whatsapp','telegram','apple-id','openai','paypal','venmo','cashapp','revolut','wise','binance','coinbase','crypto-com','kraken','kucoin','icloud')
         and r.country_id in (select id from tier_b)
        then 2
    when r.country_id in (select id from tier_a)
        then 2
    else null
end;

update public.routes set retail_credits = 4 where service_id = 'whatsapp' and country_id in ('us','uk');
update public.routes set retail_credits = 4 where service_id = 'telegram' and country_id in ('us','uk','de');
update public.routes set retail_credits = 4 where service_id = 'apple-id' and country_id in ('us','uk');
update public.routes set retail_credits = 3 where service_id = 'instagram' and country_id in ('us','uk','de','fr');
update public.routes set retail_credits = 3 where service_id = 'tiktok' and country_id in ('us','uk');
