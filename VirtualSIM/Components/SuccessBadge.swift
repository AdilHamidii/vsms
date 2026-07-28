import SwiftUI

/// What we can honestly say about a route's delivery record.
///
/// There are exactly TWO states, and that is the point. The previous design had
/// three — measured, seeded estimate, and nothing at all — and the third was
/// the bug: a route we had never sold rendered NO badge, and an absent badge
/// reads as "fine" rather than "unknown". Measured 2026-07-28, **17,471 of
/// 17,804 active routes** were in that silent state, so "no opinion" was the
/// answer the UI gave to almost every "is this any good?".
///
/// A seeded rate collapses into `.notTested` deliberately. It is SMSPVA's own
/// per-country grade — a vendor's marketing number about a route we may never
/// have sold once — and 323 routes carry one. Calling that "tested" is exactly
/// the overclaim this replaces; the muted "~40% estimate" it used to render was
/// still a number, and users read numbers as evidence.
enum DeliveryRecord: Equatable {
    /// Never conclusively measured. Covers "no data at all" and "vendor
    /// estimate" alike — neither is a test we ran.
    case notTested
    /// `codes` delivered out of `attempts` conclusive orders in the window.
    case measured(codes: Int, attempts: Int)
}

/// A small delivery-record badge, shown on EVERY route.
///
/// Colour carries confidence, not just magnitude: `.notTested` is always muted,
/// however tempting it is to render an untested route optimistically. Green /
/// amber / red are reserved for records we actually measured.
struct SuccessBadge: View {
    @Environment(\.theme) private var theme
    let record: DeliveryRecord
    var compact: Bool = false

    private var color: Color {
        switch record {
        case .notTested:
            return theme.text3
        case let .measured(codes, attempts):
            guard attempts > 0 else { return theme.text3 }
            let pct = 100 * codes / attempts
            if pct >= 70 { return theme.live }
            if pct >= 40 { return theme.warn }
            return theme.fail
        }
    }

    private var label: String {
        switch record {
        case .notTested:
            return String(localized: "Not tested")
        case let .measured(codes, attempts):
            // "2 of 7" rather than "29%". A percentage off a 7-order sample
            // wears the confidence of a 700-order one; the raw pair carries its
            // own uncertainty and needs no asterisk.
            //
            // The verb stays in the COMPACT form too. A bare "2 of 7" next to a
            // coloured dot does not say what is being counted — it could read
            // as position in a list, or stock. It pairs with "Not tested" on
            // the same surface, and that phrase names its own subject.
            return compact
                ? String(localized: "Worked \(codes) of \(attempts)")
                : String(localized: "Worked \(codes) of \(attempts) times")
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(RFont.text(11, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}
