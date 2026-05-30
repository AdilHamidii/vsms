import SwiftUI

/// In-app defaults mirroring supabase/migrations/20260530100000_brand_catalog.sql.
/// Used as a brief flash before the live catalog fetch returns.
enum SeedData {
    static let services: [Service] = [
        // Messaging
        .init(id: "whatsapp",   name: "WhatsApp",   category: "Messaging", glyph: "W", icon: "bubble.left.fill",                  domain: "whatsapp.com",     tintHex: "#25D366", smspvaCode: "opt0",   cost: 1, successRate: 96, etaSeconds: 28, sortOrder: 10),
        .init(id: "telegram",   name: "Telegram",   category: "Messaging", glyph: "T", icon: "paperplane.fill",                   domain: "telegram.org",     tintHex: "#0088CC", smspvaCode: "opt29",  cost: 1, successRate: 98, etaSeconds: 22, sortOrder: 20),
        .init(id: "signal",     name: "Signal",     category: "Messaging", glyph: "S", icon: "bubble.left.fill",                  domain: "signal.org",       tintHex: "#3A76F0", smspvaCode: "opt22",  cost: 1, successRate: 97, etaSeconds: 24, sortOrder: 30),
        .init(id: "discord",    name: "Discord",    category: "Messaging", glyph: "D", icon: "bubble.left.and.bubble.right.fill", domain: "discord.com",      tintHex: "#5865F2", smspvaCode: "opt39",  cost: 1, successRate: 97, etaSeconds: 25, sortOrder: 40),
        .init(id: "viber",      name: "Viber",      category: "Messaging", glyph: "V", icon: "phone.bubble.left.fill",            domain: "viber.com",        tintHex: "#7360F2", smspvaCode: "opt8",   cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 50),
        .init(id: "wechat",     name: "WeChat",     category: "Messaging", glyph: "W", icon: "bubble.left.fill",                  domain: "wechat.com",       tintHex: "#7BB32E", smspvaCode: "opt7",   cost: 1, successRate: 94, etaSeconds: 32, sortOrder: 60),
        .init(id: "line",       name: "LINE",       category: "Messaging", glyph: "L", icon: "bubble.left.fill",                  domain: "line.me",          tintHex: "#00C300", smspvaCode: "opt12",  cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 70),
        .init(id: "snapchat",   name: "Snapchat",   category: "Messaging", glyph: "S", icon: "camera.fill",                       domain: "snapchat.com",     tintHex: "#FFFC00", smspvaCode: "opt28",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 80),
        .init(id: "messenger",  name: "Messenger",  category: "Messaging", glyph: "M", icon: "bubble.left.fill",                  domain: "messenger.com",    tintHex: "#0078FF", smspvaCode: "opt2",   cost: 1, successRate: 95, etaSeconds: 28, sortOrder: 90),
        .init(id: "kakaotalk",  name: "KakaoTalk",  category: "Messaging", glyph: "K", icon: "bubble.left.fill",                  domain: "kakaocorp.com",    tintHex: "#FFE812", smspvaCode: "opt27",  cost: 1, successRate: 93, etaSeconds: 35, sortOrder: 100),
        // Social
        .init(id: "facebook",   name: "Facebook",   category: "Social", glyph: "F", icon: "photo.fill",                           domain: "facebook.com",     tintHex: "#1877F2", smspvaCode: "opt2",   cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 110),
        .init(id: "instagram",  name: "Instagram",  category: "Social", glyph: "I", icon: "camera.fill",                          domain: "instagram.com",    tintHex: "#E4405F", smspvaCode: "opt16",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 120),
        .init(id: "tiktok",     name: "TikTok",     category: "Social", glyph: "T", icon: "play.tv.fill",                         domain: "tiktok.com",       tintHex: "#0F0F0F", smspvaCode: "opt167", cost: 1, successRate: 91, etaSeconds: 45, sortOrder: 130),
        .init(id: "twitter-x",  name: "Twitter / X",category: "Social", glyph: "X", icon: "at",                                   domain: "x.com",            tintHex: "#0F0F0F", smspvaCode: "opt41",  cost: 1, successRate: 92, etaSeconds: 42, sortOrder: 140),
        .init(id: "linkedin",   name: "LinkedIn",   category: "Social", glyph: "L", icon: "briefcase.fill",                       domain: "linkedin.com",     tintHex: "#0A66C2", smspvaCode: "opt33",  cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 150),
        .init(id: "reddit",     name: "Reddit",     category: "Social", glyph: "R", icon: "text.bubble.fill",                     domain: "reddit.com",       tintHex: "#FF4500", smspvaCode: "opt34",  cost: 1, successRate: 93, etaSeconds: 35, sortOrder: 160),
        .init(id: "pinterest",  name: "Pinterest",  category: "Social", glyph: "P", icon: "pin.fill",                             domain: "pinterest.com",    tintHex: "#E60023", smspvaCode: "opt38",  cost: 1, successRate: 92, etaSeconds: 40, sortOrder: 170),
        .init(id: "youtube",    name: "YouTube",    category: "Social", glyph: "Y", icon: "play.rectangle.fill",                  domain: "youtube.com",      tintHex: "#FF0000", smspvaCode: "opt15",  cost: 1, successRate: 96, etaSeconds: 28, sortOrder: 180),
        .init(id: "twitch",     name: "Twitch",     category: "Social", glyph: "T", icon: "tv.fill",                              domain: "twitch.tv",        tintHex: "#9146FF", smspvaCode: "opt77",  cost: 1, successRate: 94, etaSeconds: 32, sortOrder: 190),
        .init(id: "threads",    name: "Threads",    category: "Social", glyph: "T", icon: "at",                                   domain: "threads.net",      tintHex: "#0F0F0F", smspvaCode: "opt168", cost: 1, successRate: 90, etaSeconds: 45, sortOrder: 200),
        .init(id: "vk",         name: "VK",         category: "Social", glyph: "V", icon: "text.bubble.fill",                     domain: "vk.com",           tintHex: "#0077FF", smspvaCode: "opt3",   cost: 1, successRate: 93, etaSeconds: 35, sortOrder: 210),
        .init(id: "mastodon",   name: "Mastodon",   category: "Social", glyph: "M", icon: "at",                                   domain: "joinmastodon.org", tintHex: "#6364FF", smspvaCode: "opt148", cost: 1, successRate: 88, etaSeconds: 50, sortOrder: 220),
        // Tech
        .init(id: "google",     name: "Google",     category: "Tech", glyph: "G", icon: "globe",                                  domain: "google.com",       tintHex: "#4285F4", smspvaCode: "opt1",   cost: 1, successRate: 99, etaSeconds: 20, sortOrder: 230),
        .init(id: "gmail",      name: "Gmail",      category: "Tech", glyph: "M", icon: "envelope.fill",                          domain: "gmail.com",        tintHex: "#EA4335", smspvaCode: "opt15",  cost: 1, successRate: 98, etaSeconds: 22, sortOrder: 240),
        .init(id: "yahoo",      name: "Yahoo",      category: "Tech", glyph: "Y", icon: "envelope.fill",                          domain: "yahoo.com",        tintHex: "#6001D2", smspvaCode: "opt12",  cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 250),
        .init(id: "outlook",    name: "Outlook",    category: "Tech", glyph: "O", icon: "envelope.fill",                          domain: "outlook.com",      tintHex: "#0078D4", smspvaCode: "opt55",  cost: 1, successRate: 97, etaSeconds: 26, sortOrder: 260),
        .init(id: "protonmail", name: "Proton Mail",category: "Tech", glyph: "P", icon: "envelope.fill",                          domain: "proton.me",        tintHex: "#6D4AFF", smspvaCode: "opt149", cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 270),
        .init(id: "openai",     name: "OpenAI",     category: "Tech", glyph: "O", icon: "sparkles",                               domain: "openai.com",       tintHex: "#10A37F", smspvaCode: "opt177", cost: 2, successRate: 95, etaSeconds: 32, sortOrder: 280),
        .init(id: "github",     name: "GitHub",     category: "Tech", glyph: "G", icon: "chevron.left.forwardslash.chevron.right",domain: "github.com",       tintHex: "#0F0F0F", smspvaCode: "opt43",  cost: 1, successRate: 96, etaSeconds: 28, sortOrder: 290),
        .init(id: "apple-id",   name: "Apple ID",   category: "Tech", glyph: "A", icon: "apple.logo",                             domain: "apple.com",        tintHex: "#0F0F0F", smspvaCode: "opt9",   cost: 2, successRate: 93, etaSeconds: 40, sortOrder: 300),
        .init(id: "yandex",     name: "Yandex",     category: "Tech", glyph: "Y", icon: "globe",                                  domain: "yandex.com",       tintHex: "#FC3F1D", smspvaCode: "opt6",   cost: 1, successRate: 92, etaSeconds: 36, sortOrder: 310),
        // Finance
        .init(id: "paypal",     name: "PayPal",     category: "Finance", glyph: "P", icon: "creditcard.fill",                     domain: "paypal.com",       tintHex: "#003087", smspvaCode: "opt71",  cost: 2, successRate: 92, etaSeconds: 50, sortOrder: 320),
        .init(id: "venmo",      name: "Venmo",      category: "Finance", glyph: "V", icon: "creditcard.fill",                     domain: "venmo.com",        tintHex: "#008CFF", smspvaCode: "opt72",  cost: 2, successRate: 91, etaSeconds: 50, sortOrder: 330),
        .init(id: "cashapp",    name: "Cash App",   category: "Finance", glyph: "C", icon: "creditcard.fill",                     domain: "cash.app",         tintHex: "#00D632", smspvaCode: "opt73",  cost: 2, successRate: 90, etaSeconds: 55, sortOrder: 340),
        .init(id: "revolut",    name: "Revolut",    category: "Finance", glyph: "R", icon: "creditcard.fill",                     domain: "revolut.com",      tintHex: "#0F0F0F", smspvaCode: "opt74",  cost: 2, successRate: 92, etaSeconds: 48, sortOrder: 350),
        .init(id: "wise",       name: "Wise",       category: "Finance", glyph: "W", icon: "creditcard.fill",                     domain: "wise.com",         tintHex: "#9FE870", smspvaCode: "opt75",  cost: 2, successRate: 93, etaSeconds: 45, sortOrder: 360),
        .init(id: "binance",    name: "Binance",    category: "Finance", glyph: "B", icon: "bitcoinsign.circle.fill",             domain: "binance.com",      tintHex: "#F0B90B", smspvaCode: "opt56",  cost: 2, successRate: 90, etaSeconds: 55, sortOrder: 370),
        .init(id: "coinbase",   name: "Coinbase",   category: "Finance", glyph: "C", icon: "bitcoinsign.circle.fill",             domain: "coinbase.com",     tintHex: "#0052FF", smspvaCode: "opt57",  cost: 2, successRate: 92, etaSeconds: 50, sortOrder: 380),
        .init(id: "crypto-com", name: "Crypto.com", category: "Finance", glyph: "C", icon: "bitcoinsign.circle.fill",             domain: "crypto.com",       tintHex: "#003D7A", smspvaCode: "opt58",  cost: 2, successRate: 90, etaSeconds: 55, sortOrder: 390),
        .init(id: "kraken",     name: "Kraken",     category: "Finance", glyph: "K", icon: "bitcoinsign.circle.fill",             domain: "kraken.com",       tintHex: "#5848D6", smspvaCode: "opt59",  cost: 2, successRate: 89, etaSeconds: 60, sortOrder: 400),
        .init(id: "kucoin",     name: "KuCoin",     category: "Finance", glyph: "K", icon: "bitcoinsign.circle.fill",             domain: "kucoin.com",       tintHex: "#24AE8F", smspvaCode: "opt60",  cost: 2, successRate: 88, etaSeconds: 65, sortOrder: 410),
        // Commerce
        .init(id: "amazon",     name: "Amazon",     category: "Commerce", glyph: "A", icon: "bag.fill",                           domain: "amazon.com",       tintHex: "#FF9900", smspvaCode: "opt19",  cost: 1, successRate: 96, etaSeconds: 30, sortOrder: 420),
        .init(id: "ebay",       name: "eBay",       category: "Commerce", glyph: "E", icon: "hammer.fill",                        domain: "ebay.com",         tintHex: "#0F0F0F", smspvaCode: "opt20",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 430),
        .init(id: "aliexpress", name: "AliExpress", category: "Commerce", glyph: "A", icon: "bag.fill",                           domain: "aliexpress.com",   tintHex: "#FF3E1D", smspvaCode: "opt21",  cost: 1, successRate: 92, etaSeconds: 40, sortOrder: 440),
        .init(id: "shein",      name: "Shein",      category: "Commerce", glyph: "S", icon: "bag.fill",                           domain: "shein.com",        tintHex: "#0F0F0F", smspvaCode: "opt23",  cost: 1, successRate: 91, etaSeconds: 42, sortOrder: 450),
        .init(id: "temu",       name: "Temu",       category: "Commerce", glyph: "T", icon: "bag.fill",                           domain: "temu.com",         tintHex: "#FB7701", smspvaCode: "opt24",  cost: 1, successRate: 92, etaSeconds: 40, sortOrder: 460),
        .init(id: "walmart",    name: "Walmart",    category: "Commerce", glyph: "W", icon: "bag.fill",                           domain: "walmart.com",      tintHex: "#0071CE", smspvaCode: "opt25",  cost: 1, successRate: 95, etaSeconds: 32, sortOrder: 470),
        // Delivery
        .init(id: "doordash",   name: "DoorDash",   category: "Delivery", glyph: "D", icon: "takeoutbag.and.cup.and.straw.fill",  domain: "doordash.com",     tintHex: "#FF3008", smspvaCode: "opt37",  cost: 1, successRate: 94, etaSeconds: 36, sortOrder: 480),
        .init(id: "ubereats",   name: "Uber Eats",  category: "Delivery", glyph: "U", icon: "takeoutbag.and.cup.and.straw.fill",  domain: "ubereats.com",     tintHex: "#06C167", smspvaCode: "opt37",  cost: 1, successRate: 95, etaSeconds: 33, sortOrder: 490),
        .init(id: "instacart",  name: "Instacart",  category: "Delivery", glyph: "I", icon: "cart.fill",                          domain: "instacart.com",    tintHex: "#43B02A", smspvaCode: "opt36",  cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 500),
        .init(id: "grubhub",    name: "Grubhub",    category: "Delivery", glyph: "G", icon: "takeoutbag.and.cup.and.straw.fill",  domain: "grubhub.com",      tintHex: "#FF8000", smspvaCode: "opt37",  cost: 1, successRate: 92, etaSeconds: 40, sortOrder: 510),
        // Transport
        .init(id: "uber",       name: "Uber",       category: "Transport", glyph: "U", icon: "car.fill",                          domain: "uber.com",         tintHex: "#0F0F0F", smspvaCode: "opt5",   cost: 1, successRate: 97, etaSeconds: 30, sortOrder: 520),
        .init(id: "lyft",       name: "Lyft",       category: "Transport", glyph: "L", icon: "car.fill",                          domain: "lyft.com",         tintHex: "#FF00BF", smspvaCode: "opt6",   cost: 1, successRate: 96, etaSeconds: 32, sortOrder: 530),
        .init(id: "bolt",       name: "Bolt",       category: "Transport", glyph: "B", icon: "car.fill",                          domain: "bolt.eu",          tintHex: "#34D186", smspvaCode: "opt78",  cost: 1, successRate: 94, etaSeconds: 34, sortOrder: 540),
        .init(id: "grab",       name: "Grab",       category: "Transport", glyph: "G", icon: "car.fill",                          domain: "grab.com",         tintHex: "#00B14F", smspvaCode: "opt79",  cost: 1, successRate: 92, etaSeconds: 38, sortOrder: 550),
        // Travel
        .init(id: "airbnb",     name: "Airbnb",     category: "Travel", glyph: "A", icon: "bed.double.fill",                      domain: "airbnb.com",       tintHex: "#FF5A5F", smspvaCode: "opt43",  cost: 1, successRate: 94, etaSeconds: 36, sortOrder: 560),
        .init(id: "booking",    name: "Booking.com",category: "Travel", glyph: "B", icon: "bed.double.fill",                      domain: "booking.com",      tintHex: "#003580", smspvaCode: "opt71",  cost: 1, successRate: 95, etaSeconds: 32, sortOrder: 570),
        .init(id: "expedia",    name: "Expedia",    category: "Travel", glyph: "E", icon: "airplane",                             domain: "expedia.com",      tintHex: "#191E3B", smspvaCode: "opt45",  cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 580),
        // Dating
        .init(id: "tinder",     name: "Tinder",     category: "Dating", glyph: "T", icon: "heart.fill",                           domain: "tinder.com",       tintHex: "#FE3C72", smspvaCode: "opt28",  cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 590),
        .init(id: "bumble",     name: "Bumble",     category: "Dating", glyph: "B", icon: "heart.fill",                           domain: "bumble.com",       tintHex: "#FFC629", smspvaCode: "opt30",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 600),
        .init(id: "hinge",      name: "Hinge",      category: "Dating", glyph: "H", icon: "heart.fill",                           domain: "hinge.co",         tintHex: "#0F0F0F", smspvaCode: "opt31",  cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 610),
        .init(id: "grindr",     name: "Grindr",     category: "Dating", glyph: "G", icon: "heart.fill",                           domain: "grindr.com",       tintHex: "#0F0F0F", smspvaCode: "opt32",  cost: 1, successRate: 92, etaSeconds: 40, sortOrder: 620),
        .init(id: "badoo",      name: "Badoo",      category: "Dating", glyph: "B", icon: "heart.fill",                           domain: "badoo.com",        tintHex: "#9C00FF", smspvaCode: "opt34",  cost: 1, successRate: 91, etaSeconds: 42, sortOrder: 630),
        // Entertainment
        .init(id: "netflix",    name: "Netflix",    category: "Entertainment", glyph: "N", icon: "play.rectangle.fill",           domain: "netflix.com",      tintHex: "#E50914", smspvaCode: "opt47",  cost: 1, successRate: 95, etaSeconds: 32, sortOrder: 640),
        .init(id: "spotify",    name: "Spotify",    category: "Entertainment", glyph: "S", icon: "music.note",                    domain: "spotify.com",      tintHex: "#1DB954", smspvaCode: "opt36",  cost: 1, successRate: 96, etaSeconds: 28, sortOrder: 650),
        .init(id: "disney-plus",name: "Disney+",    category: "Entertainment", glyph: "D", icon: "play.rectangle.fill",           domain: "disneyplus.com",   tintHex: "#113CCF", smspvaCode: "opt46",  cost: 1, successRate: 94, etaSeconds: 34, sortOrder: 660),
        .init(id: "hulu",       name: "Hulu",       category: "Entertainment", glyph: "H", icon: "play.rectangle.fill",           domain: "hulu.com",         tintHex: "#1CE783", smspvaCode: "opt48",  cost: 1, successRate: 93, etaSeconds: 36, sortOrder: 670),
        .init(id: "steam",      name: "Steam",      category: "Entertainment", glyph: "S", icon: "gamecontroller.fill",           domain: "steampowered.com", tintHex: "#1B2838", smspvaCode: "opt54",  cost: 1, successRate: 95, etaSeconds: 32, sortOrder: 680),
        .init(id: "roblox",     name: "Roblox",     category: "Entertainment", glyph: "R", icon: "gamecontroller.fill",           domain: "roblox.com",       tintHex: "#0F0F0F", smspvaCode: "opt49",  cost: 1, successRate: 94, etaSeconds: 34, sortOrder: 690),
        .init(id: "epic-games", name: "Epic Games", category: "Entertainment", glyph: "E", icon: "gamecontroller.fill",           domain: "epicgames.com",    tintHex: "#0F0F0F", smspvaCode: "opt50",  cost: 1, successRate: 93, etaSeconds: 36, sortOrder: 700),
        // Productivity
        .init(id: "notion",     name: "Notion",     category: "Productivity", glyph: "N", icon: "doc.text.fill",                  domain: "notion.so",        tintHex: "#0F0F0F", smspvaCode: "opt151", cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 710),
        .init(id: "slack",      name: "Slack",      category: "Productivity", glyph: "S", icon: "message.fill",                   domain: "slack.com",        tintHex: "#4A154B", smspvaCode: "opt52",  cost: 1, successRate: 96, etaSeconds: 28, sortOrder: 720),
        .init(id: "zoom",       name: "Zoom",       category: "Productivity", glyph: "Z", icon: "video.fill",                     domain: "zoom.us",          tintHex: "#2D8CFF", smspvaCode: "opt53",  cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 730),
        .init(id: "figma",      name: "Figma",      category: "Productivity", glyph: "F", icon: "square.on.square",               domain: "figma.com",        tintHex: "#F24E1E", smspvaCode: "opt61",  cost: 1, successRate: 94, etaSeconds: 32, sortOrder: 740),
        .init(id: "dropbox",    name: "Dropbox",    category: "Productivity", glyph: "D", icon: "folder.fill",                    domain: "dropbox.com",      tintHex: "#0061FF", smspvaCode: "opt62",  cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 750),
        .init(id: "icloud",     name: "iCloud",     category: "Productivity", glyph: "C", icon: "icloud.fill",                    domain: "icloud.com",       tintHex: "#3693F3", smspvaCode: "opt9",   cost: 2, successRate: 93, etaSeconds: 40, sortOrder: 760),
    ]

