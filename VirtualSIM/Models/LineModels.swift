import Foundation

// The fourth product line: a phone number the user RENTS and KEEPS, with
// two-way SMS and voice. Unlike the other three it is billed by StoreKit
// subscription and never touches the credit wallet — see CLAUDE.md,
// "Rentable second numbers".
//
// ⚠️ EVERY enum here has an `unknown` fallback in `init(from:)`, and that is
// deliberate rather than defensive habit. iOS `OrderStatus` is a plain String
// enum with no unknown case, so a status the shipped build does not recognise
// throws on decode and takes the WHOLE orders tab down — which is why
// `begin_order` has to write a semantically wrong `'waiting'` for its
// pre-reservation row. Six lines per enum permanently removes the
// client-first-schema-second release ordering from this product line.
//
// Note `.convertFromSnakeCase` rewrites KEYS, never VALUES: `past_due` arrives
// verbatim and needs an explicit raw value.

// MARK: - Status

enum LineStatus: String, Codable, Hashable {
    case provisioning
    case active
    case grace
    case pastDue = "past_due"
    case suspended
    case releasing
    case released
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LineStatus(rawValue: raw) ?? .unknown
    }

    /// Can the user send a text or place a call right now?
    ///
    /// `grace` is deliberately permissive: Apple's billing grace period exists
    /// so an expired card does not cost the customer their service, and cutting
    /// them off during it would defeat the whole point of enabling it.
    var canSend: Bool { self == .active || self == .grace }

    /// Inbound keeps working one step longer than outbound. A number that
    /// silently stops RECEIVING is indistinguishable from a broken number, and
    /// the user cannot control who texts them.
    var canReceive: Bool { self == .active || self == .grace || self == .pastDue }

    /// Occupies the one-live-line-per-user slot server-side
    /// (`phone_lines_one_live_per_user`).
    var isLive: Bool {
        switch self {
        case .provisioning, .active, .grace, .pastDue, .suspended, .releasing: true
        case .released, .failed, .unknown: false
        }
    }

    /// True while the number is still being set up and there is nothing to use.
    var isSettingUp: Bool { self == .provisioning }
}

enum LineMsgDirection: String, Codable, Hashable {
    case inbound, outbound, unknown
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LineMsgDirection(rawValue: raw) ?? .unknown
    }
}

enum LineMsgStatus: String, Codable, Hashable {
    case queued, sending, sent, delivered, failed, received, unknown
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LineMsgStatus(rawValue: raw) ?? .unknown
    }
    var isFailed: Bool { self == .failed }
    var isInFlight: Bool { self == .queued || self == .sending }
}

enum LineCallDirection: String, Codable, Hashable {
    case inbound, outbound, unknown
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LineCallDirection(rawValue: raw) ?? .unknown
    }
}

enum LineCallStatus: String, Codable, Hashable {
    case ringing, answered, completed, missed, busy, failed, canceled, unknown
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LineCallStatus(rawValue: raw) ?? .unknown
    }
    /// A call the user never got to. Rendered in `theme.fail`, like a missed
    /// call anywhere else.
    var isMissed: Bool { self == .missed || self == .busy }
}

// MARK: - The line

/// One row of the `my_line` VIEW — never `phone_lines` itself.
///
/// RLS is row-level and cannot restrict columns, and the base table holds
/// `monthly_cost_cents` plus every Telnyx internal id. SELECT on it is revoked
/// outright from `authenticated`, so this view is the only readable shape and
/// its `where user_id = auth.uid()` IS the security boundary.
struct Line: Codable, Identifiable, Hashable {
    let id: String
    let e164: String
    let countryCode: String
    let numberType: String
    let status: LineStatus
    let currentPeriodStart: Date?
    let currentPeriodEnd: Date?
    let graceUntil: Date?
    let holdUntil: Date?
    let smsAllowance: Int
    let smsUsed: Int
    let voiceAllowanceSeconds: Int
    let voiceUsedSeconds: Int
    let allowancePeriodStart: Date?
    let emergencyDisabled: Bool
    let createdAt: Date
    let activatedAt: Date?
    let releasedAt: Date?

    // MARK: Allowance
    //
    // Every accessor reports what is LEFT, never what is used. The provider
    // gives us "used" and the question the user actually has is "how much can
    // I still do", so making them subtract is a tax paid on every glance —
    // the same reasoning as `DataRing`.

    var smsRemaining: Int { max(0, smsAllowance - smsUsed) }
    var voiceSecondsRemaining: Int { max(0, voiceAllowanceSeconds - voiceUsedSeconds) }
    var voiceMinutesRemaining: Int { voiceSecondsRemaining / 60 }

    var hasSmsLeft: Bool { smsRemaining > 0 }
    var hasVoiceLeft: Bool { voiceSecondsRemaining > 0 }

