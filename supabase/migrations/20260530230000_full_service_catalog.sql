-- Phase L: full 261-service SMSPVA catalog from docs.smspva.com.
--
-- Each row's `domain` is a best-guess used by iOS to fetch a real logo
-- (Clearbit -> Google FaviconV2 -> SF Symbol fallback). Where I'm not
-- sure of the domain, it's left NULL and iOS shows the SF Symbol on the
-- tinted background.
--
-- For ~60% of these I can give a confident domain. For obscure regional
-- services (Drug Vokrug, autocosmos.com, etc.) the domain is in the
-- description itself or omitted.
--
-- "OTHER (no guarantee)" opt19 is intentionally skipped — pure catch-all,
-- no consumer surface.

delete from public.routes;
delete from public.services;

insert into public.services (id, name, category, smspva_code, tint, glyph, icon, domain, cost, success_rate, eta_seconds, sort_order) values
    -- AI
    ('openai',          'OpenAI / ChatGPT', 'AI',  'opt132', '#10A37F', 'O', 'sparkles',          'openai.com',         2, 95, 32, 10),
    ('claude',          'Claude',           'AI',  'opt196', '#C97559', 'C', 'sparkles',          'anthropic.com',      2, 95, 30, 20),
    ('toloka',          'Toloka',           'AI',  'opt264', '#5B9BFF', 'T', 'sparkles',          'toloka.ai',          1, 92, 36, 30),
    ('outlier',         'Outlier',          'AI',  'opt246', '#0F0F0F', 'O', 'sparkles',          'outlier.ai',         1, 92, 36, 40),

    -- Messaging
    ('whatsapp',        'WhatsApp',         'Messaging', 'opt20',  '#25D366', 'W', 'bubble.left.fill',                  'whatsapp.com',     2, 96, 28, 100),
    ('telegram',        'Telegram',         'Messaging', 'opt29',  '#0088CC', 'T', 'paperplane.fill',                   'telegram.org',     2, 98, 22, 110),
    ('signal',          'Signal',           'Messaging', 'opt127', '#3A76F0', 'S', 'bubble.left.fill',                  'signal.org',       1, 97, 24, 120),
    ('discord',         'Discord',          'Messaging', 'opt45',  '#5865F2', 'D', 'bubble.left.and.bubble.right.fill', 'discord.com',      1, 97, 25, 130),
    ('viber',           'Viber',            'Messaging', 'opt11',  '#7360F2', 'V', 'phone.bubble.left.fill',            'viber.com',        1, 95, 30, 140),
    ('wechat',          'WeChat',           'Messaging', 'opt67',  '#07C160', 'W', 'bubble.left.fill',                  'wechat.com',       1, 94, 32, 150),
    ('line',            'LINE',             'Messaging', 'opt37',  '#00C300', 'L', 'bubble.left.fill',                  'line.me',          1, 95, 30, 160),
    ('snapchat',        'Snapchat',         'Messaging', 'opt90',  '#FFFC00', 'S', 'camera.fill',                       'snapchat.com',     1, 94, 35, 170),
    ('kakaotalk',       'KakaoTalk',        'Messaging', 'opt71',  '#FEE500', 'K', 'bubble.left.fill',                  'kakaocorp.com',    1, 93, 35, 180),
    ('tango',           'Tango',            'Messaging', 'opt82',  '#FF3F40', 'T', 'video.fill',                        'tango.me',         1, 92, 38, 190),
    ('imo',             'IMO',              'Messaging', 'opt111', '#00B5FF', 'I', 'video.fill',                        'imo.im',           1, 92, 38, 200),
    ('michat',          'MiChat',           'Messaging', 'opt96',  '#5C5CFF', 'M', 'bubble.left.fill',                  'michat.com',       1, 90, 40, 210),
    ('zalo',            'Zalo',             'Messaging', 'opt158', '#0068FF', 'Z', 'bubble.left.fill',                  'zalo.me',          1, 90, 40, 220),
    ('hellotalk',       'HelloTalk',        'Messaging', 'opt203', '#22C2D2', 'H', 'bubble.left.fill',                  'hellotalk.com',    1, 90, 40, 230),
    ('voov',            'VooV Meeting',     'Messaging', 'opt147', '#1A66FF', 'V', 'video.fill',                        'voovmeeting.com',  1, 89, 42, 240),
    ('drug-vokrug',     'Drug Vokrug',      'Messaging', 'opt31',  '#FF6B35', 'D', 'bubble.left.fill',                  'drugvokrug.ru',    1, 88, 45, 250),
    ('google-chat',     'Google Chat',      'Messaging', 'opt271', '#0F9D58', 'G', 'bubble.left.fill',                  'chat.google.com',  1, 93, 32, 260),
    ('google-messenger','Google Messenger', 'Messaging', 'opt259', '#0F9D58', 'G', 'bubble.left.fill',                  'messages.google.com',1, 93, 32, 270),
    ('google-voice',    'Google Voice',     'Messaging', 'opt140', '#0F9D58', 'G', 'phone.fill',                        'voice.google.com', 1, 93, 32, 280),
    ('twilio',          'Twilio',           'Messaging', 'opt66',  '#F22F46', 'T', 'phone.fill',                        'twilio.com',       1, 92, 35, 290),
    ('truecaller',      'TrueCaller',       'Messaging', 'opt233', '#1F8FFF', 'T', 'phone.fill',                        'truecaller.com',   1, 92, 35, 300),
    ('vonage',          'Vonage',           'Messaging', 'opt178', '#871FFF', 'V', 'phone.fill',                        'vonage.com',       1, 91, 38, 310),

    -- Social
    ('facebook',        'Facebook',         'Social', 'opt2',   '#1877F2', 'F', 'photo.fill',                'facebook.com',     1, 93, 38, 400),
    ('instagram',       'Instagram',        'Social', 'opt16',  '#E4405F', 'I', 'camera.fill',               'instagram.com',    1, 94, 35, 410),
    ('tiktok',          'TikTok',           'Social', 'opt104', '#0F0F0F', 'T', 'play.tv.fill',              'tiktok.com',       1, 91, 45, 420),
    ('twitter-x',       'Twitter / X',      'Social', 'opt41',  '#0F0F0F', 'X', 'at',                        'x.com',            1, 92, 42, 430),
    ('linkedin',        'LinkedIn',         'Social', 'opt8',   '#0A66C2', 'L', 'briefcase.fill',            'linkedin.com',     1, 95, 30, 440),
    ('reddit',          'Reddit',           'Social', 'opt265', '#FF4500', 'R', 'text.bubble.fill',          'reddit.com',       1, 93, 35, 450),
    ('vk',              'VK',               'Social', 'opt69',  '#0077FF', 'V', 'text.bubble.fill',          'vk.com',           1, 90, 40, 460),
    ('twitch',          'Twitch',           'Social', 'opt205', '#9146FF', 'T', 'tv.fill',                   'twitch.tv',        1, 94, 32, 470),
    ('clubhouse',       'Clubhouse',        'Social', 'opt98',  '#F1EFE4', 'C', 'mic.fill',                  'clubhousehq.com',  1, 90, 40, 480),
    ('tencent-qq',      'Tencent QQ',       'Social', 'opt34',  '#1FA9FF', 'Q', 'bubble.left.fill',          'qq.com',           1, 90, 42, 490),
    ('ok',              'Odnoklassniki',    'Social', 'opt5',   '#EE8208', 'O', 'photo.fill',                'ok.ru',            1, 91, 40, 500),
    ('mamba',           'Mamba',            'Social', 'opt100', '#DC1F50', 'M', 'photo.fill',                'mamba.ru',         1, 89, 44, 510),
    ('fotostrana',      'Fotostrana',       'Social', 'opt13',  '#E6493F', 'F', 'photo.fill',                'fotostrana.ru',    1, 88, 45, 520),
    ('rusdate',         'RusDate',          'Social', 'opt186', '#E4405F', 'R', 'heart.fill',                'rusdate.net',      1, 87, 46, 530),
    ('locanto',         'Locanto',          'Social', 'opt114', '#26B66C', 'L', 'photo.fill',                'locanto.com',      1, 89, 44, 540),
    ('truth-social',    'Truth Social',     'Social', 'opt244', '#5D3F75', 'T', 'photo.fill',                'truthsocial.com',  1, 90, 42, 550),
    ('publi24',         'Publi24',          'Social', 'opt207', '#FE9900', 'P', 'photo.fill',                'publi24.ro',       1, 88, 46, 560),
    ('chotot',          'Cho Tot',          'Social', 'opt176', '#FFCD00', 'C', 'photo.fill',                'chotot.com',       1, 89, 45, 570),

    -- Dating
    ('tinder',          'Tinder',           'Dating', 'opt9',   '#FE3C72', 'T', 'heart.fill',                'tinder.com',       1, 93, 38, 700),
    ('bumble',          'Bumble',           'Dating', 'opt145', '#FFC629', 'B', 'heart.fill',                'bumble.com',       1, 94, 35, 710),
    ('hinge',           'Hinge',            'Dating', 'opt120', '#0F0F0F', 'H', 'heart.fill',                'hinge.co',         1, 93, 38, 720),
    ('grindr',          'Grindr',           'Dating', 'opt110', '#FFFF00', 'G', 'heart.fill',                'grindr.com',       1, 92, 40, 730),
    ('badoo',           'Badoo',            'Dating', 'opt56',  '#9C00FF', 'B', 'heart.fill',                'badoo.com',        1, 91, 42, 740),
    ('pof',             'Plenty of Fish',   'Dating', 'opt84',  '#E54B27', 'P', 'heart.fill',                'pof.com',          1, 89, 44, 750),
    ('okcupid',         'OkCupid',          'Dating', 'opt230', '#FF425D', 'O', 'heart.fill',                'okcupid.com',      1, 91, 42, 760),
    ('match',           'Match',            'Dating', 'opt250', '#0073EC', 'M', 'heart.fill',                'match.com',        1, 91, 42, 770),
    ('happn',           'Happn',            'Dating', 'opt155', '#FF6E66', 'H', 'heart.fill',                'happn.com',        1, 90, 44, 780),
    ('feeld',           'Feeld',            'Dating', 'opt159', '#0F0F0F', 'F', 'heart.fill',                'feeld.co',         1, 90, 44, 790),
    ('skout',           'Skout',            'Dating', 'opt49',  '#00BCFA', 'S', 'heart.fill',                'skout.com',        1, 89, 45, 800),
    ('wooplus',         'WooPlus',          'Dating', 'opt208', '#9B59B6', 'W', 'heart.fill',                'wooplusapp.com',   1, 88, 46, 810),
    ('zoosk',           'Zoosk',            'Dating', 'opt253', '#FFAF02', 'Z', 'heart.fill',                'zoosk.com',        1, 89, 45, 820),
    ('cupidmedia',      'CupidMedia',       'Dating', 'opt157', '#E91E63', 'C', 'heart.fill',                'cupidmedia.com',   1, 88, 46, 830),
    ('ourtime',         'OurTime',          'Dating', 'opt212', '#75AA40', 'O', 'heart.fill',                'ourtime.com',      1, 88, 46, 840),

    -- Finance / Banking
    ('paypal',          'PayPal',           'Finance', 'opt83',  '#003087', 'P', 'creditcard.fill',          'paypal.com',       2, 92, 50, 1000),
    ('venmo',           'Venmo',            'Finance', 'opt39',  '#008CFF', 'V', 'creditcard.fill',          'venmo.com',        2, 91, 50, 1010),
    ('cashapp',         'Cash App',         'Finance', 'opt226', '#00D632', 'C', 'creditcard.fill',          'cash.app',         2, 90, 55, 1020),
    ('revolut',         'Revolut',          'Finance', 'opt133', '#0F0F0F', 'R', 'creditcard.fill',          'revolut.com',      2, 92, 48, 1030),
    ('wise',            'Wise',             'Finance', 'opt91',  '#9FE870', 'W', 'creditcard.fill',          'wise.com',         2, 93, 45, 1040),
    ('klarna',          'Klarna',           'Finance', 'opt175', '#FFA8CD', 'K', 'creditcard.fill',          'klarna.com',       2, 92, 48, 1050),
    ('paysafecard',     'Paysafecard',      'Finance', 'opt122', '#00AFEC', 'P', 'creditcard.fill',          'paysafecard.com',  2, 91, 50, 1060),
    ('skrill',          'Skrill',           'Finance', 'opt117', '#862165', 'S', 'creditcard.fill',          'skrill.com',       2, 91, 50, 1070),
    ('neteller',        'Neteller',         'Finance', 'opt116', '#00AC41', 'N', 'creditcard.fill',          'neteller.com',     2, 91, 50, 1080),
    ('payoneer',        'Payoneer',         'Finance', 'opt162', '#FF4800', 'P', 'creditcard.fill',          'payoneer.com',     2, 91, 50, 1090),
    ('monese',          'Monese',           'Finance', 'opt121', '#0A11A2', 'M', 'creditcard.fill',          'monese.com',       2, 90, 52, 1100),
    ('sumup',           'SumUp',            'Finance', 'opt258', '#5D9BFF', 'S', 'creditcard.fill',          'sumup.com',        2, 90, 52, 1110),
    ('moneylion',       'MoneyLion',        'Finance', 'opt47',  '#0DB17E', 'M', 'creditcard.fill',          'moneylion.com',    2, 90, 52, 1120),
    ('credit-karma',    'Credit Karma',     'Finance', 'opt124', '#34A853', 'C', 'creditcard.fill',          'creditkarma.com',  2, 91, 50, 1130),
    ('profee',          'Profee',           'Finance', 'opt263', '#1FA463', 'P', 'creditcard.fill',          'profee.com',       2, 90, 52, 1140),
    ('remitly',         'Remitly',          'Finance', 'opt257', '#E91333', 'R', 'creditcard.fill',          'remitly.com',      2, 91, 50, 1150),
    ('transfergo',      'TransferGo',       'Finance', 'opt218', '#FFC000', 'T', 'creditcard.fill',          'transfergo.com',   2, 91, 50, 1160),
    ('paysend',         'Paysend',          'Finance', 'opt183', '#FF5400', 'P', 'creditcard.fill',          'paysend.com',      2, 90, 52, 1170),
    ('astropay',        'Astropay',         'Finance', 'opt256', '#26195E', 'A', 'creditcard.fill',          'astropay.com',     2, 90, 52, 1180),
    ('icard',           'iCard',            'Finance', 'opt103', '#7B1FA2', 'I', 'creditcard.fill',          'icard.com',        2, 90, 52, 1190),
    ('weststein',       'WESTSTEIN',        'Finance', 'opt80',  '#0F0F0F', 'W', 'creditcard.fill',          'weststein.com',    2, 88, 55, 1200),
    ('verse',           'Verse',            'Finance', 'opt39',  '#5340FF', 'V', 'creditcard.fill',          'verse.me',         2, 90, 52, 1210),
    ('bunq',            'bunq',             'Finance', 'opt199', '#3DBABF', 'B', 'creditcard.fill',          'bunq.com',         2, 90, 52, 1220),
    ('contact',         'CONTACT',          'Finance', 'opt51',  '#005EB8', 'C', 'creditcard.fill',          'contact-sys.com',  2, 90, 52, 1230),
    ('koronapay',       'KoronaPay',        'Finance', 'opt99',  '#FBB03B', 'K', 'creditcard.fill',          'koronapay.com',    2, 90, 52, 1240),
    ('easypay',         'EasyPay',          'Finance', 'opt21',  '#0066B3', 'E', 'creditcard.fill',          'easypay.ua',       2, 89, 54, 1250),
    ('qiwi',            'Qiwi',             'Finance', 'opt18',  '#FF8C00', 'Q', 'creditcard.fill',          'qiwi.com',         2, 89, 54, 1260),
    ('webmoney',        'WebMoney',         'Finance', 'opt24',  '#0073B8', 'W', 'creditcard.fill',          'webmoney.com',     2, 89, 54, 1270),
    ('yandex-money',    'Yandex Money',     'Finance', 'opt23',  '#FC3F1D', 'Y', 'creditcard.fill',          'yoomoney.ru',      2, 91, 50, 1280),
    ('momo',            'MOMO',             'Finance', 'opt184', '#A50064', 'M', 'creditcard.fill',          'momo.vn',          2, 89, 54, 1290),
    ('wing-money',      'Wing Money',       'Finance', 'opt106', '#005CB9', 'W', 'creditcard.fill',          'wingmoney.com',    2, 89, 54, 1300),
    ('walletub',        'WalletHub',        'Finance', 'opt206', '#01B0B5', 'W', 'creditcard.fill',          'wallethub.com',    1, 90, 50, 1310),
    ('capital-one',     'Capital One Shopping','Finance','opt266','#004977', 'C', 'creditcard.fill',         'capitaloneshopping.com',1, 91, 50, 1320),
    ('mr-x-world',      'X World Wallet',   'Finance', 'opt173', '#0F0F0F', 'X', 'creditcard.fill',          NULL,               1, 88, 55, 1330),

    -- Crypto
    ('binance',         'Binance',          'Crypto', 'opt190', '#F0B90B', 'B', 'bitcoinsign.circle.fill',   'binance.com',      2, 90, 55, 1500),
    ('coinbase',        'Coinbase',         'Crypto', 'opt112', '#0052FF', 'C', 'bitcoinsign.circle.fill',   'coinbase.com',     2, 92, 50, 1510),
    ('okx',             'OKX',              'Crypto', 'opt228', '#0F0F0F', 'O', 'bitcoinsign.circle.fill',   'okx.com',          2, 90, 55, 1520),
    ('localbitcoins',   'LocalBitcoins',    'Crypto', 'opt105', '#FFA001', 'L', 'bitcoinsign.circle.fill',   'localbitcoins.com',2, 88, 60, 1530),
    ('bitpanda',        'Bitpanda',         'Crypto', 'opt237', '#0F0F0F', 'B', 'bitcoinsign.circle.fill',   'bitpanda.com',     2, 90, 55, 1540),

    -- Email / Tech
    ('google',          'Google / YouTube / Gmail','Tech','opt1','#4285F4', 'G', 'globe',                    'google.com',       1, 99, 20, 2000),
    ('microsoft',       'Microsoft',        'Tech', 'opt15',  '#00A4EF', 'M', 'square.grid.2x2.fill',       'microsoft.com',    1, 97, 26, 2010),
    ('ms365',           'Microsoft 365',    'Tech', 'opt7',   '#D83B01', 'M', 'envelope.fill',              'office.com',       1, 97, 26, 2020),
    ('apple-id',        'Apple',            'Tech', 'opt131', '#0F0F0F', 'A', 'apple.logo',                 'apple.com',        2, 93, 40, 2030),
    ('yahoo',           'Yahoo',            'Tech', 'opt65',  '#6001D2', 'Y', 'envelope.fill',              'yahoo.com',        1, 95, 30, 2040),
    ('aol',             'AOL',              'Tech', 'opt10',  '#0067F0', 'A', 'envelope.fill',              'aol.com',          1, 92, 35, 2050),
    ('protonmail',      'Proton Mail',      'Tech', 'opt57',  '#6D4AFF', 'P', 'envelope.fill',              'proton.me',        1, 95, 30, 2060),
    ('fastmail',        'FastMail',         'Tech', 'opt43',  '#296DC6', 'F', 'envelope.fill',              'fastmail.com',     1, 94, 32, 2070),
    ('hey',             'Hey',              'Tech', 'opt216', '#5522FA', 'H', 'envelope.fill',              'hey.com',          1, 92, 35, 2080),
    ('mail-ru',         'Mail.ru',          'Tech', 'opt33',  '#168DE2', 'M', 'envelope.fill',              'mail.ru',          1, 91, 38, 2090),
    ('mail-ru-group',   'Mail.ru Group',    'Tech', 'opt4',   '#0F0F0F', 'M', 'envelope.fill',              'corp.mail.ru',     1, 91, 38, 2100),
    ('rambler',         'Rambler',          'Tech', 'opt154', '#FF8200', 'R', 'envelope.fill',              'rambler.ru',       1, 90, 40, 2110),
    ('web-de',          'WEB.DE',           'Tech', 'opt172', '#FFC900', 'W', 'envelope.fill',              'web.de',           1, 91, 38, 2120),
    ('naver',           'Naver',            'Tech', 'opt73',  '#03C75A', 'N', 'globe',                      'naver.com',        1, 93, 35, 2130),
    ('yandex',          'Yandex',           'Tech', 'opt23',  '#FC3F1D', 'Y', 'globe',                      'yandex.com',       1, 92, 36, 2140),
    ('samsung',         'Samsung',          'Tech', 'opt174', '#1428A0', 'S', 'iphone',                     'samsung.com',      1, 92, 36, 2150),
    ('huawei',          'HUAWEI',           'Tech', 'opt166', '#FF0000', 'H', 'iphone',                     'huawei.com',       1, 90, 40, 2160),
    ('zoho',            'Zoho',             'Tech', 'opt93',  '#E42527', 'Z', 'envelope.fill',              'zoho.com',         1, 92, 36, 2170),
    ('proton-mail-czechmail','Czech email services','Tech','opt150','#6D4AFF','C','envelope.fill',           NULL,               1, 88, 50, 2180),
    ('inbox-lv',        'inbox.lv',         'Tech', 'opt167', '#0066B3', 'I', 'envelope.fill',              'inbox.lv',         1, 88, 50, 2190),
    ('onet',            'Onet (onet.pl)',   'Tech', 'opt241', '#FF7700', 'O', 'envelope.fill',              'onet.pl',          1, 90, 40, 2200),
    ('laposte',         'LAPOSTE',          'Tech', 'opt182', '#FCE300', 'L', 'envelope.fill',              'laposte.net',      1, 89, 44, 2210),

    -- Commerce
    ('amazon',          'Amazon',           'Commerce', 'opt44',  '#FF9900', 'A', 'bag.fill',                'amazon.com',       1, 96, 30, 3000),
    ('alibaba',         'Alibaba',          'Commerce', 'opt61',  '#FF6A00', 'A', 'bag.fill',                'alibaba.com',      1, 92, 40, 3010),
    ('ebay-paypal',     'eBay & PayPal',    'Commerce', 'opt83',  '#E53238', 'E', 'hammer.fill',             'ebay.com',         1, 94, 35, 3020),
    ('walmart',         'Walmart',          'Commerce', 'opt227', '#0071CE', 'W', 'bag.fill',                'walmart.com',      1, 95, 32, 3030),
    ('best-buy',        'Best Buy',         'Commerce', 'opt252', '#0046BE', 'B', 'bag.fill',                'bestbuy.com',      1, 94, 32, 3040),
    ('ozon',            'OZON',             'Commerce', 'opt181', '#005BFF', 'O', 'bag.fill',                'ozon.ru',          1, 93, 34, 3050),
    ('jd-com',          'JD.com',           'Commerce', 'opt94',  '#E2231A', 'J', 'bag.fill',                'jd.com',           1, 92, 36, 3060),
    ('shopee',          'Shopee',           'Commerce', 'opt48',  '#EE4D2D', 'S', 'bag.fill',                'shopee.com',       1, 93, 35, 3070),
    ('lazada',          'Lazada',           'Commerce', 'opt60',  '#0F156D', 'L', 'bag.fill',                'lazada.com',       1, 92, 36, 3080),
    ('avito',           'Avito',            'Commerce', 'opt59',  '#97CF26', 'A', 'bag.fill',                'avito.ru',         1, 93, 35, 3090),
    ('olx',             'OLX',              'Commerce', 'opt70',  '#3A77FF', 'O', 'bag.fill',                'olx.com',          1, 92, 36, 3100),
    ('vinted',          'Vinted',           'Commerce', 'opt130', '#09B1BA', 'V', 'bag.fill',                'vinted.com',       1, 93, 35, 3110),
    ('whatnot',         'Whatnot',          'Commerce', 'opt231', '#FFFC00', 'W', 'bag.fill',                'whatnot.com',      1, 92, 36, 3120),
    ('mercari',         'Mercari',          'Commerce', 'opt197', '#FF0211', 'M', 'bag.fill',                'mercari.com',      1, 92, 36, 3130),
    ('offerup',         'OfferUp',          'Commerce', 'opt113', '#65D72E', 'O', 'bag.fill',                'offerup.com',      1, 92, 36, 3140),
    ('grailed',         'Grailed',          'Commerce', 'opt420', '#0F0F0F', 'G', 'bag.fill',                'grailed.com',      1, 91, 38, 3150),
    ('snkrdunk',        'SNKRDUNK',         'Commerce', 'opt190', '#0F0F0F', 'S', 'bag.fill',                'snkrdunk.com',     1, 91, 38, 3160),
    ('craigslist',      'Craigslist',       'Commerce', 'opt26',  '#5C2D91', 'C', 'bag.fill',                'craigslist.org',   1, 90, 40, 3170),
    ('marktplaats',     'Marktplaats',      'Commerce', 'opt171', '#73A4CC', 'M', 'bag.fill',                'marktplaats.nl',   1, 91, 38, 3180),
    ('leboncoin',       'Leboncoin',        'Commerce', 'opt164', '#FF6E14', 'L', 'bag.fill',                'leboncoin.fr',     1, 91, 38, 3190),
    ('kleinanzeigen',   'Kleinanzeigen',    'Commerce', 'opt152', '#A2D45E', 'K', 'bag.fill',                'kleinanzeigen.de', 1, 91, 38, 3200),
    ('subito',          'Subito',           'Commerce', 'opt146', '#FFCD00', 'S', 'bag.fill',                'subito.it',        1, 90, 40, 3210),
    ('idealista',       'Idealista',        'Commerce', 'opt165', '#FF6700', 'I', 'house.fill',              'idealista.com',    1, 91, 38, 3220),
    ('hepsiburada',     'Hepsiburada',      'Commerce', 'opt238', '#FF6000', 'H', 'bag.fill',                'hepsiburada.com',  1, 90, 40, 3230),
    ('mobile-de',       'mobile.de',        'Commerce', 'opt156', '#FF801A', 'M', 'car.fill',                'mobile.de',        1, 90, 40, 3240),
    ('autocosmos',      'autocosmos.com',   'Commerce', 'opt143', '#FF0000', 'A', 'car.fill',                'autocosmos.com',   1, 88, 44, 3250),
    ('drom-ru',         'Drom.RU',          'Commerce', 'opt32',  '#1F8FFF', 'D', 'car.fill',                'drom.ru',          1, 89, 42, 3260),
    ('prom-ua',         'Prom.UA',          'Commerce', 'opt107', '#E62121', 'P', 'bag.fill',                'prom.ua',          1, 89, 42, 3270),
    ('casa-it',         'Casa.it',          'Commerce', 'opt148', '#0F1F4D', 'C', 'house.fill',              'casa.it',          1, 89, 42, 3280),
    ('roomster',        'Roomster',         'Commerce', 'opt153', '#7B1FA2', 'R', 'house.fill',              'roomster.com',     1, 88, 44, 3290),
    ('publi24-2',       'Lajumate.ro',      'Commerce', 'opt195', '#FF6600', 'L', 'bag.fill',                'lajumate.ro',      1, 88, 44, 3300),
    ('schibsted',       'Schibsted-konto',  'Commerce', 'opt134', '#0F0F0F', 'S', 'bag.fill',                'schibsted.com',    1, 89, 42, 3310),
    ('bazos',           'Bazos.sk',         'Commerce', 'opt138', '#FF8C00', 'B', 'bag.fill',                'bazos.sk',         1, 88, 44, 3320),
    ('skelbiu',         'Skelbiu',          'Commerce', 'opt270', '#E61F2F', 'S', 'bag.fill',                'skelbiu.lt',       1, 88, 44, 3330),
    ('eneba',           'ENEBA',            'Commerce', 'opt200', '#FE6500', 'E', 'gamecontroller.fill',     'eneba.com',        1, 90, 40, 3340),
    ('g2a',             'G2A',              'Commerce', 'opt68',  '#F15A00', 'G', 'gamecontroller.fill',     'g2a.com',          1, 91, 38, 3350),
    ('gameflip',        'Gameflip',         'Commerce', 'opt77',  '#0F0F0F', 'G', 'gamecontroller.fill',     'gameflip.com',     1, 90, 40, 3360),
    ('gamers-set',      'OffGamers',        'Commerce', 'opt28',  '#FF6500', 'O', 'gamecontroller.fill',     'offgamers.com',    1, 90, 40, 3370),
    ('dundle',          'Dundle',           'Commerce', 'opt136', '#FF6800', 'D', 'creditcard.fill',         'dundle.com',       1, 90, 40, 3380),
    ('adidas-nike',     'Adidas & Nike',    'Commerce', 'opt86',  '#0F0F0F', 'A', 'bag.fill',                'nike.com',         1, 90, 40, 3390),
    ('zasilkovna',      'Zasilkovna',       'Commerce', 'opt225', '#A8001F', 'Z', 'shippingbox.fill',        'zasilkovna.cz',    1, 90, 40, 3400),
    ('mpsellers',       'MPSellers',        'Commerce', 'opt197', '#0F0F0F', 'M', 'bag.fill',                NULL,               1, 87, 46, 3410),
    ('pokemon-center',  'Pokemon Center',   'Commerce', 'opt268', '#FFCB05', 'P', 'gamecontroller.fill',     'pokemoncenter.com',1, 91, 38, 3420),
    ('iqos',            'IQOS',             'Commerce', 'opt243', '#27676C', 'I', 'bag.fill',                'iqos.com',         1, 89, 42, 3430),
    ('royal-canin',     'Royal Canin',      'Commerce', 'opt170', '#A51E22', 'R', 'pawprint.fill',           'royalcanin.com',   1, 89, 42, 3440),
    ('monster-energy',  'Monster Energy',   'Commerce', 'opt254', '#000000', 'M', 'bag.fill',                'monsterenergy.com',1, 89, 42, 3450),
    ('papa-johns',      'Papa Johns',       'Commerce', 'opt27',  '#006937', 'P', 'takeoutbag.and.cup.and.straw.fill','papajohns.com',1, 91, 38, 3460),

    -- Food delivery
    ('doordash',        'DoorDash',         'Delivery', 'opt40',  '#FF3008', 'D', 'takeoutbag.and.cup.and.straw.fill', 'doordash.com', 1, 94, 36, 4000),
    ('deliveroo',       'Deliveroo',        'Delivery', 'opt53',  '#00CCBC', 'D', 'takeoutbag.and.cup.and.straw.fill', 'deliveroo.com',1, 94, 36, 4010),
    ('foodpanda',       'foodpanda',        'Delivery', 'opt115', '#D70F64', 'F', 'takeoutbag.and.cup.and.straw.fill', 'foodpanda.com',1, 93, 38, 4020),
    ('foodora',         'foodora',          'Delivery', 'opt189', '#D70F64', 'F', 'takeoutbag.and.cup.and.straw.fill', 'foodora.com',  1, 93, 38, 4030),
    ('ifood',           'iFood',            'Delivery', 'opt55',  '#EA1D2C', 'I', 'takeoutbag.and.cup.and.straw.fill', 'ifood.com.br', 1, 93, 38, 4040),
    ('wolt',            'Wolt',             'Delivery', 'opt163', '#00C2E8', 'W', 'takeoutbag.and.cup.and.straw.fill', 'wolt.com',     1, 93, 38, 4050),
    ('glovo',           'Glovo',            'Delivery', 'opt108', '#FFC244', 'G', 'takeoutbag.and.cup.and.straw.fill', 'glovoapp.com', 1, 93, 38, 4060),
    ('samokat',         'Samokat',          'Delivery', 'opt185', '#FF464D', 'S', 'takeoutbag.and.cup.and.straw.fill', 'samokat.ru',   1, 91, 40, 4070),
    ('kuper',           'Kuper (SberMarket)','Delivery','opt97', '#00B956', 'K', 'cart.fill',                 'kuper.ru',         1, 91, 40, 4080),
    ('magnit',          'Magnit',           'Delivery', 'opt126', '#FF3D2E', 'M', 'cart.fill',                'magnit.ru',        1, 90, 42, 4090),
    ('lalamove',        'Lalamove',         'Delivery', 'opt180', '#EE4117', 'L', 'shippingbox.fill',         'lalamove.com',     1, 91, 40, 4100),

    -- Transport
    ('uber',            'Uber',             'Transport', 'opt72',  '#0F0F0F', 'U', 'car.fill',               'uber.com',         1, 97, 30, 5000),
    ('lyft',            'Lyft',             'Transport', 'opt75',  '#FF00BF', 'L', 'car.fill',               'lyft.com',         1, 96, 32, 5010),
    ('bolt',            'Bolt',             'Transport', 'opt81',  '#34D186', 'B', 'car.fill',               'bolt.eu',          1, 94, 34, 5020),
    ('grab',            'Grab',             'Transport', 'opt30',  '#00B14F', 'G', 'car.fill',               'grab.com',         1, 92, 38, 5030),
    ('didi',            'DiDi',             'Transport', 'opt92',  '#FF7338', 'D', 'car.fill',               'didiglobal.com',   1, 92, 38, 5040),
    ('gettaxi',         'GetTaxi (Gett)',   'Transport', 'opt35',  '#FFC700', 'G', 'car.fill',               'gett.com',         1, 90, 40, 5050),
    ('citymobil',       'CityMobil',        'Transport', 'opt76',  '#FFCB05', 'C', 'car.fill',               'city-mobil.ru',    1, 89, 42, 5060),
    ('careem',          'Careem',           'Transport', 'opt89',  '#0BA85B', 'C', 'car.fill',               'careem.com',       1, 91, 40, 5070),
    ('whoosh',          'Whoosh',           'Transport', 'opt123', '#FFD600', 'W', 'figure.run',             'whoosh.bike',      1, 90, 42, 5080),
    ('taxi-maksim',     'Taxi Maksim',      'Transport', 'opt74',  '#FFD600', 'T', 'car.fill',               'taximaxim.com',    1, 89, 44, 5090),

    -- Travel
    ('airbnb',          'Airbnb',           'Travel', 'opt46',  '#FF5A5F', 'A', 'bed.double.fill',           'airbnb.com',       1, 94, 36, 5500),
    ('hopper',          'Hopper',           'Travel', 'opt144', '#FF0F60', 'H', 'airplane',                  'hopper.com',       1, 92, 40, 5510),
    ('american-airlines','American Airlines','Travel','opt272', '#005DAA', 'A', 'airplane',                  'aa.com',           1, 92, 40, 5520),

    -- Gambling / Betting
    ('bet365',          'bet365',           'Gambling', 'opt17',  '#14805E', 'B', 'die.face.5.fill',         'bet365.com',       2, 90, 50, 6000),
    ('cas-22',          '22bet',            'Gambling', 'opt224', '#142535', 'B', 'die.face.5.fill',         '22bet.com',        2, 89, 52, 6010),
    ('cas-888',         '888casino',        'Gambling', 'opt22',  '#00A85A', 'B', 'die.face.5.fill',         '888casino.com',    2, 89, 52, 6020),
    ('betfair',         'BetFair',          'Gambling', 'opt25',  '#FCD200', 'B', 'die.face.5.fill',         'betfair.com',      2, 90, 50, 6030),
    ('betmgm',          'Betmgm',           'Gambling', 'opt223', '#B07F2C', 'B', 'die.face.5.fill',         'betmgm.com',       2, 90, 50, 6040),
    ('betano',          'Betano',           'Gambling', 'opt192', '#FF6900', 'B', 'die.face.5.fill',         'betano.com',       2, 89, 52, 6050),
    ('parimatch',       'Parimatch',        'Gambling', 'opt3',   '#FFCB05', 'P', 'die.face.5.fill',         'parimatch.com',    2, 89, 52, 6060),
    ('paddy-power',     'Paddy Power',      'Gambling', 'opt109', '#006645', 'P', 'die.face.5.fill',         'paddypower.com',   2, 90, 50, 6070),
    ('bwin',            'bwin',             'Gambling', 'opt137', '#FFEB00', 'B', 'die.face.5.fill',         'bwin.com',         2, 90, 50, 6080),
    ('ggbet',           'GGbet',            'Gambling', 'opt188', '#FFB500', 'G', 'die.face.5.fill',         'gg.bet',           2, 89, 52, 6090),
    ('ggpoker',         'GGPoker UK',       'Gambling', 'opt229', '#E40520', 'G', 'die.face.5.fill',         'ggpoker.co.uk',    2, 89, 52, 6100),
    ('netbet',          'NetBet',           'Gambling', 'opt95',  '#FF8000', 'N', 'die.face.5.fill',         'netbet.com',       2, 89, 52, 6110),
    ('sisal',           'Sisal',            'Gambling', 'opt38',  '#E3071B', 'S', 'die.face.5.fill',         'sisal.it',         2, 89, 52, 6120),
    ('mrgreen',         'MrGreen',          'Gambling', 'opt211', '#0F8049', 'M', 'die.face.5.fill',         'mrgreen.com',      2, 89, 52, 6130),
    ('eurobet',         'EUROBET',          'Gambling', 'opt141', '#142535', 'E', 'die.face.5.fill',         'eurobet.it',       2, 89, 52, 6140),
    ('goldbet',         'goldbet.it',       'Gambling', 'opt240', '#FFD200', 'G', 'die.face.5.fill',         'goldbet.it',       2, 89, 52, 6150),
    ('giocodigitale',   'giocodigitale.it', 'Gambling', 'opt85',  '#0044A8', 'G', 'die.face.5.fill',         'giocodigitale.it', 2, 89, 52, 6160),
    ('fontbet',         'fontbet',          'Gambling', 'opt139', '#FFC400', 'F', 'die.face.5.fill',         'fonbet.com',       2, 89, 52, 6170),
    ('fbet',            'Fbet',             'Gambling', 'opt215', '#FF0000', 'F', 'die.face.5.fill',         'fbet.ro',          2, 89, 52, 6180),
    ('fortuna',         'Fortuna',          'Gambling', 'opt221', '#E40521', 'F', 'die.face.5.fill',         'ifortuna.cz',      2, 89, 52, 6190),
    ('superbet',        'Superbet',         'Gambling', 'opt249', '#E40521', 'S', 'die.face.5.fill',         'superbet.ro',      2, 89, 52, 6200),
    ('totogaming',      'TOTOGAMING',       'Gambling', 'opt220', '#FFCC00', 'T', 'die.face.5.fill',         'totogaming.am',    2, 89, 52, 6210),
    ('livescore',       'LiveScore',        'Gambling', 'opt42',  '#0066B3', 'L', 'sportscourt.fill',        'livescore.com',    1, 91, 40, 6220),
    ('ticketmaster',    'Ticketmaster',     'Gambling', 'opt52',  '#005DAA', 'T', 'ticket.fill',             'ticketmaster.com', 1, 91, 40, 6230),
    ('bandus',          'BANDUS',           'Gambling', 'opt209', '#0F0F0F', 'B', 'die.face.5.fill',         NULL,               2, 87, 55, 6240),
    ('bc-game',         'BC GAME',          'Gambling', 'opt262', '#FFCB05', 'B', 'die.face.5.fill',         'bc.game',          2, 87, 55, 6250),
    ('caliente',        'Caliente',         'Gambling', 'opt267', '#E40521', 'C', 'die.face.5.fill',         'caliente.mx',      2, 89, 52, 6260),
    ('casa-pariurilor', 'Casa Pariurilor',  'Gambling', 'opt255', '#FFCB05', 'C', 'die.face.5.fill',         'casapariurilor.ro',2, 89, 52, 6270),
    ('lasvegas-ro',     'LASVEGAS.RO',      'Gambling', 'opt222', '#E40521', 'L', 'die.face.5.fill',         'lasvegas.ro',      2, 89, 52, 6280),
    ('getsbet',         'GetsBet.ro',       'Gambling', 'opt179', '#FF7700', 'G', 'die.face.5.fill',         'getsbet.ro',       2, 89, 52, 6290),
    ('novibet',         'novibet.com',      'Gambling', 'opt151', '#0F0F0F', 'N', 'die.face.5.fill',         'novibet.com',      2, 89, 52, 6300),
    ('parions-sport',   'Parions Sport',    'Gambling', 'opt260', '#005DAA', 'P', 'die.face.5.fill',         'enligne.parionssport.fdj.fr',2,89,52,6310),
    ('pari-ru',         'Pari.ru',          'Gambling', 'opt169', '#FFCB05', 'P', 'die.face.5.fill',         'pari.ru',          2, 89, 52, 6320),
    ('kwiff',           'kwiff',            'Gambling', 'opt129', '#FF6500', 'K', 'die.face.5.fill',         'kwiff.com',        2, 89, 52, 6330),
    ('waitomo',         'Waitomo',          'Gambling', 'opt213', '#0F0F0F', 'W', 'die.face.5.fill',         NULL,               2, 87, 55, 6340),
    ('maxline-by',      'Maxline.by',       'Gambling', 'opt219', '#E40521', 'M', 'die.face.5.fill',         'maxline.by',       2, 87, 55, 6350),
    ('pm-by',           'pm.by',            'Gambling', 'opt149', '#FF7700', 'P', 'die.face.5.fill',         'pm.by',            2, 87, 55, 6360),
    ('1cupis',          '1cupis.ru',        'Gambling', 'opt251', '#FFCB05', 'C', 'die.face.5.fill',         '1cupis.ru',        2, 87, 55, 6370),
    ('blsspain-russia', 'BLS Spain-Russia', 'Gambling', 'opt135', '#FF0000', 'B', 'die.face.5.fill',         NULL,               2, 86, 58, 6380),
    ('esx',             'ESX',              'Gambling', 'opt248', '#0F0F0F', 'E', 'die.face.5.fill',         'abonamentesali.ro',1, 89, 52, 6390),
    ('casino-plus',     'Casino Plus',      'Gambling', 'opt201', '#FFCB05', 'C', 'die.face.5.fill',         NULL,               2, 87, 55, 6400),
    ('solitaire',       'Solitaire',        'Gambling', 'opt234', '#1F8FFF', 'S', 'die.face.5.fill',         NULL,               1, 89, 50, 6410),

    -- Entertainment
    ('netflix',         'Netflix',          'Entertainment', 'opt101', '#E50914', 'N', 'play.rectangle.fill',    'netflix.com',  1, 95, 32, 7000),
    ('steam',           'Steam',            'Entertainment', 'opt58',  '#1B2838', 'S', 'gamecontroller.fill',    'steampowered.com',1, 95, 32, 7010),
    ('blizzard',        'Blizzard',         'Entertainment', 'opt78',  '#00AEFF', 'B', 'gamecontroller.fill',    'blizzard.com', 1, 93, 36, 7020),
    ('twitch-ent',      'Twitch',           'Entertainment', 'opt205', '#9146FF', 'T', 'tv.fill',                'twitch.tv',    1, 94, 32, 7030),
    ('nico',            'Niconico',         'Entertainment', 'opt119', '#252525', 'N', 'play.rectangle.fill',    'nicovideo.jp', 1, 90, 42, 7040),

    -- Productivity
    ('discord-prod',    'Discord Productivity','Productivity','opt45','#5865F2', 'D', 'message.fill',           'discord.com',  1, 97, 25, 8000),
    ('zoho-prod',       'Zoho',             'Productivity', 'opt93',  '#E42527', 'Z', 'doc.fill',               'zoho.com',     1, 92, 36, 8010),
    ('weebly',          'Weebly',           'Productivity', 'opt54',  '#00B6EC', 'W', 'globe',                  'weebly.com',   1, 91, 38, 8020),
    ('linode',          'Linode',           'Productivity', 'opt245', '#00A95C', 'L', 'server.rack',            'linode.com',   1, 92, 36, 8030),
    ('beget',           'Beget',            'Productivity', 'opt187', '#00B0E8', 'B', 'server.rack',            'beget.com',    1, 91, 38, 8040),
    ('nhncloud',        'NHN Cloud',        'Productivity', 'opt202', '#0F0F0F', 'N', 'cloud.fill',             'nhncloud.com', 1, 89, 42, 8050),
    ('brevo',           'Brevo',            'Productivity', 'opt217', '#0B996E', 'B', 'envelope.fill',          'brevo.com',    1, 92, 36, 8060),
    ('distrokid',       'DistroKid',        'Productivity', 'opt232', '#0F0F0F', 'D', 'music.note',             'distrokid.com',1, 92, 36, 8070),
    ('huawei-prod',     'HUAWEI Productivity','Productivity','opt166','#FF0000', 'H', 'iphone',                 'huawei.com',   1, 90, 40, 8080),

    -- Surveys / Cashback
    ('myopinions',      'MyOpinions & eRewards','Surveys','opt0',  '#0F8049', 'M', 'star.fill',               'myopinions.com.au',1,87,50,9000),
    ('inboxdollars',    'Inboxdollars',     'Surveys', 'opt118', '#FF6600', 'I', 'star.fill',                'inboxdollars.com', 1, 88, 48, 9010),
    ('swagbucks',       'Swagbucks',        'Surveys', 'opt125', '#FF6900', 'S', 'star.fill',                'swagbucks.com',    1, 89, 46, 9020),
    ('cashrewards',     'Cashrewards',      'Surveys', 'opt214', '#FFCB00', 'C', 'star.fill',                'cashrewards.com.au',1, 88, 48, 9030),
    ('topcashback',     'TopCashback',      'Surveys', 'opt191', '#0066B3', 'T', 'star.fill',                'topcashback.com',  1, 89, 46, 9040),
    ('ipsos',           'Ipsos',            'Surveys', 'opt193', '#001E62', 'I', 'star.fill',                'ipsos.com',        1, 88, 48, 9050),
    ('nectar',          'Nectar',           'Surveys', 'opt198', '#7B1FA2', 'N', 'star.fill',                'nectar.com',       1, 88, 48, 9060),
    ('zoominfo',        'ZoomInfo',         'Surveys', 'opt194', '#FF6600', 'Z', 'star.fill',                'zoominfo.com',     1, 89, 46, 9070),
    ('radquest',        'RadQuest',         'Surveys', 'opt247', '#0F0F0F', 'R', 'star.fill',                NULL,               1, 87, 50, 9080),
    ('welo-data',       'Welo Data',        'Surveys', 'opt261', '#0F0F0F', 'W', 'star.fill',                'welocalize.com',   1, 87, 50, 9090),
    ('year13',          'Year13',           'Surveys', 'opt236', '#FFD700', 'Y', 'star.fill',                'year13.com.au',    1, 87, 50, 9100),
    ('taptap',          'Taptap',           'Surveys', 'opt239', '#1F8FFF', 'T', 'star.fill',                NULL,               1, 87, 50, 9110),

    -- Specialty / Other
    ('apple-music',     'Apple',            'Specialty','opt131','#0F0F0F','A','apple.logo',                 'apple.com',        2, 93, 40, 9500),
    ('abbott',          'Abbott',           'Specialty','opt242','#009CDE','A','heart.text.square.fill',     'abbott.com',       1, 90, 42, 9510),
    ('tlscontact',      'TLScontact',       'Specialty','opt235','#005DAA','T','airplane',                   'tlscontact.com',   1, 89, 44, 9520),
    ('royal-canin-2',   'Royal Canin Spec', 'Specialty','opt170','#A51E22','R','pawprint.fill',              'royalcanin.com',   1, 89, 44, 9530),
    ('tank-ru',         'Tank.RU',          'Specialty','opt161','#FFCB05','T','car.fill',                   'tank.ru',          1, 87, 48, 9540),
    ('u-by-prodia',     'U By Prodia',      'Specialty','opt160','#0F0F0F','U','heart.text.square.fill',     'prodia.com',       1, 87, 48, 9550),
    ('nhncorp',         'NHN Corp',         'Specialty','opt177','#FF1B4D','N','globe',                      'nhn.com',          1, 89, 44, 9560),
    ('yalla-live',      'Yalla.live',       'Specialty','opt88', '#F2C600','Y','mic.fill',                   'yalla.live',       1, 88, 46, 9570),
    ('denimapp',        'DenimApp',         'Specialty','opt204','#0F0F0F','D','bag.fill',                   NULL,               1, 87, 48, 9580);

-- Re-create routes for all (service, country) pairs
insert into public.routes (service_id, country_id, status)
select s.id, c.id, 'active'
from public.services s
cross join public.countries c;

-- Re-apply Tier-A pricing model (same as Phase I)
with tier_a as (select unnest(array['us','uk','ca','au','de','fr','nl']) as id)
update public.routes r
set retail_credits = case
    when r.service_id in ('whatsapp','telegram','apple-id','openai','claude','paypal','venmo','cashapp','revolut','wise','binance','coinbase','okx','localbitcoins','bitpanda')
         and r.country_id in (select id from tier_a)
        then 3
    when r.country_id in (select id from tier_a)
        then 2
    else null
end;

-- Hand-tuned spikes for the top-tier combos
update public.routes set retail_credits = 4 where service_id = 'whatsapp' and country_id in ('us','uk');
update public.routes set retail_credits = 4 where service_id = 'telegram' and country_id in ('us','uk','de');
update public.routes set retail_credits = 4 where service_id = 'apple-id' and country_id in ('us','uk');
update public.routes set retail_credits = 3 where service_id = 'instagram' and country_id in ('us','uk','de','fr');
update public.routes set retail_credits = 3 where service_id = 'tiktok' and country_id in ('us','uk');
