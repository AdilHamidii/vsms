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
    // beats buying a smaller one repeatedly (60 for $24.99 vs 2×30 = $25.98;
    // 150 for $59.99 vs 5×30 = $64.95). "BEST VALUE" sits on the genuinely lowest
    // per-credit pack. NOTE: production prices are set per-product in App Store
    // Connect — keep those tiers in sync with these fallbacks.
    //
    // As of 2026-07-31 these fallbacks match the LIVE US prices exactly. They did
    // not before: the US billed $4.99 / $11.99 for the 12- and 30-packs because
    // those products were anchored to FRA and their dollar price was *derived*
    // from the euro one, while 60/150 were anchored to USA. That drift inverted
    // the ladder — 30 cr worked out at $0.3997/credit against the 60-pack's
    // $0.4165, so two 30-packs bought 60 credits for $23.98 and strictly beat the
    // $24.99 60-pack, our top revenue product. USD is now realigned to the EUR
    // figures and the ladder improves monotonically again.
    static let all: [CreditPack] = [
        .init(id: "sm", productId: "com.anthersystems.VirtualSIM.credits.5",
              credits: 5,   price: "$2.99",  perCredit: "$0.60 / cr", badge: nil),
        .init(id: "md", productId: "com.anthersystems.VirtualSIM.credits.12",
              credits: 12,  price: "$5.99",  perCredit: "$0.50 / cr", badge: "MOST POPULAR"),
        .init(id: "lg", productId: "com.anthersystems.VirtualSIM.credits.30",
              credits: 30,  price: "$12.99", perCredit: "$0.43 / cr", badge: nil),
        // Larger packs for eSIM data plans (which run pricier than OTP numbers).
        //
        // These strings are FALLBACKS shown only until StoreKit returns the real
        // product. Keep them in sync with App Store Connect, not with intent —
        // they once read $22.99/$49.99, which was never what the store would
        // have billed.
        //
        // ⚠️ This comment used to assert that neither of these two was APPROVED
        // and that "StoreKit never returns them, so the fallback is all a user
        // ever sees". **That is FALSE and was already false when written**:
        // both read `APPROVED` on
        // `/v1/apps/6774768570/inAppPurchasesV2` (re-verified 2026-08-06), and
        // credits.60 has been the top revenue product. The stale note is
        // recorded rather than deleted because it nearly caused both packs to
        // be filtered out of the paywall as unbuyable — including the one
        // carrying BEST VALUE. **Read ASC before acting on any claim about
        // product state.**
        .init(id: "xl", productId: "com.anthersystems.VirtualSIM.credits.60",
              credits: 60,  price: "$24.99", perCredit: "$0.42 / cr", badge: nil),
        .init(id: "xxl", productId: "com.anthersystems.VirtualSIM.credits.150",
              credits: 150, price: "$59.99", perCredit: "$0.40 / cr", badge: "BEST VALUE"),
    ]

    static let allProductIds: [String] = all.map(\.productId)
}