    /// 0…1 of the allowance consumed, for the bars. Guards a zero allowance so
    /// a misconfigured line renders empty rather than dividing by zero.
    var smsFraction: Double {
        guard smsAllowance > 0 else { return 0 }
        return min(1, Double(smsUsed) / Double(smsAllowance))
    }
    var voiceFraction: Double {
        guard voiceAllowanceSeconds > 0 else { return 0 }
        return min(1, Double(voiceUsedSeconds) / Double(voiceAllowanceSeconds))
    }

    /// When the counters go back to full. Allowances reset on RENEWAL, never on
    /// a calendar boundary — resetting on the 1st would hand a mid-month
    /// subscriber a free extra allowance.
    var allowanceResetsAt: Date? { currentPeriodEnd }

    // MARK: Send gating
    //
    // Two different reasons a composer is disabled, and they must not be
    // collapsed: one is "you have used your texts", the other is "your payment
    // failed". Telling a past-due user they are out of texts would send them
    // to wait for a reset that is not coming.

    enum SendBlock: Hashable {
        case allowanceExhausted
        case pastDue
        case suspended
        case notLive
    }

    var sendBlock: SendBlock? {
        switch status {
        case .active, .grace:
            return hasSmsLeft ? nil : .allowanceExhausted
        case .pastDue:  return .pastDue
        case .suspended: return .suspended
        default:        return .notLive
        }
    }

    var callBlock: SendBlock? {
        switch status {
        case .active, .grace:
            return hasVoiceLeft ? nil : .allowanceExhausted
        case .pastDue:  return .pastDue
        case .suspended: return .suspended
        default:        return .notLive
        }
    }
}

// MARK: - Threads, messages, calls

struct LineThread: Codable, Identifiable, Hashable {
    let id: String
    let lineId: String
    let peerE164: String
    let lastMessageAt: Date?
    let lastPreview: String?
    let unreadCount: Int
    let blocked: Bool
    let createdAt: Date
}

struct LineMessage: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let lineId: String
    let direction: LineMsgDirection
    let e164From: String
    let e164To: String
    let body: String?
    let status: LineMsgStatus
    let segments: Int
    let sentAt: Date?
    let receivedAt: Date?
    let createdAt: Date

    /// What to stamp under the bubble. Falls back to `createdAt` so a message
    /// still in flight — which has neither `sent_at` nor `received_at` yet —
    /// carries a time rather than a blank.
    var timestamp: Date { sentAt ?? receivedAt ?? createdAt }
    var isOutbound: Bool { direction == .outbound }
}

struct LineCall: Codable, Identifiable, Hashable {
    let id: String
    let lineId: String
    let direction: LineCallDirection
    let peerE164: String
    let status: LineCallStatus
    let startedAt: Date?
    let answeredAt: Date?
    let endedAt: Date?
    let durationSeconds: Int?
    let billedSeconds: Int?
    let createdAt: Date

    /// Prefer the CDR's figure. `duration_seconds` is what the CLIENT reported
    /// and is advisory only — a client can be wrong, killed, or lying — while
    /// `billed_seconds` is the billing truth and arrives minutes later.
    var displaySeconds: Int? { billedSeconds ?? durationSeconds }
}

// MARK: - Buying one

/// A city we sell numbers in. The picker offers CITIES rather than area codes
/// because Canada's prestige codes are exhausted — 416, 514, 613 and 403 all
/// return zero stock while their overlays (437, 438, 343, 587) are full. A raw
/// area-code picker would offer "416 — Toronto" and then fail.
struct LineCity: Codable, Identifiable, Hashable {
    let id: String
    let label: String

    /// Rendered immediately so the picker is on screen before any network call,
    /// then REPLACED by whatever the server returns — exactly how `SeedData`
    /// seeds the service catalogue.
    ///
    /// Safe to seed because a city is stable while an AREA CODE is not: the
    /// server owns which codes it walks and in what order, and that is the part
    /// that goes dry. The worst case here is offering a city the server has
    /// since dropped, which fails honestly on the next screen ("no numbers in
    /// this city") instead of showing an empty picker for two seconds.
    static let seeded: [LineCity] = [
        .init(id: "toronto",   label: "Toronto"),
        .init(id: "montreal",  label: "Montreal"),
        .init(id: "vancouver", label: "Vancouver"),
        .init(id: "calgary",   label: "Calgary"),
        .init(id: "ottawa",    label: "Ottawa"),
        .init(id: "halifax",   label: "Halifax"),
        .init(id: "winnipeg",  label: "Winnipeg"),
    ]

    /// Province, for the city cards. Purely cosmetic — a bare city list reads
    /// as a dropdown, and this is meant to feel like choosing where you live.
    ///
    /// Resolved through `String(localized:)` here rather than handed out as a
    /// `LocalizedStringKey`, so this file stays free of SwiftUI. Call sites
    /// render it with plain `Text(_:)`, which is correct precisely because the
    /// catalog lookup already happened.
    var region: String {
        switch id {
        case "toronto":   String(localized: "Ontario")
        case "montreal":  String(localized: "Quebec")
        case "vancouver": String(localized: "British Columbia")
        case "calgary":   String(localized: "Alberta")
        case "ottawa":    String(localized: "Ontario")
        case "halifax":   String(localized: "Nova Scotia")
        case "winnipeg":  String(localized: "Manitoba")
        default:          String(localized: "Canada")
        }
    }
}

