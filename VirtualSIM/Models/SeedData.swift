import SwiftUI

/// Compact in-app default catalog — just the 30 most popular services.
/// Used as a brief flash before the live catalog fetch (200+ services)
/// returns from PostgREST.
enum SeedData {
    static let services: [Service] = [
        .init(id: "whatsapp",   name: "WhatsApp",         category: "Messaging", glyph: "W", icon: "bubble.left.fill",                  domain: "whatsapp.com",  tintHex: "#25D366", smspvaCode: "opt20",  cost: 2, successRate: 96, etaSeconds: 28, sortOrder: 100),
        .init(id: "telegram",   name: "Telegram",         category: "Messaging", glyph: "T", icon: "paperplane.fill",                   domain: "telegram.org",  tintHex: "#0088CC", smspvaCode: "opt29",  cost: 2, successRate: 98, etaSeconds: 22, sortOrder: 110),
        .init(id: "signal",     name: "Signal",           category: "Messaging", glyph: "S", icon: "bubble.left.fill",                  domain: "signal.org",    tintHex: "#3A76F0", smspvaCode: "opt127", cost: 1, successRate: 97, etaSeconds: 24, sortOrder: 120),
        .init(id: "discord",    name: "Discord",          category: "Messaging", glyph: "D", icon: "bubble.left.and.bubble.right.fill", domain: "discord.com",   tintHex: "#5865F2", smspvaCode: "opt45",  cost: 1, successRate: 97, etaSeconds: 25, sortOrder: 130),
        .init(id: "viber",      name: "Viber",            category: "Messaging", glyph: "V", icon: "phone.bubble.left.fill",            domain: "viber.com",     tintHex: "#7360F2", smspvaCode: "opt11",  cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 140),
        .init(id: "wechat",     name: "WeChat",           category: "Messaging", glyph: "W", icon: "bubble.left.fill",                  domain: "wechat.com",    tintHex: "#07C160", smspvaCode: "opt67",  cost: 1, successRate: 94, etaSeconds: 32, sortOrder: 150),
        .init(id: "snapchat",   name: "Snapchat",         category: "Messaging", glyph: "S", icon: "camera.fill",                       domain: "snapchat.com",  tintHex: "#FFFC00", smspvaCode: "opt90",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 170),
        .init(id: "facebook",   name: "Facebook",         category: "Social",    glyph: "F", icon: "photo.fill",                        domain: "facebook.com",  tintHex: "#1877F2", smspvaCode: "opt2",   cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 400),
        .init(id: "instagram",  name: "Instagram",        category: "Social",    glyph: "I", icon: "camera.fill",                       domain: "instagram.com", tintHex: "#E4405F", smspvaCode: "opt16",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 410),
        .init(id: "tiktok",     name: "TikTok",           category: "Social",    glyph: "T", icon: "play.tv.fill",                      domain: "tiktok.com",    tintHex: "#0F0F0F", smspvaCode: "opt104", cost: 1, successRate: 91, etaSeconds: 45, sortOrder: 420),
        .init(id: "twitter-x",  name: "Twitter / X",      category: "Social",    glyph: "X", icon: "at",                                domain: "x.com",         tintHex: "#0F0F0F", smspvaCode: "opt41",  cost: 1, successRate: 92, etaSeconds: 42, sortOrder: 430),
        .init(id: "linkedin",   name: "LinkedIn",         category: "Social",    glyph: "L", icon: "briefcase.fill",                    domain: "linkedin.com",  tintHex: "#0A66C2", smspvaCode: "opt8",   cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 440),
        .init(id: "reddit",     name: "Reddit",           category: "Social",    glyph: "R", icon: "text.bubble.fill",                  domain: "reddit.com",    tintHex: "#FF4500", smspvaCode: "opt265", cost: 1, successRate: 93, etaSeconds: 35, sortOrder: 450),
        .init(id: "twitch",     name: "Twitch",           category: "Social",    glyph: "T", icon: "tv.fill",                           domain: "twitch.tv",     tintHex: "#9146FF", smspvaCode: "opt205", cost: 1, successRate: 94, etaSeconds: 32, sortOrder: 470),
        .init(id: "tinder",     name: "Tinder",           category: "Dating",    glyph: "T", icon: "heart.fill",                        domain: "tinder.com",    tintHex: "#FE3C72", smspvaCode: "opt9",   cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 700),
        .init(id: "bumble",     name: "Bumble",           category: "Dating",    glyph: "B", icon: "heart.fill",                        domain: "bumble.com",    tintHex: "#FFC629", smspvaCode: "opt145", cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 710),
        .init(id: "openai",     name: "OpenAI / ChatGPT", category: "AI",        glyph: "O", icon: "sparkles",                          domain: "openai.com",    tintHex: "#10A37F", smspvaCode: "opt132", cost: 2, successRate: 95, etaSeconds: 32, sortOrder: 10),
        .init(id: "claude",     name: "Claude",           category: "AI",        glyph: "C", icon: "sparkles",                          domain: "anthropic.com", tintHex: "#C97559", smspvaCode: "opt196", cost: 2, successRate: 95, etaSeconds: 30, sortOrder: 20),
        .init(id: "google",     name: "Google",           category: "Tech",      glyph: "G", icon: "globe",                             domain: "google.com",    tintHex: "#4285F4", smspvaCode: "opt1",   cost: 1, successRate: 99, etaSeconds: 20, sortOrder: 2000),
        .init(id: "apple-id",   name: "Apple",            category: "Tech",      glyph: "A", icon: "apple.logo",                        domain: "apple.com",     tintHex: "#0F0F0F", smspvaCode: "opt131", cost: 2, successRate: 93, etaSeconds: 40, sortOrder: 2030),
        .init(id: "paypal",     name: "PayPal",           category: "Finance",   glyph: "P", icon: "creditcard.fill",                   domain: "paypal.com",    tintHex: "#003087", smspvaCode: "opt83",  cost: 2, successRate: 92, etaSeconds: 50, sortOrder: 1000),
        .init(id: "revolut",    name: "Revolut",          category: "Finance",   glyph: "R", icon: "creditcard.fill",                   domain: "revolut.com",   tintHex: "#0F0F0F", smspvaCode: "opt133", cost: 2, successRate: 92, etaSeconds: 48, sortOrder: 1030),
        .init(id: "binance",    name: "Binance",          category: "Crypto",    glyph: "B", icon: "bitcoinsign.circle.fill",           domain: "binance.com",   tintHex: "#F0B90B", smspvaCode: "opt190", cost: 2, successRate: 90, etaSeconds: 55, sortOrder: 1500),
        .init(id: "coinbase",   name: "Coinbase",         category: "Crypto",    glyph: "C", icon: "bitcoinsign.circle.fill",           domain: "coinbase.com",  tintHex: "#0052FF", smspvaCode: "opt112", cost: 2, successRate: 92, etaSeconds: 50, sortOrder: 1510),
        .init(id: "amazon",     name: "Amazon",           category: "Commerce",  glyph: "A", icon: "bag.fill",                          domain: "amazon.com",    tintHex: "#FF9900", smspvaCode: "opt44",  cost: 1, successRate: 96, etaSeconds: 30, sortOrder: 3000),
        .init(id: "uber",       name: "Uber",             category: "Transport", glyph: "U", icon: "car.fill",                          domain: "uber.com",      tintHex: "#0F0F0F", smspvaCode: "opt72",  cost: 1, successRate: 97, etaSeconds: 30, sortOrder: 5000),
        .init(id: "lyft",       name: "Lyft",             category: "Transport", glyph: "L", icon: "car.fill",                          domain: "lyft.com",      tintHex: "#FF00BF", smspvaCode: "opt75",  cost: 1, successRate: 96, etaSeconds: 32, sortOrder: 5010),
        .init(id: "airbnb",     name: "Airbnb",           category: "Travel",    glyph: "A", icon: "bed.double.fill",                   domain: "airbnb.com",    tintHex: "#FF5A5F", smspvaCode: "opt46",  cost: 1, successRate: 94, etaSeconds: 36, sortOrder: 5500),
        .init(id: "netflix",    name: "Netflix",          category: "Entertainment", glyph: "N", icon: "play.rectangle.fill",            domain: "netflix.com",   tintHex: "#E50914", smspvaCode: "opt101", cost: 1, successRate: 95, etaSeconds: 32, sortOrder: 7000),
        .init(id: "steam",      name: "Steam",            category: "Entertainment", glyph: "S", icon: "gamecontroller.fill",            domain: "steampowered.com",tintHex: "#1B2838", smspvaCode: "opt58", cost: 1, successRate: 95, etaSeconds: 32, sortOrder: 7010),
    ]

