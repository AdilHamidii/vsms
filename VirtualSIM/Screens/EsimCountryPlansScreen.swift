import SwiftUI

/// The plans for one country: pick how long, then pick how much.
///
/// The previous screen was a single price-ascending list of every active plan —
/// for Japan, 25 rows, four of them reading "1 GB · 1 day" at four different
/// prices, and a third of them strictly worse than another row on the same
/// screen (see `EsimPlanRanking` for the measurements).
///
/// Splitting on duration first is what makes the rest legible. Duration is the
/// axis the traveller already knows before they open the app — they know how
/// long the trip is — whereas "how many gigabytes" is a question they can only
/// answer relative to the options. Fixing the axis they know turns a
/// three-variable comparison into a one-variable one.
struct EsimCountryPlansScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let entry: EsimCountryEntry
    var openCredits: () -> Void

    @State private var days: Int?
    @State private var showAll = false
    @State private var appeared = false

    private var all: [EsimPlan] { state.esimPlans(forCountry: entry.code) }
    private var durations: [Int] { EsimPlanRanking.durations(all) }

    /// Plans for the chosen duration, best-first.
    private var visible: [EsimPlan] {
        let forDuration = all.filter { $0.validityDays == days }
        let list = showAll ? forDuration : EsimPlanRanking.frontier(forDuration)
        return list.sorted { ($0.dataMb ?? 0) < ($1.dataMb ?? 0) }
    }
    private var hiddenCount: Int {
        EsimPlanRanking.hiddenCount(all.filter { $0.validityDays == days })
    }
    private var bestValue: EsimPlan? { EsimPlanRanking.bestValue(visible) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                durationPicker
                planList
                if hiddenCount > 0 { disclosure }
                Color.clear.frame(height: 120)
            }
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CreditPill(value: state.balance, action: openCredits)
            }
        }
        .onAppear {
            if days == nil { days = Self.defaultDuration(durations) }
            withAnimation(RMotion.content) { appeared = true }
        }
    }

    /// A week, or whatever is closest to it.
    ///
    /// The catalog skews hard to 1-day plans (496 of 1,081) purely because the
    /// provider lists many of them, not because they are what people want —
    /// defaulting to the most-listed duration would open every country on
    /// single-day plans. A week is the modal trip length, so that is the
    /// opening view; the chips make any other choice one tap away.
    private static func defaultDuration(_ options: [Int]) -> Int? {
        options.min { abs($0 - 7) < abs($1 - 7) }
    }

    // MARK: - Duration

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW LONG")
                .font(RFont.text(11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(durations, id: \.self) { d in
                        let active = d == days
                        Button {
                            withAnimation(RMotion.select) { days = d; showAll = false }
                        } label: {
                            VStack(spacing: 1) {
                                Text("\(d)")
                                    .font(RFont.display(17, weight: .bold)).tracking(-0.4)
                                Text(d == 1 ? "day" : "days")
                                    .font(RFont.text(11, weight: .medium))
                            }
                            .foregroundStyle(active ? theme.onInk : theme.text2)
                            .frame(minWidth: 58)
                            .padding(.vertical, 9).padding(.horizontal, 12)
                            .background(active ? theme.ink : theme.chipBg,
                                        in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Plans

    private var planList: some View {
        VStack(spacing: 10) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, plan in
                planCard(plan, isBest: plan.id == bestValue?.id)
                    .riseIn(appeared, index: idx)
            }
            if visible.isEmpty {
                Text("No plans at this length.")
                    .font(RFont.text(13)).foregroundStyle(theme.text2)
                    .padding(.top, 30)
            }
        }
        .padding(.horizontal, 16)
    }

    private func planCard(_ plan: EsimPlan, isBest: Bool) -> some View {
        let cr = plan.retailCredits ?? 0
        let affordable = cr <= state.balance
        return Button {
            state.startEsimCheckout(plan)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(plan.dataLabel)
                                .font(RFont.display(24, weight: .bold)).tracking(-0.8)
                                .foregroundStyle(theme.text)
                            if isBest {
                                Text("BEST VALUE")
                                    .font(RFont.text(9, weight: .bold)).tracking(0.4)
                                    .foregroundStyle(theme.onInk)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(theme.ink, in: .capsule)
                            }
                        }
                        HStack(spacing: 6) {
                            if let perDay = plan.perDayLabel {
                                Text(perDay).font(RFont.text(12)).foregroundStyle(theme.text2)
                                Text("·").foregroundStyle(theme.text3)
                            }
                            if let value = plan.creditsPerGBLabel {
                                Text(value).font(RFont.mono(11)).foregroundStyle(theme.text3)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(cr)")
                                .font(RFont.display(22, weight: .bold)).tracking(-0.5)
                                .foregroundStyle(affordable ? theme.text : theme.text2)
                            Text("cr").font(RFont.text(12, weight: .medium))
                                .foregroundStyle(theme.text2)
                        }
                        // The largest APPROVED credit pack is 60 while the mean
                        // eSIM plan is 59 credits, so "can I afford this?" is
                        // the live question on this screen and a bare price does
                        // not answer it.
                        if !affordable {
                            // "+4 more" sitting directly under "4 cr" was
                            // ambiguous about both the unit and the direction —
                            // it reads as a surcharge. Name the unit and the
                            // fact that it is a shortfall.
                            Text("\(cr - state.balance) cr short")
                                .font(RFont.text(11, weight: .medium))
                                .foregroundStyle(theme.warn)
                        }
                    }
                }
                .padding(14)

                if let speed = plan.speed, !speed.isEmpty {
                    Divider().overlay(theme.sep)
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10)).foregroundStyle(theme.text3)
                        Text(speed).font(RFont.text(11)).foregroundStyle(theme.text2)
                        Spacer(minLength: 0)
                        if plan.extendable == true {
                            Text("Top-up-able").font(RFont.text(11)).foregroundStyle(theme.text3)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
            .background(theme.elev, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(isBest ? theme.ink.opacity(0.4) : theme.sep, lineWidth: isBest ? 1.2 : 0.5))
            .contentShape(.rect)
        }
        .pressableCard()
    }

    // MARK: - Disclosure

    private var disclosureLabel: String {
        if showAll {
            return hiddenCount == 1
                ? String(localized: "Hide 1 worse-value plan")
                : String(localized: "Hide \(hiddenCount) worse-value plans")
        }
        return hiddenCount == 1
            ? String(localized: "Show 1 more plan")
            : String(localized: "Show \(hiddenCount) more plans")
    }

    /// Never shorten a list silently. The user is told exactly how many rows are
    /// held back and why, and can see them in one tap — the filter is a default,
    /// not a decision made on their behalf.
    private var disclosure: some View {
        Button {
            withAnimation(RMotion.content) { showAll.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAll ? "eye.slash" : "eye")
                    .font(.system(size: 11, weight: .medium))
                // Four complete sentences rather than interpolating the noun.
                // "Show %lld more %@" cannot be translated correctly — German
                // and the Romance languages inflect the adjective to agree with
                // the noun, so the fragment has to be part of the translated
                // string, not substituted into it.
                Text(disclosureLabel)
                    .font(RFont.text(12, weight: .medium))
            }
            .foregroundStyle(theme.text2)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(theme.chipBg, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

// `PressableStyle` lived here — a SECOND press vocabulary with its own spring
// and its own numbers, used on four eSIM surfaces while the rest of the app
// used `.pressable()`. Identical card taps therefore felt different depending
// on the screen. Replaced by `.pressableCard()` in DesignSystem/Feedback.swift,
// which is the same look driven by the one shared style.
