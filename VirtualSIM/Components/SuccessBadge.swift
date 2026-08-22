import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// OWNER DECISION, 2026-08-22: the app's OWN delivery record is no longer
// rendered anywhere in the temp-SMS product.
//
// "Ours: 0 of 4", "Worked 3 of 7 times", "Not tested", "0% of 2 tries" and the
// plain-English odds phrases ("Rarely works for …", "Hit or miss") are gone
// from every surface — Home, Checkout, the service and country pickers, the
// waiting screen and the recovery screen. `SuccessBadge`, `OurRecordChip`,
// `DeliveryBand` and the `Theme.delivery*` tints were deleted with them.
//
// What STAYS:
// - **The vendor's network-wide rate** (`NetworkRateMeter`), which is a third
//   party's aggregate and answers a different question.
// - **The record DATA and every steering rule built on it** — `DeliveryRecord`,
//   `AppState.deliveryRecord`, `routeKey`, `bestCountry`, `retryKey`,
//   `Service.deliversPoorly`, `Country.deliversPoorly` and the picker sort
//   keys. This was a display change only; nothing about which route the app
//   chooses for a user moved.
// ─────────────────────────────────────────────────────────────────────────────

/// What we can honestly say about a route's delivery record.
///
/// No longer rendered (see the note above) — it is the ranking input the
/// pickers, the starter picker and the post-failure retry all sort on. There
/// are exactly TWO states, and that is still the point: a route we have never
/// sold must not score the same as one we have proven bad.
enum DeliveryRecord: Equatable {
    /// Never conclusively measured. Covers "no data at all" and "vendor
    /// estimate" alike — neither is a test we ran.
    case notTested
    /// `codes` delivered out of `attempts` conclusive orders in the window.
    case measured(codes: Int, attempts: Int)
}

extension DeliveryRecord {
    /// Delivered fraction, or nil when we have never measured this route.
    ///
    /// `nil` and `0` are deliberately different answers: "we don't know" must
    /// never sort or read the same as "we know it fails". Ranking code that
    /// collapses them with `?? 0` buries untested inventory below inventory we
    /// have proven bad, which is how a catalog stops discovering anything.
    var ratio: Double? {
        guard case let .measured(codes, attempts) = self, attempts > 0 else { return nil }
        return Double(codes) / Double(attempts)
    }

    /// Measured, and it has never delivered.
    var isMeasuredZero: Bool { ratio == 0 }
}

/// The network's published rate, drawn as a **bar**.
///
/// The shape is the point. A bar reads as a proportion of a population — an
/// aggregate somebody else measured. The word `network` rides along with it so
/// the row is self-describing and the screen needs no legend above the list.
///
/// ⚠️ **It lives here and not inside a picker.** It was `private` to
/// `CountrySheet` while three other surfaces — Home, Checkout and
/// `ServiceSheet` — rendered nothing for routes the country picker was already
/// showing a real figure for. A rendering rule that exists in one file is a
/// rule the rest of the app does not have.
struct NetworkRateMeter: View {
    @Environment(\.theme) private var theme
    let pct: Int

    private static let barWidth: CGFloat = 38

    private var clamped: Int { min(100, max(0, pct)) }

    /// 🔴 **The network figure keeps its OWN thresholds — >60 green, 30–60
    /// amber, <30 red.** They are an explicit owner decision (2026-08-03), and
    /// they were never on the same scale as our own orders: measured over every
    /// non-cancelled order, a published 80+ realised ~40% and 60–79 realised
    /// ~25%, so the published figure runs roughly double what we saw.
    private var color: Color {
        if clamped > 60 { return theme.live }
        if clamped >= 30 { return theme.warn }
        return theme.fail
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.track)
                    .frame(width: Self.barWidth, height: 4)
                Capsule()
                    .fill(color)
                    // A floor of 3pt so a 1% route still draws something: a bar
                    // of literally zero width is indistinguishable from an
                    // unrated route, which renders no bar at all.
                    .frame(width: max(3, Self.barWidth * CGFloat(clamped) / 100), height: 4)
            }

            Text("\(clamped)%")
                .font(RFont.text(12, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()

            Text("network")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network-wide delivery rate \(clamped) percent"))
    }
}

/// The delivery slot on the single-route surfaces — the Home hero, Checkout,
/// and the service picker.
///
/// It renders the vendor's network rate when there is one and **nothing at all
/// otherwise**. Since 2026-08-22 that is the whole of it: it used to fall back
/// to our own record, which is no longer shown anywhere (see the file header).
/// `CountrySheet` deliberately does not use it — that row places the meter
/// under the dial code itself.
struct DeliverySignal: View {
    /// The vendor's published rate for this route's pool. nil = they publish
    /// none — never 0, which is a measurement and means something else.
    let poolRate: Int?
    /// Match the slot this sits in — Checkout's receipt column is trailing.
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        if let poolRate {
            VStack(alignment: alignment, spacing: 4) {
                NetworkRateMeter(pct: poolRate)
            }
        }
    }
}
