-- Phase G: replace brand-name catalog with App-Store-friendly generic services
-- and add an icon column (SF Symbol name) so the iOS UI shows real shapes
-- instead of letter glyphs.

alter table public.services add column if not exists icon text;

-- Wipe existing seed catalog (also cascades routes pointing at these rows).
delete from public.routes;
delete from public.services;
delete from public.countries;

insert into public.services (id, name, category, smspva_code, tint, glyph, icon, cost, success_rate, eta_seconds, sort_order) values
    ('messenger-a',  'Messenger A',  'Messaging',     'opt29',  '#2E6FD9', 'M', 'bubble.left.fill',                       1, 98, 22, 10),
    ('chatline',     'Chatline',     'Messaging',     'opt0',   '#7A4AE0', 'C', 'bubble.left.and.bubble.right.fill',      1, 96, 28, 20),
    ('telechat',     'Telechat',     'Messaging',     'opt22',  '#00A2E8', 'T', 'paperplane.fill',                        1, 97, 25, 30),
    ('socialgram',   'Socialgram',   'Social',        'opt16',  '#D14B7E', 'S', 'photo.fill',                             1, 94, 35, 40),
    ('feedly-plus',  'Feedly+',      'Social',        'opt2',   '#E0793A', 'F', 'text.bubble.fill',                       1, 93, 38, 50),
    ('shortpost',    'Shortpost',    'Social',        'opt41',  '#0F0F0F', 'X', 'at',                                     1, 92, 42, 60),
    ('videocast',    'Videocast',    'Social',        'opt167', '#4A2A8E', 'V', 'play.tv.fill',                           1, 91, 45, 70),
    ('matchly',      'Matchly',      'Dating',        'opt28',  '#D9527B', 'L', 'heart.fill',                             1, 93, 48, 80),
    ('walletly',     'Walletly',     'Finance',       'opt77',  '#1FA463', 'W', 'creditcard.fill',                        2, 92, 55, 90),
    ('banky',        'Banky',        'Finance',       'opt15',  '#0F4C81', 'B', 'building.columns.fill',                  2, 94, 45, 100),
    ('cryptobase',   'Cryptobase',   'Finance',       'opt55',  '#3F4452', 'X', 'bitcoinsign.circle.fill',                2, 90, 62, 110),
    ('marketcart',   'Marketcart',   'Commerce',      'opt19',  '#A77836', 'K', 'bag.fill',                               1, 96, 36, 120),
    ('auctionly',    'Auctionly',    'Commerce',      'opt23',  '#3A6E5E', 'A', 'hammer.fill',                            1, 94, 44, 130),
    ('foodbox',      'Foodbox',      'Delivery',      'opt37',  '#D33A3A', 'F', 'takeoutbag.and.cup.and.straw.fill',      1, 95, 39, 140),
    ('rideshare',    'Rideshare X',  'Transport',     'opt5',   '#1B2330', 'R', 'car.fill',                               1, 97, 31, 150),
    ('cabify',       'Cabify',       'Transport',     'opt7',   '#7A4AE0', 'Y', 'car.side.fill',                          1, 95, 33, 160),
    ('stayhub',      'Stayhub',      'Travel',        'opt43',  '#0F8A8A', 'S', 'bed.double.fill',                        1, 94, 40, 170),
    ('travelhub',    'Travelhub',    'Travel',        'opt71',  '#176FB8', 'T', 'airplane',                               1, 93, 42, 180),
    ('cloudbox',     'Cloudbox',     'Productivity',  'opt62',  '#1E88E5', 'C', 'icloud.fill',                            1, 96, 32, 190),
    ('mailspace',    'Mailspace',    'Productivity',  'opt8',   '#3F51B5', 'M', 'envelope.fill',                          1, 97, 28, 200),
    ('workboard',    'Workboard',    'Productivity',  'opt4',   '#1B2330', 'W', 'briefcase.fill',                         1, 95, 30, 210),
    ('gamebox',      'Gamebox',      'Entertainment', 'opt9',   '#D33A3A', 'G', 'gamecontroller.fill',                    1, 93, 36, 220),
    ('streamcast',   'Streamcast',   'Entertainment', 'opt36',  '#9B59B6', 'S', 'music.note.tv.fill',                     1, 94, 34, 230);

insert into public.countries (id, name, smspva_code, dial_code, flag, stock, avg_seconds, sort_order) values
    ('us', 'United States',  'US',  '+1',   '🇺🇸', 'high',   25, 10),
    ('uk', 'United Kingdom', 'UK',  '+44',  '🇬🇧', 'high',   30, 20),
    ('de', 'Germany',        'DE',  '+49',  '🇩🇪', 'high',   28, 30),
    ('nl', 'Netherlands',    'NL',  '+31',  '🇳🇱', 'high',   30, 40),
    ('fr', 'France',         'FR',  '+33',  '🇫🇷', 'medium', 36, 50),
    ('it', 'Italy',          'IT',  '+39',  '🇮🇹', 'medium', 35, 60),
    ('es', 'Spain',          'ES',  '+34',  '🇪🇸', 'medium', 38, 70),
    ('pl', 'Poland',         'PL',  '+48',  '🇵🇱', 'medium', 40, 80),
    ('in', 'India',          'IN',  '+91',  '🇮🇳', 'high',   41, 90),
    ('br', 'Brazil',         'BR',  '+55',  '🇧🇷', 'medium', 52, 100);

insert into public.routes (service_id, country_id, status)
select s.id, c.id, 'active'
from public.services s
cross join public.countries c;
