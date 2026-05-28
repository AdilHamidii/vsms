import SwiftUI

/// In-app defaults that mirror the DB seed in
/// supabase/migrations/20260528120000_catalog.sql.
///
/// These are used before the live catalog finishes loading. Once
/// CatalogAPI.fetch() returns, AppState replaces these arrays with the
/// authoritative server values.
enum SeedData {
    static let services: [Service] = [
        .init(id: "telegram",  name: "Telegram",     category: "Messaging", glyph: "T", tintHex: "#0088CC", smspvaCode: "opt29",  cost: 1, successRate: 98, etaSeconds: 22, sortOrder: 10),
        .init(id: "whatsapp",  name: "WhatsApp",     category: "Messaging", glyph: "W", tintHex: "#25D366", smspvaCode: "opt0",   cost: 1, successRate: 96, etaSeconds: 28, sortOrder: 20),
        .init(id: "discord",   name: "Discord",      category: "Social",    glyph: "D", tintHex: "#5865F2", smspvaCode: "opt22",  cost: 1, successRate: 97, etaSeconds: 25, sortOrder: 30),
        .init(id: "instagram", name: "Instagram",    category: "Social",    glyph: "I", tintHex: "#E4405F", smspvaCode: "opt16",  cost: 1, successRate: 94, etaSeconds: 35, sortOrder: 40),
        .init(id: "facebook",  name: "Facebook",     category: "Social",    glyph: "F", tintHex: "#1877F2", smspvaCode: "opt2",   cost: 1, successRate: 93, etaSeconds: 38, sortOrder: 50),
        .init(id: "twitter",   name: "Twitter / X",  category: "Social",    glyph: "X", tintHex: "#0F0F0F", smspvaCode: "opt41",  cost: 1, successRate: 92, etaSeconds: 42, sortOrder: 60),
        .init(id: "google",    name: "Google",       category: "Tech",      glyph: "G", tintHex: "#4285F4", smspvaCode: "opt15",  cost: 1, successRate: 99, etaSeconds: 20, sortOrder: 70),
        .init(id: "microsoft", name: "Microsoft",    category: "Tech",      glyph: "M", tintHex: "#0078D4", smspvaCode: "opt55",  cost: 1, successRate: 97, etaSeconds: 26, sortOrder: 80),
        .init(id: "openai",    name: "OpenAI",       category: "AI",        glyph: "O", tintHex: "#10A37F", smspvaCode: "opt177", cost: 2, successRate: 95, etaSeconds: 32, sortOrder: 90),
        .init(id: "tiktok",    name: "TikTok",       category: "Media",     glyph: "T", tintHex: "#0F0F0F", smspvaCode: "opt167", cost: 1, successRate: 91, etaSeconds: 45, sortOrder: 100),
        .init(id: "amazon",    name: "Amazon",       category: "Commerce",  glyph: "A", tintHex: "#FF9900", smspvaCode: "opt19",  cost: 1, successRate: 96, etaSeconds: 30, sortOrder: 110),
        .init(id: "uber",      name: "Uber",         category: "Transport", glyph: "U", tintHex: "#0F0F0F", smspvaCode: "opt77",  cost: 1, successRate: 95, etaSeconds: 33, sortOrder: 120),
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

let serviceCategories: [String] = ["Popular", "Messaging", "Social", "Tech", "AI", "Media", "Commerce", "Transport"]
