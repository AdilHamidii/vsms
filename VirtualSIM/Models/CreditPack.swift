import Foundation

struct CreditPack: Identifiable, Hashable {
    let id: String
    let productId: String
    let credits: Int
    /// Static fallback price in USD, shown only until StoreKit's live localized
    /// price loads. **The single source for both fallback strings below.**
    let priceUsd: Decimal
    /// Optional marketing badge, e.g. "MOST POPULAR" / "BEST VALUE". nil = no badge.
    let badge: String?
    /// An OPTIONAL pack is dropped from the visible ladder when StoreKit has
    /// answered and did not return this product — its App Store review may still
    /// be pending, so its absence is expected rather than a load failure. Every
    /// other pack renders "Unavailable" in that case, because for an approved
    /// product a missing row IS the signal that something broke. The product id
    /// stays in `allProductIds`: the request list is not the visible list, and
    /// the pack must appear the moment Apple starts returning it, with no
    /// release.
    var optional: Bool = false

    /// Static fallback price string.
    var price: String { priceUsd.formatted(.currency(code: "USD")) }

    /// Static fallback per-credit, DERIVED rather than stored.
    ///
    /// ⚠️ It used to be a hand-written string sitting next to the price, i.e. a
    /// second copy of `price ÷ credits` maintained by eye — the exact shape this
    /// codebase documents as guaranteed to drift, and which has already inverted
    /// this very ladder once (the 30-pack beat the 60-pack in the US for weeks
    /// because two hand-set numbers disagreed with what the store billed).
    /// A wrong per-credit label is not cosmetic here: it is the only figure that
    /// makes different pack sizes comparable, so it is what the buyer reasons
    /// with. Deriving it means a stale value cannot render at all.
    ///
    /// USD is correct for a FALLBACK: it is shown only before StoreKit answers,
    /// and these amounts are the US tier. Once the product loads,
    /// `IAPStore.perCredit(_:)` recomputes from the real localized price.
    var perCredit: String {
        guard credits > 0 else { return "" }
        let per = priceUsd / Decimal(credits)
        return "\(per.formatted(.currency(code: "USD"))) / cr"
    }
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
    //
    // 2.1: `credits.8` sits ALONGSIDE `credits.5` at $3.99 rather than replacing
    // it (owner decision 2026-08-10). The 12-pack dropped $5.99 → $5.49 in the
    // same decision so the six-rung ladder stays strictly monotonic per credit.
    // `credits.8` is the one rung marked `optional`: its App Store review is
    // pending, and until Apple returns it StoreKit answers with five products,
    // not six.
    static let all: [CreditPack] = [
        .init(id: "sm", productId: "com.anthersystems.VirtualSIM.credits.5",
              credits: 5,   priceUsd: 2.99,  badge: nil),
        .init(id: "s8", productId: "com.anthersystems.VirtualSIM.credits.8",
              credits: 8,   priceUsd: 3.99,  badge: nil, optional: true),
        .init(id: "md", productId: "com.anthersystems.VirtualSIM.credits.12",
              credits: 12,  priceUsd: 5.49,  badge: "MOST POPULAR"),
        .init(id: "lg", productId: "com.anthersystems.VirtualSIM.credits.30",
              credits: 30,  priceUsd: 12.99, badge: nil),
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
              credits: 60,  priceUsd: 24.99, badge: nil),
        .init(id: "xxl", productId: "com.anthersystems.VirtualSIM.credits.150",
              credits: 150, priceUsd: 59.99, badge: "BEST VALUE"),
    ]

    /// The WHOLE ladder must improve strictly: a bigger pack always beats
    /// stacking smaller ones. This has been violated in production before — US
    /// pricing drift made two 30-packs ($23.98) beat the 60-pack ($24.99),
    /// silently dominating the top revenue product — so it is asserted rather
    /// than trusted. Debug-only: it guards the fallback table, and the live
    /// prices come from App Store Connect where the same rule has to be kept by
    /// hand.
    ///
    /// The 2026-08-10 ladder satisfies it at every step, entry rung included:
    /// 0.598 > 0.49875 > 0.4575 > 0.433 > 0.4165 > 0.39993 per credit.
    static func assertLadderImproves() {
        #if DEBUG
        for (a, b) in zip(all, all.dropFirst()) {
            let perA = a.priceUsd / Decimal(a.credits)
            let perB = b.priceUsd / Decimal(b.credits)
            assert(perB < perA,
                   "credit ladder regression: \(b.id) at \(perB)/cr is not cheaper than \(a.id) at \(perA)/cr")
        }
        #endif
    }

    static let allProductIds: [String] = all.map(\.productId)
}
