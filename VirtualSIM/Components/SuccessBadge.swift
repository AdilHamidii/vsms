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

    /// The colour band for this record, or nil when there is nothing measured
    /// to colour. See `DeliveryBand` — never invent a band for `.notTested`.
    var band: DeliveryBand? { ratio.map(DeliveryBand.of(ratio:)) }
}

/// **The app's ONE definition of what a delivery figure's colour means.**
///
/// There were FOUR, all disagreeing, all written at their call site:
/// `SuccessBadge` (>=70 / >=40), an inline copy of the same arithmetic in
/// `HomeScreen`'s view body, `CountrySheet.poolRateColor` (>60 / >=30) and
/// `DeliveryNotice.evidenceColor` (>=0.50 / >=0.20). So the same route could be
/// amber on Home and green on Checkout, which quietly destroys the one thing
/// colour is carrying here: confidence.
///
/// The thresholds settled on are **>=50% / >=20%**, which are not a new opinion
/// — they are exactly `Service.DeliveryOdds`' good / mixed / poor cuts. That is
/// the app's only product-level statement of what a delivery rate MEANS, it is
/// what already drives the plain-English odds phrases ("hit or miss"), and
/// aligning the colour to it means the phrase and the swatch can never
/// contradict each other on the same screen.
///
/// ⚠️ One caller is deliberately NOT migrated: `CountrySheet.poolRateColor`
/// bands the PROVIDER's published pool rate, which is a third party's aggregate
/// across all its customers rather than our own measurement, and the owner set
/// those bands (>60 / >=30) by hand. Migrating it is a one-line change and a
/// separate decision, not an oversight.
enum DeliveryBand {
    /// Delivers more often than not.
    case strong
    /// Real, but a coin flip at best.
    case mixed
    /// Measured, and it mostly fails.
    case weak

    static func of(ratio: Double) -> DeliveryBand {
        if ratio >= 0.50 { return .strong }
        if ratio >= 0.20 { return .mixed }
        return .weak
    }

    /// nil when there is no sample. `0 of 0` is not a weak route, it is an
    /// unknown one, and collapsing the two is the mistake this whole file is
    /// about.
    static func of(codes: Int, attempts: Int) -> DeliveryBand? {
        guard attempts > 0 else { return nil }
        return of(ratio: Double(codes) / Double(attempts))
    }

    static func of(percent: Int) -> DeliveryBand {
        of(ratio: Double(percent) / 100)
    }
}

extension Theme {
    /// Foreground colour for a measured delivery band.
    func deliveryColor(_ band: DeliveryBand) -> Color {
        switch band {
        case .strong: live
        case .mixed:  warn
        case .weak:   fail
        }
    }

    /// The matching wash, for a capsule behind the figure.
    func deliverySoft(_ band: DeliveryBand) -> Color {
        switch band {
        case .strong: liveSoft
        case .mixed:  warnSoft
        case .weak:   failSoft
        }
    }
}

/// A small delivery-record badge, shown on EVERY route.
///
/// Colour carries confidence, not just magnitude: `.notTested` is always muted,
/// however tempting it is to render an untested route optimistically. Green /
/// amber / red are reserved for records we actually measured.
///
/// ── Two fixes from the 2026-08 audit ─────────────────────────────────────
///
/// **It was 11pt with a 5pt dot** — the app's metadata size, on the one element
/// answering "will this actually work?". It is the reason to buy or not buy,
/// and it was rendered smaller than the dial code beside it. Now 12pt semibold
/// on a soft-tinted capsule, so it reads as a verdict rather than as a caption.
///
/// **`.notTested` used `theme.text3` — the exact colour "Unavailable" uses**,
/// so "we have no data on this" and "you cannot buy this" were visually
/// identical. It now takes `text2` and an OUTLINE dot: a hollow ring reads as
/// "nothing recorded here" where a filled one always reads as a measurement.
struct SuccessBadge: View {
    @Environment(\.theme) private var theme
    let record: DeliveryRecord
    var compact: Bool = false

    private var color: Color {
        guard let band = record.band else { return theme.text2 }
        return theme.deliveryColor(band)
    }

    private var wash: Color {
        guard let band = record.band else { return theme.chipBg }
        return theme.deliverySoft(band)
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
            // Both forms now name their NOUN. "Worked 2 of 7" has no subject —
            // two of seven what? Orders, and saying so is free. The screen that
            // renders this is responsible for stating the 30-day window once;
            // repeating it on every row would bury the figure it qualifies.
            return compact
                ? String(localized: "\(codes) of \(attempts) orders")
                : String(localized: "Delivered on \(codes) of \(attempts) orders")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            // Filled = measured. Hollow = nothing recorded. The shape is the
            // signal, so it survives greyscale and colour-blindness where a
            // muted-vs-green fill would not.
            Group {
                if record.band == nil {
                    Circle().strokeBorder(color, lineWidth: 1.2)
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: 6, height: 6)

            // Already resolved by `String(localized:)` above — passing it back
            // through a LocalizedStringKey would just miss the lookup twice.
            Text(label)
                .font(RFont.text(12, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(wash, in: .capsule)
    }
}
