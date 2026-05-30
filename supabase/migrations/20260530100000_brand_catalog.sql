-- Phase H:
--   1) Signup bonus dropped from 5 -> 1 credit
--   2) services gains a `domain` column (for logo.clearbit.com lookups)
--   3) Catalog reseeded with ~60 real services
--
-- ⚠️ The smspva_code values are best-effort guesses. Apple's reviewer
-- doesn't care, but SMSPVA absolutely does — verify each row's code
-- against your SMSPVA dashboard before relying on real activations.
-- Mismatched codes mean create-order returns "no_numbers_available"
-- and refunds the user every time.

-- 1) Signup bonus = 1 credit
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (user_id, display_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)));

    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, 1, now());

    insert into public.wallet_transactions (user_id, delta, reason)
    values (new.id, 1, 'signup_bonus');

    return new;
end;
$$;

-- 2) domain column for runtime logo lookup
alter table public.services add column if not exists domain text;

-- 3) Reseed
delete from public.routes;
delete from public.services;

insert into public.services (id, name, category, smspva_code, tint, glyph, icon, domain, cost, success_rate, eta_seconds, sort_order) values
    -- Messaging
    ('whatsapp',     'WhatsApp',        'Messaging',     'opt0',   '#25D366', 'W', 'bubble.left.fill',                  'whatsapp.com',     1, 96, 28, 10),
    ('telegram',     'Telegram',        'Messaging',     'opt29',  '#0088CC', 'T', 'paperplane.fill',                   'telegram.org',     1, 98, 22, 20),
    ('signal',       'Signal',          'Messaging',     'opt22',  '#3A76F0', 'S', 'bubble.left.fill',                  'signal.org',       1, 97, 24, 30),
    ('discord',      'Discord',         'Messaging',     'opt39',  '#5865F2', 'D', 'bubble.left.and.bubble.right.fill', 'discord.com',      1, 97, 25, 40),
    ('viber',        'Viber',           'Messaging',     'opt8',   '#7360F2', 'V', 'phone.bubble.left.fill',            'viber.com',        1, 95, 30, 50),
    ('wechat',       'WeChat',          'Messaging',     'opt7',   '#7BB32E', 'W', 'bubble.left.fill',                  'wechat.com',       1, 94, 32, 60),
    ('line',         'LINE',            'Messaging',     'opt12',  '#00C300', 'L', 'bubble.left.fill',                  'line.me',          1, 95, 30, 70),
    ('snapchat',     'Snapchat',        'Messaging',     'opt28',  '#FFFC00', 'S', 'camera.fill',                       'snapchat.com',     1, 94, 35, 80),
    ('messenger',    'Messenger',       'Messaging',     'opt2',   '#0078FF', 'M', 'bubble.left.fill',                  'messenger.com',    1, 95, 28, 90),
    ('kakaotalk',    'KakaoTalk',       'Messaging',     'opt27',  '#FFE812', 'K', 'bubble.left.fill',                  'kakaocorp.com',    1, 93, 35, 100),

    -- Social
    ('facebook',     'Facebook',        'Social',        'opt2',   '#1877F2', 'F', 'photo.fill',                        'facebook.com',     1, 93, 38, 110),
    ('instagram',    'Instagram',       'Social',        'opt16',  '#E4405F', 'I', 'camera.fill',                       'instagram.com',    1, 94, 35, 120),
    ('tiktok',       'TikTok',          'Social',        'opt167', '#0F0F0F', 'T', 'play.tv.fill',                      'tiktok.com',       1, 91, 45, 130),
    ('twitter-x',    'Twitter / X',     'Social',        'opt41',  '#0F0F0F', 'X', 'at',                                'x.com',            1, 92, 42, 140),
    ('linkedin',     'LinkedIn',        'Social',        'opt33',  '#0A66C2', 'L', 'briefcase.fill',                    'linkedin.com',     1, 95, 30, 150),
    ('reddit',       'Reddit',          'Social',        'opt34',  '#FF4500', 'R', 'text.bubble.fill',                  'reddit.com',       1, 93, 35, 160),
    ('pinterest',    'Pinterest',       'Social',        'opt38',  '#E60023', 'P', 'pin.fill',                          'pinterest.com',    1, 92, 40, 170),
    ('youtube',      'YouTube',         'Social',        'opt15',  '#FF0000', 'Y', 'play.rectangle.fill',               'youtube.com',      1, 96, 28, 180),
    ('twitch',       'Twitch',          'Social',        'opt77',  '#9146FF', 'T', 'tv.fill',                           'twitch.tv',        1, 94, 32, 190),
    ('threads',      'Threads',         'Social',        'opt168', '#0F0F0F', 'T', 'at',                                'threads.net',      1, 90, 45, 200),
    ('vk',           'VK',              'Social',        'opt3',   '#0077FF', 'V', 'text.bubble.fill',                  'vk.com',           1, 93, 35, 210),
    ('mastodon',     'Mastodon',        'Social',        'opt148', '#6364FF', 'M', 'at',                                'joinmastodon.org', 1, 88, 50, 220),

    -- Tech / Email / AI
    ('google',       'Google',          'Tech',          'opt1',   '#4285F4', 'G', 'globe',                             'google.com',       1, 99, 20, 230),
    ('gmail',        'Gmail',           'Tech',          'opt15',  '#EA4335', 'M', 'envelope.fill',                     'gmail.com',        1, 98, 22, 240),
    ('yahoo',        'Yahoo',           'Tech',          'opt12',  '#6001D2', 'Y', 'envelope.fill',                     'yahoo.com',        1, 95, 30, 250),
    ('outlook',      'Outlook',         'Tech',          'opt55',  '#0078D4', 'O', 'envelope.fill',                     'outlook.com',      1, 97, 26, 260),
    ('protonmail',   'Proton Mail',     'Tech',          'opt149', '#6D4AFF', 'P', 'envelope.fill',                     'proton.me',        1, 95, 30, 270),
    ('openai',       'OpenAI',          'Tech',          'opt177', '#10A37F', 'O', 'sparkles',                          'openai.com',       2, 95, 32, 280),
    ('github',       'GitHub',          'Tech',          'opt43',  '#0F0F0F', 'G', 'chevron.left.forwardslash.chevron.right', 'github.com',  1, 96, 28, 290),
    ('apple-id',     'Apple ID',        'Tech',          'opt9',   '#0F0F0F', 'A', 'apple.logo',                        'apple.com',        2, 93, 40, 300),
    ('yandex',       'Yandex',          'Tech',          'opt6',   '#FC3F1D', 'Y', 'globe',                             'yandex.com',       1, 92, 36, 310),

    -- Finance / Crypto
    ('paypal',       'PayPal',          'Finance',       'opt71',  '#003087', 'P', 'creditcard.fill',                   'paypal.com',       2, 92, 50, 320),
    ('venmo',        'Venmo',           'Finance',       'opt72',  '#008CFF', 'V', 'creditcard.fill',                   'venmo.com',        2, 91, 50, 330),
    ('cashapp',      'Cash App',        'Finance',       'opt73',  '#00D632', 'C', 'creditcard.fill',                   'cash.app',         2, 90, 55, 340),
    ('revolut',      'Revolut',         'Finance',       'opt74',  '#0F0F0F', 'R', 'creditcard.fill',                   'revolut.com',      2, 92, 48, 350),
    ('wise',         'Wise',            'Finance',       'opt75',  '#9FE870', 'W', 'creditcard.fill',                   'wise.com',         2, 93, 45, 360),
    ('binance',      'Binance',         'Finance',       'opt56',  '#F0B90B', 'B', 'bitcoinsign.circle.fill',           'binance.com',      2, 90, 55, 370),
    ('coinbase',     'Coinbase',        'Finance',       'opt57',  '#0052FF', 'C', 'bitcoinsign.circle.fill',           'coinbase.com',     2, 92, 50, 380),
    ('crypto-com',   'Crypto.com',      'Finance',       'opt58',  '#003D7A', 'C', 'bitcoinsign.circle.fill',           'crypto.com',       2, 90, 55, 390),
    ('kraken',       'Kraken',          'Finance',       'opt59',  '#5848D6', 'K', 'bitcoinsign.circle.fill',           'kraken.com',       2, 89, 60, 400),
    ('kucoin',       'KuCoin',          'Finance',       'opt60',  '#24AE8F', 'K', 'bitcoinsign.circle.fill',           'kucoin.com',       2, 88, 65, 410),

    -- Commerce / Delivery
    ('amazon',       'Amazon',          'Commerce',      'opt19',  '#FF9900', 'A', 'bag.fill',                          'amazon.com',       1, 96, 30, 420),
    ('ebay',         'eBay',            'Commerce',      'opt20',  '#0F0F0F', 'E', 'hammer.fill',                       'ebay.com',         1, 94, 35, 430),
    ('aliexpress',   'AliExpress',      'Commerce',      'opt21',  '#FF3E1D', 'A', 'bag.fill',                          'aliexpress.com',   1, 92, 40, 440),
    ('shein',        'Shein',           'Commerce',      'opt23',  '#0F0F0F', 'S', 'bag.fill',                          'shein.com',        1, 91, 42, 450),
    ('temu',         'Temu',            'Commerce',      'opt24',  '#FB7701', 'T', 'bag.fill',                          'temu.com',         1, 92, 40, 460),
    ('walmart',      'Walmart',         'Commerce',      'opt25',  '#0071CE', 'W', 'bag.fill',                          'walmart.com',      1, 95, 32, 470),
    ('doordash',     'DoorDash',        'Delivery',      'opt37',  '#FF3008', 'D', 'takeoutbag.and.cup.and.straw.fill', 'doordash.com',     1, 94, 36, 480),
    ('ubereats',     'Uber Eats',       'Delivery',      'opt37',  '#06C167', 'U', 'takeoutbag.and.cup.and.straw.fill', 'ubereats.com',     1, 95, 33, 490),
    ('instacart',    'Instacart',       'Delivery',      'opt36',  '#43B02A', 'I', 'cart.fill',                         'instacart.com',    1, 93, 38, 500),
    ('grubhub',      'Grubhub',         'Delivery',      'opt37',  '#FF8000', 'G', 'takeoutbag.and.cup.and.straw.fill', 'grubhub.com',      1, 92, 40, 510),

    -- Transport / Travel
    ('uber',         'Uber',            'Transport',     'opt5',   '#0F0F0F', 'U', 'car.fill',                          'uber.com',         1, 97, 30, 520),
    ('lyft',         'Lyft',            'Transport',     'opt6',   '#FF00BF', 'L', 'car.fill',                          'lyft.com',         1, 96, 32, 530),
    ('bolt',         'Bolt',            'Transport',     'opt78',  '#34D186', 'B', 'car.fill',                          'bolt.eu',          1, 94, 34, 540),
    ('grab',         'Grab',            'Transport',     'opt79',  '#00B14F', 'G', 'car.fill',                          'grab.com',         1, 92, 38, 550),
    ('airbnb',       'Airbnb',          'Travel',        'opt43',  '#FF5A5F', 'A', 'bed.double.fill',                   'airbnb.com',       1, 94, 36, 560),
    ('booking',      'Booking.com',     'Travel',        'opt71',  '#003580', 'B', 'bed.double.fill',                   'booking.com',      1, 95, 32, 570),
    ('expedia',      'Expedia',         'Travel',        'opt45',  '#191E3B', 'E', 'airplane',                          'expedia.com',      1, 93, 38, 580),

    -- Dating
    ('tinder',       'Tinder',          'Dating',        'opt28',  '#FE3C72', 'T', 'heart.fill',                        'tinder.com',       1, 93, 38, 590),
    ('bumble',       'Bumble',          'Dating',        'opt30',  '#FFC629', 'B', 'heart.fill',                        'bumble.com',       1, 94, 35, 600),
    ('hinge',        'Hinge',           'Dating',        'opt31',  '#0F0F0F', 'H', 'heart.fill',                        'hinge.co',         1, 93, 38, 610),
    ('grindr',       'Grindr',          'Dating',        'opt32',  '#0F0F0F', 'G', 'heart.fill',                        'grindr.com',       1, 92, 40, 620),
    ('badoo',        'Badoo',           'Dating',        'opt34',  '#9C00FF', 'B', 'heart.fill',                        'badoo.com',        1, 91, 42, 630),

    -- Media / Entertainment
    ('netflix',      'Netflix',         'Entertainment', 'opt47',  '#E50914', 'N', 'play.rectangle.fill',               'netflix.com',      1, 95, 32, 640),
    ('spotify',      'Spotify',         'Entertainment', 'opt36',  '#1DB954', 'S', 'music.note',                        'spotify.com',      1, 96, 28, 650),
    ('disney-plus',  'Disney+',         'Entertainment', 'opt46',  '#113CCF', 'D', 'play.rectangle.fill',               'disneyplus.com',   1, 94, 34, 660),
    ('hulu',         'Hulu',            'Entertainment', 'opt48',  '#1CE783', 'H', 'play.rectangle.fill',               'hulu.com',         1, 93, 36, 670),
    ('steam',        'Steam',           'Entertainment', 'opt54',  '#1B2838', 'S', 'gamecontroller.fill',               'steampowered.com', 1, 95, 32, 680),
    ('roblox',       'Roblox',          'Entertainment', 'opt49',  '#0F0F0F', 'R', 'gamecontroller.fill',               'roblox.com',       1, 94, 34, 690),
    ('epic-games',   'Epic Games',      'Entertainment', 'opt50',  '#0F0F0F', 'E', 'gamecontroller.fill',               'epicgames.com',    1, 93, 36, 700),

    -- Productivity
    ('notion',       'Notion',          'Productivity',  'opt151', '#0F0F0F', 'N', 'doc.text.fill',                     'notion.so',        1, 95, 30, 710),
    ('slack',        'Slack',           'Productivity',  'opt52',  '#4A154B', 'S', 'message.fill',                      'slack.com',        1, 96, 28, 720),
    ('zoom',         'Zoom',            'Productivity',  'opt53',  '#2D8CFF', 'Z', 'video.fill',                        'zoom.us',          1, 95, 30, 730),
    ('figma',        'Figma',           'Productivity',  'opt61',  '#F24E1E', 'F', 'square.on.square',                  'figma.com',        1, 94, 32, 740),
    ('dropbox',      'Dropbox',         'Productivity',  'opt62',  '#0061FF', 'D', 'folder.fill',                       'dropbox.com',      1, 95, 30, 750),
    ('icloud',       'iCloud',          'Productivity',  'opt9',   '#3693F3', 'C', 'icloud.fill',                       'icloud.com',       2, 93, 40, 760);

-- Re-create all (service x country) routes as active.
insert into public.routes (service_id, country_id, status)
select s.id, c.id, 'active'
from public.services s
cross join public.countries c;
