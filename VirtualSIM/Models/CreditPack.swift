import Foundation

struct CreditPack: Identifiable, Hashable {
    let id: String
    let productId: String
    let credits: Int
    /// Static fallback price, shown only until StoreKit's live localized price loads.
    let price: String
    /// Static fallback per-credit, shown only until the live price loads. The sheet
    /// prefers `IAPStore.perCredit(_:)`, which derives it from the real StoreKit price
    /// so the label can never drift out of sync with the amount actually charged.
    let perCredit: String
    /// Optional marketing badge, e.g. "MOST POPULAR" / "BEST VALUE". nil = no badge.
    let badge: String?
}

extension CreditPack {
    // Prices form a strictly improving per-credit ladder so a larger pack always
    // beats buying a smaller one repeatedly (e.g. 60 for $22.99 vs 2×30 = $25.98;
    // 150 for $49.99 vs 5×30 = $64.95). "BEST VALUE" sits on the genuinely lowest
    // per-credit pack. NOTE: production prices are set per-product in App Store
    // Connect — keep those tiers in sync with these fallbacks.
    static let all: [CreditPack] = [
        .init(id: "sm", productId: "com.anthersystems.VirtualSIM.credits.5",
              credits: 5,   price: "$2.99",  perCredit: "$0.60 / cr", badge: nil),
        .init(id: "md", productId: "com.anthersystems.VirtualSIM.credits.12",
              credits: 12,  price: "$5.99",  perCredit: "$0.50 / cr", badge: "MOST POPULAR"),
        .init(id: "lg", productId: "com.anthersystems.VirtualSIM.credits.30",
              credits: 30,  price: "$12.99", perCredit: "$0.43 / cr", badge: nil),
        // Larger packs for eSIM data plans (which run pricier than OTP numbers).
        .init(id: "xl", productId: "com.anthersystems.VirtualSIM.credits.60",
              credits: 60,  price: "$22.99", perCredit: "$0.38 / cr", badge: nil),
        .init(id: "xxl", productId: "com.anthersystems.VirtualSIM.credits.150",
              credits: 150, price: "$49.99", perCredit: "$0.33 / cr", badge: "BEST VALUE"),
    ]

    static let allProductIds: [String] = all.map(\.productId)
}
