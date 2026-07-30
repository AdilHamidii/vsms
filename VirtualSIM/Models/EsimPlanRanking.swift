import Foundation

/// Turns the raw provider catalog into something a person can choose from.
///
/// The store used to render every active plan for a country, sorted by price
/// ascending. Measured against the live catalog on 2026-07-30 that is a bad
/// screen for two independent reasons:
///
/// * **382 of 1,081 active plans (35.3%) are DOMINATED** — for each one there
///   is another plan in the same country giving at least as much data, for at
///   least as many days, at the same price or less. Japan sells 490 MB/1 day
///   for 6 credits and 490 MB/**7 days** for **5** — cheaper *and* longer. A
///   price-ascending list puts the worse plan first.
/// * **187 (country, data, days) triples have more than one plan.** Japan lists
///   "1 GB · 1 day" four times, at 9/10/11/12 credits, with nothing on the row
///   to tell them apart. The rows are not just redundant, they are
///   indistinguishable — the user cannot see what the extra 3 credits buy,
///   because it buys nothing.
///
/// So the fix is not a nicer row design; it is showing fewer rows. Everything
/// here is pure and derives only from catalog fields we already charge on — no
/// provider quality signal is invented, per the standing rule that we never
/// render a number we did not measure.
nonisolated enum EsimPlanRanking {

    /// A plan we can reason about: all three axes present.
    private struct Comparable {
        let plan: EsimPlan
        let mb: Int
        let days: Int
        let credits: Int
    }

    private static func comparable(_ p: EsimPlan) -> Comparable? {
        guard let mb = p.dataMb, let days = p.validityDays, let cr = p.retailCredits,
              mb > 0, days > 0, cr > 0 else { return nil }
        return Comparable(plan: p, mb: mb, days: days, credits: cr)
    }

    /// The plans worth showing: the Pareto frontier over (data ↑, days ↑, price ↓).
    ///
    /// A plan is dropped when another plan is **at least as good on every axis
    /// and strictly better on one**. Exact ties on all three axes are collapsed
    /// to a single row — otherwise the frontier keeps both, and two identical
    /// rows is the very confusion this exists to remove.
    ///
    /// Plans missing data, validity or price cannot be compared, so they are
    /// never dropped. Silently hiding a row because a column was NULL would be
    /// the catalog deciding what the user may see based on a provider gap.
    static func frontier(_ plans: [EsimPlan]) -> [EsimPlan] {
        let cmp = plans.compactMap(comparable)
        let incomparable = plans.filter { comparable($0) == nil }

        // Collapse exact (mb, days, credits) duplicates first, keeping a stable
        // representative so the list does not reshuffle between launches.
        var seen = Set<String>()
        let unique = cmp.filter { c in
            seen.insert("\(c.mb)|\(c.days)|\(c.credits)").inserted
        }

        let kept = unique.filter { a in
            !unique.contains { b in
                guard b.plan.id != a.plan.id else { return false }
                let atLeastAsGood = b.mb >= a.mb && b.days >= a.days && b.credits <= a.credits
                let strictlyBetter = b.mb > a.mb || b.days > a.days || b.credits < a.credits
                return atLeastAsGood && strictlyBetter
            }
        }
        return kept.map(\.plan) + incomparable
    }

    /// How many plans the frontier removed — shown to the user as an explicit
    /// "showing N of M" rather than quietly serving a shorter list.
    static func hiddenCount(_ plans: [EsimPlan]) -> Int {
        max(0, plans.count - frontier(plans).count)
    }

    /// Distinct validity lengths present, ascending.
    ///
    /// Live catalog: 1, 7, 15, 30 and 180 days account for 1,078 of 1,081 plans,
    /// so this reads as a clean set of choices rather than a long tail. The
    /// three stragglers (3, 10, 90) are returned too — derived from the data, so
    /// a new duration appears on its own without a code change.
    static func durations(_ plans: [EsimPlan]) -> [Int] {
        Array(Set(plans.compactMap(\.validityDays))).sorted()
    }

    /// Cheapest credits-per-GB among plans we can price. The "best value" mark.
    ///
    /// Ties break toward more total data: at equal value per GB the larger plan
    /// is the one that actually lasts, and an arbitrary tie-break would make the
    /// badge jump between two rows for no visible reason.
    static func bestValue(_ plans: [EsimPlan]) -> EsimPlan? {
        plans.compactMap(comparable)
            .min {
                let l = Double($0.credits) / Double($0.mb)
                let r = Double($1.credits) / Double($1.mb)
                return l == r ? $0.mb > $1.mb : l < r
            }?
            .plan
    }
}

extension EsimPlan {
    /// Credits per GB — the one number that makes plans of different sizes
    /// comparable at a glance. Nil when either side is missing rather than
    /// defaulted, so the row shows nothing instead of a fabricated ratio.
    var creditsPerGB: Double? {
        guard let mb = dataMb, mb > 0, let cr = retailCredits else { return nil }
        return Double(cr) / (Double(mb) / 1000)
    }

    var creditsPerGBLabel: String? {
        guard let v = creditsPerGB else { return nil }
        // Drop a trailing ".0" — a 9 cr/GB plan next to a 10 cr/GB one rendered
        // as "9.0" vs "10", which reads as two different kinds of number.
        return v == v.rounded()
            ? String(format: "%.0f cr/GB", v)
            : String(format: "%.1f cr/GB", v)
    }

    /// Rough daily allowance, for plans long enough that it means something.
    /// A 1-day plan's "per day" is just its size, which is noise on the row.
    var perDayLabel: String? {
        guard let mb = dataMb, let d = validityDays, d > 1, mb > 0 else { return nil }
        return "\(EsimFormat.data(max(1, mb / d)))/day"
    }
}
