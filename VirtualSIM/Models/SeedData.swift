import SwiftUI

enum SeedData {
    static let services: [Service] = [
        .init(id: "mes",  name: "Messenger A", category: "Messaging", glyph: "M", tint: Color(hex: 0x2E6FD9), cost: 1, successRate: 99, etaSeconds: 24),
        .init(id: "chat", name: "Chatline",    category: "Messaging", glyph: "C", tint: Color(hex: 0x7A4AE0), cost: 1, successRate: 98, etaSeconds: 28),
        .init(id: "soc",  name: "Socialgram",  category: "Social",    glyph: "S", tint: Color(hex: 0xD14B7E), cost: 1, successRate: 96, etaSeconds: 35),
        .init(id: "feed", name: "Feedly+",     category: "Social",    glyph: "F", tint: Color(hex: 0xE0793A), cost: 1, successRate: 94, etaSeconds: 42),
        .init(id: "rd",   name: "Rideshare X", category: "Transport", glyph: "R", tint: Color(hex: 0x1B2330), cost: 1, successRate: 97, etaSeconds: 31),
        .init(id: "eat",  name: "Foodbox",     category: "Delivery",  glyph: "B", tint: Color(hex: 0xD33A3A), cost: 1, successRate: 95, etaSeconds: 39),
        .init(id: "wal",  name: "Walletly",    category: "Finance",   glyph: "W", tint: Color(hex: 0x1FA463), cost: 2, successRate: 92, etaSeconds: 55),
        .init(id: "mkt",  name: "Marketcart",  category: "Commerce",  glyph: "K", tint: Color(hex: 0xA77836), cost: 1, successRate: 96, etaSeconds: 36),
        .init(id: "auc",  name: "Auctionly",   category: "Commerce",  glyph: "A", tint: Color(hex: 0x3A6E5E), cost: 1, successRate: 94, etaSeconds: 44),
        .init(id: "crp",  name: "Cryptobase",  category: "Finance",   glyph: "X", tint: Color(hex: 0x3F4452), cost: 2, successRate: 90, etaSeconds: 62),
        .init(id: "vid",  name: "Streamcast",  category: "Media",     glyph: "V", tint: Color(hex: 0x4A2A8E), cost: 1, successRate: 95, etaSeconds: 33),
        .init(id: "date", name: "Matchly",     category: "Dating",    glyph: "L", tint: Color(hex: 0xD9527B), cost: 1, successRate: 93, etaSeconds: 48),
    ]

    static let countries: [Country] = [
        .init(id: "us", name: "United States",  flag: "🇺🇸", code: "+1",   stock: .high,   avgSeconds: 24),
        .init(id: "uk", name: "United Kingdom", flag: "🇬🇧", code: "+44",  stock: .high,   avgSeconds: 30),
        .init(id: "de", name: "Germany",        flag: "🇩🇪", code: "+49",  stock: .high,   avgSeconds: 28),
        .init(id: "fr", name: "France",         flag: "🇫🇷", code: "+33",  stock: .medium, avgSeconds: 36),
        .init(id: "in", name: "India",          flag: "🇮🇳", code: "+91",  stock: .high,   avgSeconds: 41),
        .init(id: "br", name: "Brazil",         flag: "🇧🇷", code: "+55",  stock: .medium, avgSeconds: 52),
        .init(id: "ph", name: "Philippines",    flag: "🇵🇭", code: "+63",  stock: .low,    avgSeconds: 65),
        .init(id: "ng", name: "Nigeria",        flag: "🇳🇬", code: "+234", stock: .medium, avgSeconds: 48),
    ]
}

let serviceCategories: [String] = ["Popular", "Messaging", "Social", "Finance", "Commerce", "Media", "Dating"]