/// One number on offer, from `search-line-numbers`.
///
/// `monthlyCents` / `upfrontCents` are what TELNYX charges US. They are carried
/// so the purchase can stamp them onto `phone_lines.monthly_cost_cents` —
/// nothing reports the cost again afterwards, so this quote is the only chance
/// to record it. They are NEVER rendered: the user sees the subscription price.
struct LineNumberOffer: Codable, Identifiable, Hashable {
    let phoneNumber: String
    let region: String?
    let monthlyCents: Int?
    let upfrontCents: Int?

    var id: String { phoneNumber }
}

/// The result of a search, plus the hold if we managed to place one.
struct LineAvailability: Codable, Hashable {
    let city: String
    let label: String?
    let areaCode: String?
    let cities: [LineCity]
    let numbers: [LineNumberOffer]

    var first: LineNumberOffer? { numbers.first }
}

/// A number held for this user while they decide.
///
/// `heldUntil` is OPTIONAL on purpose. Telnyx reservations have not been probed
/// live — CLAUDE.md records only `reservable: true` from a search response — so
/// the UI must be able to show a number with no hold at all. When this is nil
/// the card reads "Available now" and shows no countdown, rather than claiming
/// a hold we cannot back. Same rule as `DataRing`'s "no reading".
struct LineReservation: Codable, Hashable {
    let phoneNumber: String
    let city: String
    let heldUntil: Date?

    var isExpired: Bool {
        guard let heldUntil else { return false }
        return heldUntil <= Date()
    }
}

/// What `reserve-line-number` returns.
///
/// `monthlyCents` / `upfrontCents` are OUR wholesale and are never rendered —
/// they exist so the purchase can stamp the cost onto the line, because Telnyx
/// reports it nowhere afterwards.
struct LineReservationQuote: Codable, Hashable {
    let phoneNumber: String
    let region: String?
    let city: String
    /// nil when Telnyx would not hold it. The UI renders "Available now" rather
    /// than a countdown in that case — see `LineCheckoutScreen.holdLine`.
    let heldUntil: Date?
    let reservationId: String?
    let monthlyCents: Int?
    let upfrontCents: Int?

    var reservation: LineReservation {
        LineReservation(phoneNumber: phoneNumber, city: city, heldUntil: heldUntil)
    }
}

struct LineProvisionResult: Codable, Hashable {
    let ok: Bool
    let lineId: String?
    let e164: String?
}

struct LineSendResult: Codable, Hashable {
    let ok: Bool
    let messageId: String?
    let threadId: String?
    /// Texts left after this send, straight from the server's own counter.
    /// Preferred over decrementing locally: the segment count is decided
    /// server-side and a long message costs more than one.
    let remaining: Int?
}

/// Why the store has nothing to sell.
///
/// Three cases and not two, because an empty catalogue has more than one cause
/// and we only ever KNOW one of them. `paused` is a statement the server made;
/// `noStock` is an observation about one city; `unknown` covers a failed fetch,
/// which from the client is indistinguishable from an empty one. Asserting a
/// reason we do not have is the same error as rendering a seeded success rate
/// as a measurement — see `EsimStoreScreen.emptyCatalog`, which this mirrors.
enum LineUnavailableReason: Hashable {
    case paused
    case noStock
    case unknown
}

// MARK: - Formatting

/// E.164 → something a person reads. NANP only, which is the whole catalogue:
/// US and Canada are the only countries Telnyx will sell us without an
/// in-country address, and PR/VI are US area codes rather than extra markets.
enum PhoneFormat {
    /// `+14375550128` → `+1 (437) 555-0128`. Anything that is not an 11-digit
    /// +1 number is returned untouched — a half-formatted foreign number is
    /// worse than a raw one.
    static func national(_ e164: String) -> String {
        let digits = e164.filter(\.isNumber)
        guard e164.hasPrefix("+1"), digits.count == 11 else { return e164 }
        let d = Array(digits)
        let area = String(d[1...3])
        let exch = String(d[4...6])
        let line = String(d[7...10])
        return "+1 (\(area)) \(exch)-\(line)"
    }

    /// Compact form for list rows, where the full parenthesised version is too
    /// wide beside a timestamp.
    static func compact(_ e164: String) -> String {
        let digits = e164.filter(\.isNumber)
        guard e164.hasPrefix("+1"), digits.count == 11 else { return e164 }
        let d = Array(digits)
        return "(\(String(d[1...3]))) \(String(d[4...6]))-\(String(d[7...10]))"
    }

    /// `87 min` / `1:23` style duration for call rows.
    static func duration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
