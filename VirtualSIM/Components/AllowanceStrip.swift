import SwiftUI

/// Call minutes left on a rented line, with the reset date.
///
/// Reports what is **left**, never what is used — the same choice `DataRing`
/// makes and for the same reason: the server hands us "used", but the question
/// the user has is "how much can I still do", and making them subtract is a tax
/// paid on every glance.
///
/// It is on screen continuously rather than surfacing at the limit, because
/// billing here is a **hard stop**: there is no overage to absorb a surprise.
/// A meter the user has been watching all month makes running out an expected
/// event rather than a failure.
struct AllowanceStrip: View {
    @Environment(\.theme) private var theme
    let line: Line

    /// Whether to print the reset date under the gauges.
    ///
    /// Off on the Number tab since the hero header gained `renews <date>`: the
    /// allowance resets ON renewal, so the two lines are the same date by
    /// construction and printing both says one thing twice. Kept as a parameter
    /// rather than deleted because the strip is reusable and the date is the
    /// right thing to show anywhere the renewal is not already stated.
    var showsResetDate: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The `HStack(alignment: .top, spacing: 16)` that used to hold two
            // gauges is gone with the second one — a single-child stack whose
            // spacing applies to nothing. The gauge keeps its
            // `.frame(maxWidth: .infinity)`, so the bar renders exactly as it
            // did before this cleanup: full width.
            //
            // 🔴 THERE IS NO "texts left" GAUGE HERE, AND THE ORIGINAL REASON
            // IS RETIRED — READ THE NEW ONE BEFORE ADDING ONE.
            //
            // It was forbidden from 2026-08-18 because outbound SMS was dropped
            // entirely: `line.sms_used` was frozen, so the bar rendered a
            // permanently full "200 texts left" — a metered promise of a
            // capability the product could not honour. **Sending was restored
            // on 2026-09-08 and proven off-net, so that argument no longer
            // holds.**
            //
            // The rule survives on a different footing: the count IS shown, in
            // the composer (`ThreadScreen`, "N texts left this month"), which is
            // where it is spendable and therefore where it means something. A
            // second copy here would be a claim on the screen a subscriber opens
            // daily, in a strip whose other gauges are about MINUTES.
            // `NumberDetailView` deleted its own copy of this row, and its
            // comment forbids re-purposing it as an INBOUND counter — that part
            // is unconditional: inbound is unmetered, so a bar that only ever
            // falls would invent a limit that does not exist.
            //
            // Restored in the commit that shipped the dialer. It was held
            // back while `flow = .dialer` was assigned nowhere, because a
            // meter reading "78 minutes left" promises 78 spendable
            // minutes on the screen a subscriber looks at every day. The
            // rule it enforced still applies to anything added here: a
            // gauge is a claim, so it ships with the capability or after
            // it, never before.
            gauge(
                icon: RIcon.phone,
                value: "\(line.voiceSecondsRemaining / 60)",
                unit: "minutes left",
                fraction: line.voiceFraction
            )
            if showsResetDate, let reset = line.allowanceResetsAt {
                // Allowances reset on RENEWAL, never on a calendar boundary —
                // resetting on the 1st would hand a mid-month subscriber a free
                // extra allowance. So this is the renewal date, stated plainly.
                Text("Resets \(reset.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(RFont.text(11))
                    .foregroundStyle(theme.text3)
            }
        }
    }

    private func gauge(icon: String, value: String,
                       unit: LocalizedStringKey, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint(fraction))
                Text(value)
                    .font(RFont.display(17, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
            }
            AllowanceBar(fraction: fraction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Colour is a real warning channel, not decoration — amber under 20% left,
    /// red under 5%. A bar that turns amber at half is a bar the user has
    /// learned to ignore by the time it matters. Thresholds match `DataRing`
    /// deliberately: two meters in one app that mean different things by the
    /// same colour is worse than either choice alone.
    private func tint(_ fraction: Double) -> Color {
        let left = 1 - fraction
        if left <= 0.05 { return theme.fail }
        if left <= 0.20 { return theme.warn }
        return theme.ink
    }
}

/// `DataBar` in everything but its inputs. That one takes MB and derives the
/// fraction itself; this takes the fraction, because SMS counts and call
/// seconds are not megabytes and reusing it would mean lying about units at the
/// call site.
struct AllowanceBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    @State private var animated = false

    private var tint: Color {
        let left = 1 - fraction
        if left <= 0.05 { return theme.fail }
        if left <= 0.20 { return theme.warn }
        return theme.ink
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.chipBg)
                Capsule().fill(tint)
                    .frame(width: animated ? geo.size.width * max(0, 1 - fraction) : 0)
            }
        }
        .frame(height: 5)
        .onAppear { withAnimation(RMotion.value) { animated = true } }
        .onChange(of: fraction) { _, _ in withAnimation(RMotion.value) { animated = true } }
    }
}
