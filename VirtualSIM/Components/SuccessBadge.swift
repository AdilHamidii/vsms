import SwiftUI

/// A small delivery-success badge. Shown wherever a per-route success rate is
/// available. Only a MEASURED rate may read as fact ("delivered"); seeded
/// estimates carry a tilde + "est." so a provider prior is never presented as
/// our own delivery record.
///
/// Colour carries confidence, not just magnitude. A seeded rate is SMSPVA's
/// own per-country grade (grade 3 → 90) — a vendor's marketing number about a
/// route we may have never sold once. Rendering that in the same confident
/// green as a measured 90% made "~90%" on a route that had delivered 0 of 2
/// look like earned data; the tilde was the only tell and nobody reads a
/// tilde. Estimates are therefore always muted, whatever the number says.
/// Green/amber are reserved for rates we actually measured.
struct SuccessBadge: View {
    @Environment(\.theme) private var theme
    let rate: Int
    var measured: Bool = false   // conservative default: estimate
    var sample: Int? = nil       // conclusive orders behind a measured rate
    var compact: Bool = false

    /// Below this, state the sample instead of a bare percentage. A route that
    /// has gone 0-of-2 is genuinely measured, but "0% delivered" implies a
    /// settled fact; "0% of 2 tries" is the same truth without the swagger.
    private static let thinSample = 5

    private var color: Color {
        guard measured else { return theme.text3 }
        if rate >= 70 { return theme.live } else if rate >= 40 { return theme.warn } else { return theme.fail }
    }

    private var label: String {
        guard measured else {
            return compact ? "~\(rate)% est." : String(localized: "~\(rate)% estimate")
        }
        if let sample, sample < Self.thinSample {
            return compact ? "\(rate)% · \(sample)" : String(localized: "\(rate)% of \(sample) tries")
        }
        return compact ? "\(rate)%" : String(localized: "\(rate)% delivered")
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
