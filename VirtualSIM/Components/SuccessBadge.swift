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

/// The network's published rate, drawn as a **bar**.
///
/// The shape is the point. A bar reads as a proportion of a population —
/// an aggregate somebody else measured — where a bare tinted percentage sitting
/// beside our own tinted percentage read as two of the same kind of thing. The
/// word `network` rides along with it so the row is self-describing and the
/// screen needs no legend above the list.
///
/// ⚠️ **It lives here, beside `SuccessBadge`, and not in a picker.** It was
/// `private` to `CountrySheet` while three other surfaces — Home, Checkout and
/// `ServiceSheet` — kept rendering a bare "Not tested" for routes the country
/// picker was already showing a real figure for. Leboncoin · Austria read
/// **86% network** in one sheet and **Not tested** on the Home hero for the
/// same route, in the same session. A rendering rule that exists in one file
/// is a rule the rest of the app does not have.
struct NetworkRateMeter: View {
    @Environment(\.theme) private var theme
    let pct: Int

    private static let barWidth: CGFloat = 38

    private var clamped: Int { min(100, max(0, pct)) }

    /// 🔴 **The network figure keeps its OWN thresholds — >60 green, 30–60
    /// amber, <30 red — and must not be folded into `DeliveryBand`.**
    ///
    /// Two reasons, and the second is the substantive one:
    ///
    /// 1. They are an explicit owner decision (2026-08-03).
    /// 2. **The two numbers are not on the same scale.** This is a third
    ///    party's network-wide rate across all its customers; `OurRecordChip`
    ///    is what happened when *we* ordered. Measured over every non-cancelled
    ///    order, a published 80+ realised ~40% and 60–79 realised ~25% — the
    ///    published figure runs roughly double. Colouring both with one
    ///    threshold set would call a 55% network rate "good" on the same scale
    ///    that calls a 55% record of ours "good", when the first predicts
    ///    something closer to 25%.
    ///
    /// Sharing a tint FUNCTION across two different measurements is exactly the
    /// conflation the two shapes exist to prevent.
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

/// What happened when **we** ordered here, drawn as a bordered chip.
///
/// An outline rather than the filled capsule `SuccessBadge` uses, so the two
/// numbers differ in shape before they differ in colour — and the word "Ours"
/// so it is not merely *positionally* distinct from the network figure. The raw
/// pair, never a percentage: "3 of 7" carries its own uncertainty where "43%"
/// wears the confidence of a 700-order sample.
struct OurRecordChip: View {
    @Environment(\.theme) private var theme
    let codes: Int
    let attempts: Int

    private var tint: Color {
        guard let band = DeliveryBand.of(codes: codes, attempts: attempts) else {
            return theme.text2
        }
        return theme.deliveryColor(band)
    }

    var body: some View {
        Text("Ours: \(codes) of \(attempts)")
            .font(RFont.text(11, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
    }
}

/// Everything we can honestly say about ONE route's delivery, in one slot.
///
/// For the single-route surfaces — the Home hero, Checkout, and the service
/// picker — where there is exactly one route on screen and this is the element
/// answering "will this actually work?". `CountrySheet` deliberately does NOT
/// use it: that row is two-column, with the meter under the dial code and the
/// chip in the price column, and squeezing them into one stack there would
/// undo the separation.
///
/// The precedence, and why:
///
/// - **A network rate, when the vendor publishes one for this route's pool.**
///   This is the change of 2026-08-06: these surfaces used to render only our
///   own record, so 2,731 of 9,323 bookable routes said "Not tested" while the
///   country picker showed a real figure for the very same pair.
/// - **Our own record alongside it**, whenever we have one. It never replaces
///   the network figure and never hides behind it — both are true, they answer
///   different questions, and `OurRecordChip` names its owner.
/// - **`SuccessBadge` otherwise**, which is still "Not tested" for the
///   **6,592 of 9,323** bookable routes (70.7%) where nobody has measured
///   anything. That fallback is not a leftover: on a one-route screen an empty
///   slot reads as reassurance, which is the exact failure `DeliveryRecord`
///   was written to end. Showing nothing here would re-introduce it for seven
///   routes in ten.
struct DeliverySignal: View {
    /// The vendor's published rate for this route's pool. nil = they publish
    /// none — never 0, which is a measurement and means something else.
    let poolRate: Int?
    /// Our own record. Never nil; `.notTested` is a real answer.
    let record: DeliveryRecord
    /// Narrows `SuccessBadge`'s wording on space-constrained rows.
    var compact: Bool = false
    /// Match the slot this sits in — Checkout's receipt column is trailing.
    var alignment: HorizontalAlignment = .leading

    /// Both figures present. Rare today (6 routes carry a record of our own)
    /// but it must not render as one merged claim when it happens.
    private var ourRecord: (codes: Int, attempts: Int)? {
        guard case let .measured(codes, attempts) = record, attempts > 0 else { return nil }
        return (codes, attempts)
    }

    var body: some View {
        if let poolRate {
            VStack(alignment: alignment, spacing: 4) {
                NetworkRateMeter(pct: poolRate)
                if let ours = ourRecord {
                    OurRecordChip(codes: ours.codes, attempts: ours.attempts)
                }
            }
        } else {
            // Includes the measured-but-unrated case: `SuccessBadge` already
            // renders "Delivered on N of M orders" for it.
            SuccessBadge(record: record, compact: compact)
        }
    }
}