    static let countries: [Country] = [
        // Tier-A premium markets
        .init(id: "us", name: "United States",          flag: "🇺🇸", dialCode: "+1",   smspvaCode: "US", stock: .high,   avgSeconds: 25, sortOrder: 10),
        .init(id: "uk", name: "United Kingdom",         flag: "🇬🇧", dialCode: "+44",  smspvaCode: "UK", stock: .high,   avgSeconds: 30, sortOrder: 20),
        .init(id: "ca", name: "Canada",                 flag: "🇨🇦", dialCode: "+1",   smspvaCode: "CA", stock: .high,   avgSeconds: 28, sortOrder: 30),
        .init(id: "au", name: "Australia",              flag: "🇦🇺", dialCode: "+61",  smspvaCode: "AU", stock: .high,   avgSeconds: 32, sortOrder: 40),
        .init(id: "de", name: "Germany",                flag: "🇩🇪", dialCode: "+49",  smspvaCode: "DE", stock: .high,   avgSeconds: 28, sortOrder: 50),
        .init(id: "fr", name: "France",                 flag: "🇫🇷", dialCode: "+33",  smspvaCode: "FR", stock: .high,   avgSeconds: 30, sortOrder: 60),
        .init(id: "nl", name: "Netherlands",            flag: "🇳🇱", dialCode: "+31",  smspvaCode: "NL", stock: .high,   avgSeconds: 30, sortOrder: 70),
        .init(id: "it", name: "Italy",                  flag: "🇮🇹", dialCode: "+39",  smspvaCode: "IT", stock: .high,   avgSeconds: 34, sortOrder: 80),
        .init(id: "es", name: "Spain",                  flag: "🇪🇸", dialCode: "+34",  smspvaCode: "ES", stock: .high,   avgSeconds: 35, sortOrder: 90),
        .init(id: "pl", name: "Poland",                 flag: "🇵🇱", dialCode: "+48",  smspvaCode: "PL", stock: .high,   avgSeconds: 30, sortOrder: 100),
        // Nordics + DACH + Benelux + IE
        .init(id: "se", name: "Sweden",                 flag: "🇸🇪", dialCode: "+46",  smspvaCode: "SE", stock: .high,   avgSeconds: 32, sortOrder: 110),
        .init(id: "dk", name: "Denmark",                flag: "🇩🇰", dialCode: "+45",  smspvaCode: "DK", stock: .medium, avgSeconds: 32, sortOrder: 120),
        .init(id: "fi", name: "Finland",                flag: "🇫🇮", dialCode: "+358", smspvaCode: "FI", stock: .medium, avgSeconds: 36, sortOrder: 130),
        .init(id: "be", name: "Belgium",                flag: "🇧🇪", dialCode: "+32",  smspvaCode: "BE", stock: .medium, avgSeconds: 34, sortOrder: 140),
        .init(id: "at", name: "Austria",                flag: "🇦🇹", dialCode: "+43",  smspvaCode: "AT", stock: .medium, avgSeconds: 33, sortOrder: 150),
        .init(id: "ch", name: "Switzerland",            flag: "🇨🇭", dialCode: "+41",  smspvaCode: "CH", stock: .medium, avgSeconds: 35, sortOrder: 160),
        .init(id: "ie", name: "Ireland",                flag: "🇮🇪", dialCode: "+353", smspvaCode: "IE", stock: .medium, avgSeconds: 33, sortOrder: 170),
        // Southern + Eastern EU
        .init(id: "pt", name: "Portugal",               flag: "🇵🇹", dialCode: "+351", smspvaCode: "PT", stock: .medium, avgSeconds: 38, sortOrder: 180),
        .init(id: "ro", name: "Romania",                flag: "🇷🇴", dialCode: "+40",  smspvaCode: "RO", stock: .medium, avgSeconds: 40, sortOrder: 190),
        .init(id: "cz", name: "Czech Republic",         flag: "🇨🇿", dialCode: "+420", smspvaCode: "CZ", stock: .medium, avgSeconds: 36, sortOrder: 200),
        .init(id: "sk", name: "Slovakia",               flag: "🇸🇰", dialCode: "+421", smspvaCode: "SK", stock: .medium, avgSeconds: 38, sortOrder: 210),
        .init(id: "si", name: "Slovenia",               flag: "🇸🇮", dialCode: "+386", smspvaCode: "SI", stock: .medium, avgSeconds: 38, sortOrder: 220),
        .init(id: "hu", name: "Hungary",                flag: "🇭🇺", dialCode: "+36",  smspvaCode: "HU", stock: .medium, avgSeconds: 36, sortOrder: 230),
        .init(id: "hr", name: "Croatia",                flag: "🇭🇷", dialCode: "+385", smspvaCode: "HR", stock: .medium, avgSeconds: 38, sortOrder: 240),
        .init(id: "bg", name: "Bulgaria",               flag: "🇧🇬", dialCode: "+359", smspvaCode: "BG", stock: .medium, avgSeconds: 40, sortOrder: 250),
        .init(id: "rs", name: "Serbia",                 flag: "🇷🇸", dialCode: "+381", smspvaCode: "RS", stock: .medium, avgSeconds: 42, sortOrder: 260),
        .init(id: "al", name: "Albania",                flag: "🇦🇱", dialCode: "+355", smspvaCode: "AL", stock: .medium, avgSeconds: 44, sortOrder: 270),
        .init(id: "ba", name: "Bosnia and Herzegovina", flag: "🇧🇦", dialCode: "+387", smspvaCode: "BA", stock: .medium, avgSeconds: 44, sortOrder: 280),
        .init(id: "mk", name: "North Macedonia",        flag: "🇲🇰", dialCode: "+389", smspvaCode: "MK", stock: .medium, avgSeconds: 44, sortOrder: 290),
        .init(id: "mt", name: "Malta",                  flag: "🇲🇹", dialCode: "+356", smspvaCode: "MT", stock: .medium, avgSeconds: 40, sortOrder: 300),
        .init(id: "cy", name: "Cyprus",                 flag: "🇨🇾", dialCode: "+357", smspvaCode: "CY", stock: .medium, avgSeconds: 40, sortOrder: 310),
        .init(id: "gr", name: "Greece",                 flag: "🇬🇷", dialCode: "+30",  smspvaCode: "GR", stock: .medium, avgSeconds: 38, sortOrder: 320),
        .init(id: "gi", name: "Gibraltar",              flag: "🇬🇮", dialCode: "+350", smspvaCode: "GI", stock: .low,    avgSeconds: 46, sortOrder: 330),
        // Baltics
        .init(id: "ee", name: "Estonia",                flag: "🇪🇪", dialCode: "+372", smspvaCode: "EE", stock: .medium, avgSeconds: 35, sortOrder: 340),
        .init(id: "lv", name: "Latvia",                 flag: "🇱🇻", dialCode: "+371", smspvaCode: "LV", stock: .medium, avgSeconds: 36, sortOrder: 350),
        .init(id: "lt", name: "Lithuania",              flag: "🇱🇹", dialCode: "+370", smspvaCode: "LT", stock: .medium, avgSeconds: 36, sortOrder: 360),
        // Caucasus + Central Asia
        .init(id: "ge", name: "Georgia",                flag: "🇬🇪", dialCode: "+995", smspvaCode: "GE", stock: .medium, avgSeconds: 44, sortOrder: 370),
        .init(id: "kz", name: "Kazakhstan",             flag: "🇰🇿", dialCode: "+7",   smspvaCode: "KZ", stock: .high,   avgSeconds: 40, sortOrder: 380),
        .init(id: "kg", name: "Kyrgyzstan",             flag: "🇰🇬", dialCode: "+996", smspvaCode: "KG", stock: .medium, avgSeconds: 46, sortOrder: 390),
        .init(id: "md", name: "Moldova",                flag: "🇲🇩", dialCode: "+373", smspvaCode: "MD", stock: .medium, avgSeconds: 44, sortOrder: 400),
        .init(id: "ua", name: "Ukraine",                flag: "🇺🇦", dialCode: "+380", smspvaCode: "UA", stock: .high,   avgSeconds: 38, sortOrder: 410),
        // Latin America
        .init(id: "mx", name: "Mexico",                 flag: "🇲🇽", dialCode: "+52",  smspvaCode: "MX", stock: .high,   avgSeconds: 38, sortOrder: 420),
        .init(id: "br", name: "Brazil",                 flag: "🇧🇷", dialCode: "+55",  smspvaCode: "BR", stock: .high,   avgSeconds: 42, sortOrder: 430),
        .init(id: "ar", name: "Argentina",              flag: "🇦🇷", dialCode: "+54",  smspvaCode: "AR", stock: .medium, avgSeconds: 44, sortOrder: 440),
        .init(id: "co", name: "Colombia",               flag: "🇨🇴", dialCode: "+57",  smspvaCode: "CO", stock: .medium, avgSeconds: 45, sortOrder: 450),
        .init(id: "cl", name: "Chile",                  flag: "🇨🇱", dialCode: "+56",  smspvaCode: "CL", stock: .medium, avgSeconds: 46, sortOrder: 460),
        .init(id: "bo", name: "Bolivia",                flag: "🇧🇴", dialCode: "+591", smspvaCode: "BO", stock: .medium, avgSeconds: 48, sortOrder: 470),
        .init(id: "py", name: "Paraguay",               flag: "🇵🇾", dialCode: "+595", smspvaCode: "PY", stock: .medium, avgSeconds: 48, sortOrder: 480),
        .init(id: "cr", name: "Costa Rica",             flag: "🇨🇷", dialCode: "+506", smspvaCode: "CR", stock: .medium, avgSeconds: 46, sortOrder: 490),
        .init(id: "do", name: "Dominican Republic",     flag: "🇩🇴", dialCode: "+1",   smspvaCode: "DO", stock: .medium, avgSeconds: 48, sortOrder: 500),
        // MENA + Middle East
        .init(id: "tr", name: "Turkey",                 flag: "🇹🇷", dialCode: "+90",  smspvaCode: "TR", stock: .high,   avgSeconds: 40, sortOrder: 510),
        .init(id: "il", name: "Israel",                 flag: "🇮🇱", dialCode: "+972", smspvaCode: "IL", stock: .medium, avgSeconds: 36, sortOrder: 520),
        .init(id: "ma", name: "Morocco",                flag: "🇲🇦", dialCode: "+212", smspvaCode: "MA", stock: .medium, avgSeconds: 48, sortOrder: 530),
        // Africa
        .init(id: "za", name: "South Africa",           flag: "🇿🇦", dialCode: "+27",  smspvaCode: "ZA", stock: .medium, avgSeconds: 48, sortOrder: 540),
        .init(id: "ke", name: "Kenya",                  flag: "🇰🇪", dialCode: "+254", smspvaCode: "KE", stock: .medium, avgSeconds: 52, sortOrder: 550),
        .init(id: "tz", name: "Tanzania",               flag: "🇹🇿", dialCode: "+255", smspvaCode: "TZ", stock: .low,    avgSeconds: 56, sortOrder: 560),
        .init(id: "cm", name: "Cameroon",               flag: "🇨🇲", dialCode: "+237", smspvaCode: "CM", stock: .low,    avgSeconds: 58, sortOrder: 570),
        // Asia
        .init(id: "jp", name: "Japan",                  flag: "🇯🇵", dialCode: "+81",  smspvaCode: "JP", stock: .low,    avgSeconds: 50, sortOrder: 580),
        .init(id: "hk", name: "Hong Kong",              flag: "🇭🇰", dialCode: "+852", smspvaCode: "HK", stock: .medium, avgSeconds: 40, sortOrder: 590),
        .init(id: "sg", name: "Singapore",              flag: "🇸🇬", dialCode: "+65",  smspvaCode: "SG", stock: .medium, avgSeconds: 36, sortOrder: 600),
        .init(id: "my", name: "Malaysia",               flag: "🇲🇾", dialCode: "+60",  smspvaCode: "MY", stock: .medium, avgSeconds: 42, sortOrder: 610),
        .init(id: "th", name: "Thailand",               flag: "🇹🇭", dialCode: "+66",  smspvaCode: "TH", stock: .medium, avgSeconds: 44, sortOrder: 620),
        .init(id: "vn", name: "Vietnam",                flag: "🇻🇳", dialCode: "+84",  smspvaCode: "VN", stock: .medium, avgSeconds: 46, sortOrder: 630),
        .init(id: "ph", name: "Philippines",            flag: "🇵🇭", dialCode: "+63",  smspvaCode: "PH", stock: .high,   avgSeconds: 45, sortOrder: 640),
        .init(id: "id", name: "Indonesia",              flag: "🇮🇩", dialCode: "+62",  smspvaCode: "ID", stock: .high,   avgSeconds: 42, sortOrder: 650),
        .init(id: "kh", name: "Cambodia",               flag: "🇰🇭", dialCode: "+855", smspvaCode: "KH", stock: .low,    avgSeconds: 54, sortOrder: 660),
        .init(id: "bd", name: "Bangladesh",             flag: "🇧🇩", dialCode: "+880", smspvaCode: "BD", stock: .medium, avgSeconds: 50, sortOrder: 670),
        .init(id: "pk", name: "Pakistan",               flag: "🇵🇰", dialCode: "+92",  smspvaCode: "PK", stock: .medium, avgSeconds: 48, sortOrder: 680),
        .init(id: "nz", name: "New Zealand",            flag: "🇳🇿", dialCode: "+64",  smspvaCode: "NZ", stock: .medium, avgSeconds: 38, sortOrder: 690),
    ]
}

let serviceCategories: [String] = [
    "All", "AI", "Messaging", "Social", "Dating", "Tech", "Finance", "Crypto",
    "Commerce", "Delivery", "Transport", "Travel", "Entertainment", "Productivity",
    "Gambling", "Surveys", "Specialty"
]
