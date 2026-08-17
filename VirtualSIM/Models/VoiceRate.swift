import Foundation

/// What one minute to a destination costs, in credits.
///
/// Read from `voice_rate_card`, a retail-only VIEW — never from `voice_rates`,
/// which is the wholesale cost book and has SELECT revoked from clients. That
/// separation exists from day one here on purpose: `routes` and `esim_plans`
/// both publish our cost to anyone holding the publishable key, and fixing them
/// needs a client release first.
struct VoiceRate: Codable, Hashable, Identifiable {
    /// E.164 prefix WITHOUT the leading `+`, e.g. `33`. Longest match wins, so
    /// a premium sub-range can override its own country without a special case.
    let prefix: String
    let iso2: String
    let label: String
    let creditsPerMin: Double
    /// True only for NANP: covered by the plan's minute allowance, never
    /// charged to the wallet. The two meters are mutually exclusive.
    let coveredByAllowance: Bool

    var id: String { prefix }
}

extension Array where Element == VoiceRate {
    /// Longest-prefix match for a dialled string.
    ///
    /// ⚠️ Returns nil for an unpriced destination, and the caller MUST treat
    /// that as "cannot call" rather than "free". The server refuses the same
    /// way (`voice_rate_for` returns SETOF precisely so `not found` fires) —
    /// defaulting an unknown prefix to a cheap rate is how a $3.62/min premium
    /// range gets billed as a landline.
    func match(dialled: String) -> VoiceRate? {
        let digits = dialled.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return self
            .filter { digits.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
    }
}

extension VoiceRate {
    /// How the rate reads on the dialer.
    ///
    /// Sub-1-credit rates are the norm — a credit nets $0.40 and 5× on France
    /// is 0.19 credits/min — so this deliberately shows what a credit BUYS
    /// rather than a fraction the user cannot act on. "0.2 credits/min" is
    /// true and useless; "1 credit ≈ 5 min" is what decides whether they dial.
    var rateSentence: String {
        if coveredByAllowance {
            return String(localized: "Included in your minutes")
        }
        if creditsPerMin >= 1 {
            let n = Int(creditsPerMin.rounded())
            return String(localized: "\(n) credits per minute")
        }
        let minutesPerCredit = creditsPerMin > 0 ? 1.0 / creditsPerMin : 0
        let m = Int(minutesPerCredit.rounded(.down))
        guard m >= 1 else { return String(localized: "1 credit per minute") }
        return String(localized: "1 credit ≈ \(m) min")
    }
}
