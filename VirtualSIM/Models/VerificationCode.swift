import Foundation

/// Pulls a verification code out of an inbound SMS, or returns nil.
///
/// The rented-number line exists largely so people can receive codes, and until
/// now a code arriving in a thread was raw text the user had to select by hand —
/// while the temp-number product (`OtpScreen`) and the e-mail product
/// (`EmailCodeScreen`) both extract it and offer one-tap copy. This closes that
/// gap for the third line.
///
/// ── It is deliberately CONSERVATIVE, and that is the whole design ──────────
/// This repo's standing rule is to show nothing rather than a plausible-looking
/// guess — the same rule that keeps seeded success rates off badges and returns
/// `nil` from the eSIM coverage parser. A wrongly-detected code is worse than no
/// detection at all: the user taps Copy, pastes it, is rejected, and now
/// distrusts the number itself. So a candidate must clear one of two bars:
///
///   1. the message contains a verification keyword, or
///   2. the message contains EXACTLY ONE plausible candidate.
///
/// Rule 2 is what keeps "call 555 1234 for 20% off" from being read as a code,
/// because that message has two candidates and neither wins.
enum VerificationCode {

    /// Digit runs shorter than this are ordinals ("2 items"); longer ones are
    /// phone numbers, order ids and timestamps. 4–8 is where real codes live.
    private static let lengths = 4...8

    /// Matched case-insensitively against the whole message. Kept to the
    /// languages we actually ship plus the two that dominate global SMS
    /// templates — and note these are the SENDER's words, not our UI, so they
    /// are NOT localizable strings and must not be moved into the catalog.
    private static let keywords = [
        "code", "otp", "pin", "verif",          // en + fr/es/pt/it share the stem
        "bestätigung", "kode", "código", "codice", "verifica",
        "認証", "確認",                            // ja
        "password", "passcode", "one-time", "2fa",
    ]

    /// The code in `body`, or nil when nothing clears the bar.
    static func detect(in body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }

        // Split on anything that is not a digit, so a run embedded in a longer
        // number ("+14375551234") stays one over-length token and is rejected
        // rather than being sliced into a false candidate.
        let candidates = body
            .split(whereSeparator: { !$0.isNumber })
            .map(String.init)
            .filter { lengths.contains($0.count) }

        guard !candidates.isEmpty else { return nil }

        // More than one candidate is always a refusal, keyword or not:
        // "your code for order 4471 is 90210" is exactly the shape that would
        // hand over the order number, and picking by position is a guess
        // wearing a heuristic's clothes.
        guard candidates.count == 1, let candidate = candidates.first else { return nil }

        let lower = body.lowercased()
        if keywords.contains(where: { lower.contains($0) }) { return candidate }

        // No keyword. A lone number in a long sentence is far more likely to be
        // a balance, a price or a date than a code — "your balance is 1234 EUR"
        // would otherwise be offered as one. Accept it only when the message is
        // essentially just the code, which is how the terse senders write them.
        let stripped = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.count <= candidate.count + 4 ? candidate : nil
    }
}
