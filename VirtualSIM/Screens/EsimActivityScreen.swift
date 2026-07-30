import SwiftUI

/// What the user's eSIMs have actually done: usage totals, then full history.
///
/// Every number here is arithmetic over rows we already hold — credits we
/// charged and megabytes `check-esim-usage` reported back from the provider.
/// There is deliberately no "average speed", "coverage score" or "typical
/// throughput": we do not measure any of those, and this codebase's standing
/// rule is that an unmeasured number is not shown at all, however good it would
/// look on a dashboard. The same rule already deleted a seeded 91% success rate
/// from the SMS waiting screen and keeps the eSIM coverage parser returning
/// `null` rather than guessing.
struct EsimActivityScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    @State private var appeared = false

    private var hasHistory: Bool { !state.esimOrders.isEmpty }

    var body: some View {
        ScrollView {
            if !hasHistory {
                empty
            } else {
                VStack(spacing: 16) {
                    summary.riseIn(appeared, index: 0)
                    // One list, every purchase, newest first. The live ones are
                    // NOT split out here — they have their own segment, and
                    // showing them twice in the same tab makes the count in the
                    // segment header disagree with what is on screen.
                    section("All purchases", state.esimOrders, startIndex: 1)
                    Color.clear.frame(height: 120)
                }
                .padding(.top, 6)
            }
        }
        .scrollIndicators(.hidden)
        .onAppear { withAnimation(RMotion.content) { appeared = true } }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                DataRing(usedMb: state.esimTotalUsedMb,
                         totalMb: totalAllowance,
                         size: 116, lineWidth: 11)

                VStack(alignment: .leading, spacing: 10) {
                    Metric(label: String(localized: "Data used"),
                           value: EsimFormat.data(state.esimTotalUsedMb))
                    Metric(label: String(localized: "Countries"),
                           value: "\(state.esimCountriesVisited)")
                    Metric(label: String(localized: "Credits spent"),
                           value: "\(state.esimCreditsSpent)")
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            if let next = state.esimNextExpiry {
                Divider().overlay(theme.sep)
                HStack(spacing: 7) {
                    Image(systemName: RIcon.clock)
                        .font(.system(size: 11)).foregroundStyle(theme.text3)
                    Text(expiryLine(next))
                        .font(RFont.text(12)).foregroundStyle(theme.text2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(theme.elev, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
    }

    /// Allowance across live eSIMs only — the ring shows what is left to use
    /// *now*, so folding in expired plans would permanently peg it near empty
    /// and make the colour warning meaningless.
    private var totalAllowance: Int? {
        let known = state.liveEsimOrders.compactMap(\.dataTotalMb)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +)
    }

    private func expiryLine(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0
        if days < 0  { return String(localized: "Latest plan has expired") }
        if days == 0 { return String(localized: "Soonest plan expires today") }
        return days == 1
            ? String(localized: "Soonest plan expires tomorrow")
            : String(localized: "Soonest plan expires in \(days) days")
    }

    // MARK: - Sections

    private func section(_ title: String, _ orders: [EsimOrder], startIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(RFont.text(11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 20)

            VStack(spacing: 8) {
                ForEach(Array(orders.enumerated()), id: \.element.id) { idx, o in
                    Button { state.openEsimDetail(o) } label: { row(o) }
                        .buttonStyle(PressableStyle())
                        .riseIn(appeared, index: startIndex + idx)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func row(_ o: EsimOrder) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CodeFlag(code: o.plan?.countryCode ?? "", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.name)
                        .font(RFont.display(15, weight: .semibold)).foregroundStyle(theme.text)
                    HStack(spacing: 5) {
                        Text(o.plan?.dataLabel ?? "—")
                            .font(RFont.text(12)).foregroundStyle(theme.text2)
                        Text("·").foregroundStyle(theme.text3)
                        Text(o.status.label)
                            .font(RFont.text(12, weight: .medium))
                            .foregroundStyle(statusTint(o.status))
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    if o.dataTotalMb != nil {
                        Text(o.dataRemainingLabel)
                            .font(RFont.mono(12, weight: .medium)).foregroundStyle(theme.text2)
                    }
                    Text("\(o.server.costCredits) cr")
                        .font(RFont.text(11)).foregroundStyle(theme.text3)
                }
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text3)
            }
            .padding(14)

            // A usage bar only where there is a real reading to draw. Rendering
            // an empty bar for an order the provider has not reported on would
            // read as "0% used" — a measurement we do not have.
            if o.status.keepsPolling, o.dataTotalMb != nil {
                DataBar(usedMb: o.dataUsedMb, totalMb: o.dataTotalMb)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .background(theme.elev, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.sep, lineWidth: 0.5))
        .contentShape(.rect)
    }

    private func statusTint(_ s: EsimStatus) -> Color {
        switch s {
        case .active, .installed: theme.live
        case .provisioning:       theme.text2
        case .depleted, .expired: theme.warn
        case .failed:             theme.fail
        case .refunded:           theme.text2
        }
    }

    // MARK: - Empty

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34)).foregroundStyle(theme.text3)
            Text("Nothing to show yet")
                .font(RFont.display(17, weight: .semibold)).foregroundStyle(theme.text)
            Text("Once you buy a data plan, your usage and full history appear here.")
                .font(RFont.text(13)).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 70).padding(.horizontal, 40)
    }
}