    static let countries: [Country] = [
        .init(id: "us", name: "United States",  flag: "🇺🇸", dialCode: "+1",  smspvaCode: "US", stock: .high,   avgSeconds: 25, sortOrder: 10),
        .init(id: "uk", name: "United Kingdom", flag: "🇬🇧", dialCode: "+44", smspvaCode: "UK", stock: .high,   avgSeconds: 30, sortOrder: 20),
        .init(id: "de", name: "Germany",        flag: "🇩🇪", dialCode: "+49", smspvaCode: "DE", stock: .high,   avgSeconds: 28, sortOrder: 30),
        .init(id: "nl", name: "Netherlands",    flag: "🇳🇱", dialCode: "+31", smspvaCode: "NL", stock: .high,   avgSeconds: 30, sortOrder: 40),
        .init(id: "fr", name: "France",         flag: "🇫🇷", dialCode: "+33", smspvaCode: "FR", stock: .medium, avgSeconds: 36, sortOrder: 50),
        .init(id: "it", name: "Italy",          flag: "🇮🇹", dialCode: "+39", smspvaCode: "IT", stock: .medium, avgSeconds: 35, sortOrder: 60),
        .init(id: "es", name: "Spain",          flag: "🇪🇸", dialCode: "+34", smspvaCode: "ES", stock: .medium, avgSeconds: 38, sortOrder: 70),
        .init(id: "pl", name: "Poland",         flag: "🇵🇱", dialCode: "+48", smspvaCode: "PL", stock: .medium, avgSeconds: 40, sortOrder: 80),
        .init(id: "in", name: "India",          flag: "🇮🇳", dialCode: "+91", smspvaCode: "IN", stock: .high,   avgSeconds: 41, sortOrder: 90),
        .init(id: "br", name: "Brazil",         flag: "🇧🇷", dialCode: "+55", smspvaCode: "BR", stock: .medium, avgSeconds: 52, sortOrder: 100),
    ]
}

let serviceCategories: [String] = [
    "Popular", "Messaging", "Social", "Tech", "Finance", "Commerce",
    "Delivery", "Transport", "Travel", "Dating", "Entertainment", "Productivity"
]
