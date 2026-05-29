import SwiftUI

/// In-app defaults that mirror the DB seed in the catalog migration.
/// Generic categories — App Store review prefers no brand names.
enum SeedData {
    static let services: [Service] = [
        // Messaging
        .init(id: "messenger-a", name: "Messenger A", category: "Messaging", glyph: "M", icon: "bubble.left.fill",                           tintHex: "#2E6FD9", smspvaCode: "opt29",  cost: 1, successRate: 98, etaSeconds: 22, sortOrder: 10),
        .init(id: "chatline",    name: "Chatline",    category: "Messaging", glyph: "C", icon: "bubble.left.and.bubble.right.fill",          tintHex: "#7A4AE0", smspvaCode: "opt0",   cost: 1, successRate: 96, etaSeconds: 28, sortOrder: 20),
        .init(id: "telechat",    name: "Telechat",    category: "Messaging", glyph: "T", icon: "paperplane.fill",                            tintHex: "#00A2E8", smspvaCode: "opt22",  cost: 1, successRate: 97, etaSeconds: 25, sortOrder: 30),
        // Social
        .init(id: "socialgram",  name: "Socialgram",  category: "Social",    glyph: "S", icon: "photo.fill",                                 tintHex: "#D14B7E", smspvaCode: "opt16",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 40),
        .init(id: "feedly-plus", name: "Feedly+",     category: "Social",    glyph: "F", icon: "text.bubble.fill",                           tintHex: "#E0793A", smspvaCode: "opt2",   cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 50),
        .init(id: "shortpost",   name: "Shortpost",   category: "Social",    glyph: "X", icon: "at",                                         tintHex: "#0F0F0F", smspvaCode: "opt41",  cost: 1, successRate: 92, etaSeconds: 42, sortOrder: 60),
        .init(id: "videocast",   name: "Videocast",   category: "Social",    glyph: "V", icon: "play.tv.fill",                               tintHex: "#4A2A8E", smspvaCode: "opt167", cost: 1, successRate: 91, etaSeconds: 45, sortOrder: 70),
        .init(id: "matchly",     name: "Matchly",     category: "Dating",    glyph: "L", icon: "heart.fill",                                 tintHex: "#D9527B", smspvaCode: "opt28",  cost: 1, successRate: 93, etaSeconds: 48, sortOrder: 80),
        // Finance
        .init(id: "walletly",    name: "Walletly",    category: "Finance",   glyph: "W", icon: "creditcard.fill",                            tintHex: "#1FA463", smspvaCode: "opt77",  cost: 2, successRate: 92, etaSeconds: 55, sortOrder: 90),
        .init(id: "banky",       name: "Banky",       category: "Finance",   glyph: "B", icon: "building.columns.fill",                      tintHex: "#0F4C81", smspvaCode: "opt15",  cost: 2, successRate: 94, etaSeconds: 45, sortOrder: 100),
        .init(id: "cryptobase",  name: "Cryptobase",  category: "Finance",   glyph: "X", icon: "bitcoinsign.circle.fill",                    tintHex: "#3F4452", smspvaCode: "opt55",  cost: 2, successRate: 90, etaSeconds: 62, sortOrder: 110),
        // Commerce
        .init(id: "marketcart",  name: "Marketcart",  category: "Commerce",  glyph: "K", icon: "bag.fill",                                   tintHex: "#A77836", smspvaCode: "opt19",  cost: 1, successRate: 96, etaSeconds: 36, sortOrder: 120),
        .init(id: "auctionly",   name: "Auctionly",   category: "Commerce",  glyph: "A", icon: "hammer.fill",                                tintHex: "#3A6E5E", smspvaCode: "opt23",  cost: 1, successRate: 94, etaSeconds: 44, sortOrder: 130),
        .init(id: "foodbox",     name: "Foodbox",     category: "Delivery",  glyph: "F", icon: "takeoutbag.and.cup.and.straw.fill",          tintHex: "#D33A3A", smspvaCode: "opt37",  cost: 1, successRate: 95, etaSeconds: 39, sortOrder: 140),
        // Transport
        .init(id: "rideshare",   name: "Rideshare X", category: "Transport", glyph: "R", icon: "car.fill",                                   tintHex: "#1B2330", smspvaCode: "opt5",   cost: 1, successRate: 97, etaSeconds: 31, sortOrder: 150),
        .init(id: "cabify",      name: "Cabify",      category: "Transport", glyph: "Y", icon: "car.side.fill",                              tintHex: "#7A4AE0", smspvaCode: "opt7",   cost: 1, successRate: 95, etaSeconds: 33, sortOrder: 160),
        // Travel
        .init(id: "stayhub",     name: "Stayhub",     category: "Travel",    glyph: "S", icon: "bed.double.fill",                            tintHex: "#0F8A8A", smspvaCode: "opt43",  cost: 1, successRate: 94, etaSeconds: 40, sortOrder: 170),
        .init(id: "travelhub",   name: "Travelhub",   category: "Travel",    glyph: "T", icon: "airplane",                                   tintHex: "#176FB8", smspvaCode: "opt71",  cost: 1, successRate: 93, etaSeconds: 42, sortOrder: 180),
        // Productivity / Other
        .init(id: "cloudbox",    name: "Cloudbox",    category: "Productivity", glyph: "C", icon: "icloud.fill",                             tintHex: "#1E88E5", smspvaCode: "opt62",  cost: 1, successRate: 96, etaSeconds: 32, sortOrder: 190),
        .init(id: "mailspace",   name: "Mailspace",   category: "Productivity", glyph: "M", icon: "envelope.fill",                           tintHex: "#3F51B5", smspvaCode: "opt8",   cost: 1, successRate: 97, etaSeconds: 28, sortOrder: 200),
        .init(id: "workboard",   name: "Workboard",   category: "Productivity", glyph: "W", icon: "briefcase.fill",                          tintHex: "#1B2330", smspvaCode: "opt4",   cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 210),
        // Entertainment
        .init(id: "gamebox",     name: "Gamebox",     category: "Entertainment", glyph: "G", icon: "gamecontroller.fill",                    tintHex: "#D33A3A", smspvaCode: "opt9",   cost: 1, successRate: 93, etaSeconds: 36, sortOrder: 220),
        .init(id: "streamcast",  name: "Streamcast",  category: "Entertainment", glyph: "S", icon: "music.note.tv.fill",                     tintHex: "#9B59B6", smspvaCode: "opt36",  cost: 1, successRate: 94, etaSeconds: 34, sortOrder: 230),
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
    "Popular", "Messaging", "Social", "Finance", "Commerce", "Delivery",
    "Transport", "Travel", "Dating", "Productivity", "Entertainment"
]
