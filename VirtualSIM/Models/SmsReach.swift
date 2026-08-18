import Foundation

/// Whether a rented line can actually deliver a text to a given number.
///
/// ── Why this is duplicated from the server ───────────────────────────────
///
/// `supabase/functions/_shared/nanp.ts` is the AUTHORITY and stays the
/// boundary: `send-line-message` refuses with `international_sms` /
/// `cross_border_sms` whatever the client believes. This copy exists only so
/// the refusal is visible BEFORE the user writes a message — being told "no"
/// after typing it out is the part that reads as a bug.
///
/// So the two may drift without breaking anything: a stale copy here shows the
/// wrong hint, never the wrong outcome. Keep the NPA table in step anyway —
/// when a new Canadian area code opens, this file and `nanp.ts` both need it.
///
/// ⚠️ THIS IS TEMPORARY AND SHOULD BE DELETED, not tuned. It encodes a carrier
/// registration gap (`40010`, 10DLC), not a fact about telephony. When
/// toll-free verification or 10DLC clears, delete it here and there together
/// rather than adding exceptions to it.
enum SmsReach {
    enum Refusal: Equatable {
        /// Both ends are NANP, different countries — e.g. a Canadian line
        /// texting a US number.
        case crossBorder(from: String)
        /// The destination is outside the NANP entirely.
        case international(from: String)
    }

    /// The full set of Canadian area codes. Mirrors `CA_NPA` in `nanp.ts`.
    ///
    /// A missing entry reads a Canadian number as American and shows a refusal
    /// the server would not make — which is the safe direction, since the send
    /// is still attempted and the server still decides.
    private static let caNPA: Set<String> = [
        "204", "226", "236", "249", "250", "263", "289", "306", "343", "354",
        "365", "367", "368", "382", "387", "403", "416", "418", "428", "431",
        "437", "438", "450", "468", "474", "506", "514", "519", "548", "579",
        "581", "584", "587", "600", "604", "613", "639", "647", "672", "683",
        "705", "709", "742", "753", "778", "780", "782", "807", "819", "825",
        "867", "873", "879", "902", "905",
    ]

    /// `"US"` / `"CA"` for a +1 number, nil for anything else.
    static func nanpCountry(_ e164: String) -> String? {
        let d = e164.filter(\.isNumber)
        guard d.count == 11, d.hasPrefix("1") else { return nil }
        let npa = String(Array(d)[1...3])
        return caNPA.contains(npa) ? "CA" : "US"
    }

    /// nil when the send is worth attempting. Mirrors `canSendTo`, including
    /// its permissive branch for an unclassified SENDER — inventing refusals
    /// out of missing data is how a product quietly loses destinations it
    /// could serve.
    static func refusal(from lineCountry: String?, to recipient: String) -> Refusal? {
        let from = (lineCountry ?? "").uppercased()
        guard !from.isEmpty else { return nil }
        let to = nanpCountry(recipient)

        if from == "US" || from == "CA" {
            guard let to else { return .international(from: from) }
            return from == to ? nil : .crossBorder(from: from)
        }

        guard let to else { return nil }
        return from == to ? nil : .crossBorder(from: from)
    }

    /// What to tell the user, in the sender's own terms.
    ///
    /// Named per country rather than interpolated: a sentence assembled from a
    /// country name translates badly, and there are only two senders we sell.
    /// Returns a resolved `String` rather than a `LocalizedStringKey`, because
    /// only `String(localized:)` and `Text("literal")` are seen by the string
    /// extractor — a key handed back from a function is the exact shape that
    /// ships English to all six locales (CLAUDE.md, `Text(someString)`).
    static func explanation(_ refusal: Refusal) -> String {
        switch refusal {
        case .crossBorder(let from):
            return from == "CA"
                ? String(localized: "Your Canadian number can only text Canadian numbers right now. It can still receive texts from anywhere.")
                : String(localized: "Your US number can only text US numbers right now. It can still receive texts from anywhere.")
        case .international:
            return String(localized: "This number can't text other countries yet. It can still receive texts from anywhere.")
        }
    }
}
