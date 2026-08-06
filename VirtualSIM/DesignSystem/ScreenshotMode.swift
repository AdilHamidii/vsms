import Foundation

/// A DEBUG-only harness for producing App Store screenshots.
///
/// ── Why this exists ───────────────────────────────────────────────────────
///
/// App Store screenshots have to be regenerated for every release, at exact
/// pixel sizes Apple accepts (6.9" is 1290×2796 or 1320×2868 — a real iPhone 14
/// Pro produces 1179×2556, which ASC does not take). That means the simulator,
/// and the simulator cannot get past `AuthGate`: Sign in with Apple does not
/// work there.
///
/// It also means no UI automation. Rather than script taps, each screen is
/// addressed by a LAUNCH ARGUMENT and the app opens directly onto it — so a
/// screenshot run is N independent launches with nothing to go wrong in
/// between, and it produces the same frames every time.
///
/// ── Why it cannot ship ────────────────────────────────────────────────────
///
/// The entire file is inside `#if DEBUG`. In a Release build `isActive` is a
/// stored `false` the optimiser folds away, every call site compiles to
/// nothing, and none of the sample data below exists in the binary. A release
/// archive therefore cannot be put into this state by any launch argument,
/// environment variable, or server response.
///
/// ⚠️ The data here is **obviously synthetic and must stay that way**: 555
/// numbers, a fictional peer, a code that is not a real code. It is a mock of
/// our own UI, not a claim about anything. Do not "improve" it by pointing it
/// at production data — a screenshot showing a real user's number or a real
/// delivery statistic would be both a privacy leak and, since App Store
/// screenshots are marketing, an unmeasured claim.
enum ScreenshotMode {

    /// Which screen to open. One launch per value.
    enum Screen: String {
        case onboarding      // page 1, the product pitch
        case lineIntro       // the store's first page — what a second number is
        case lineStore       // pick a city
        case thread          // a real conversation on a rented number
        case compose         // starting a new conversation
        case email           // temp e-mail, code delivered
        case linePaywall     // the subscription screen, monthly selected
        // The same screen with the YEARLY plan selected. Two frames rather
        // than one because each App Store Connect subscription wants a review
        // screenshot of ITSELF being bought, and the selected row is the only
        // thing that differs — the price, the period under the CTA and the
        // trial line all follow the selection.
        case linePaywallYearly
        case lineInbox       // an owned number, with conversations
        case home            // the temp-SMS store
        case waiting         // waiting for a code
        case code            // the code arrived
        case orders
    }

    #if DEBUG
    /// `-screenshot <screen>` on the launch arguments.
    static var screen: Screen? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshot"), i + 1 < args.count else {
            return nil
        }
        return Screen(rawValue: args[i + 1])
    }

    static var isActive: Bool { screen != nil }
    #else
    static var screen: Screen? { nil }
    static var isActive: Bool { false }
    #endif
}

#if DEBUG
extension ScreenshotMode {

    /// A line that looks lived-in. Deliberately part-used: a full 200/200
    /// allowance is the least informative state a meter can be in, and an
    /// untouched inbox does not show what the product is for.
    static var sampleLine: Line {
        let now = Date()
        return Line(
            id: "sample-line",
            e164: "+14375550128",
            countryCode: "CA",
            numberType: "local",
            status: .active,
            currentPeriodStart: now.addingTimeInterval(-11 * 86_400),
            currentPeriodEnd: now.addingTimeInterval(19 * 86_400),
            graceUntil: nil,
            holdUntil: nil,
            smsAllowance: 200,
            smsUsed: 58,
            voiceAllowanceSeconds: 6_000,
            voiceUsedSeconds: 1_320,
            allowancePeriodStart: now.addingTimeInterval(-11 * 86_400),
            emergencyDisabled: true,
            createdAt: now.addingTimeInterval(-11 * 86_400),
            activatedAt: now.addingTimeInterval(-11 * 86_400),
            releasedAt: nil
        )
    }

    /// Three conversations, because the point of a rented number is that it
    /// holds history across different people — which one thread cannot show.
    static var sampleThreads: [LineThread] {
        let now = Date()
        return [
            LineThread(id: "t1", lineId: "sample-line", peerE164: "+14165550199",
                       lastMessageAt: now.addingTimeInterval(-120),
                       lastPreview: "Is the bike still available?",
                       unreadCount: 2, blocked: false,
                       createdAt: now.addingTimeInterval(-3_600)),
            LineThread(id: "t2", lineId: "sample-line", peerE164: "+15145550102",
                       lastMessageAt: now.addingTimeInterval(-2_400),
                       lastPreview: "You: Yes, 7pm 👍",
                       unreadCount: 0, blocked: false,
                       createdAt: now.addingTimeInterval(-86_400)),
            LineThread(id: "t3", lineId: "sample-line", peerE164: "+16135550144",
                       lastMessageAt: now.addingTimeInterval(-7_200),
                       lastPreview: "Sorry, running 10 min late",
                       unreadCount: 0, blocked: false,
                       createdAt: now.addingTimeInterval(-172_800)),
        ]
    }

    /// The open conversation behind the `thread` frame. Both directions,
    /// because a one-sided list does not show that this is a real two-way
    /// number rather than a receive-only inbox.
    static var sampleMessages: [LineMessage] {
        let now = Date()
        func msg(_ id: String, _ dir: LineMsgDirection, _ body: String,
                 _ ago: TimeInterval) -> LineMessage {
            LineMessage(
                id: id, threadId: "t1", lineId: "sample-line", direction: dir,
                e164From: dir == .inbound ? "+14165550199" : "+14375550128",
                e164To: dir == .inbound ? "+14375550128" : "+14165550199",
                body: body, status: .delivered, segments: 1,
                sentAt: dir == .outbound ? now.addingTimeInterval(-ago) : nil,
                receivedAt: dir == .inbound ? now.addingTimeInterval(-ago) : nil,
                createdAt: now.addingTimeInterval(-ago))
        }
        return [
            msg("m1", .inbound,  "Hi! Is the bike still available?", 900),
            msg("m2", .outbound, "It is — still has the original receipt too.", 780),
            msg("m3", .inbound,  "Could I see it tomorrow around 6?", 600),
            msg("m4", .outbound, "6 works. I'll send the address closer to the time.", 480),
            msg("m5", .inbound,  "Is the bike still available?", 120),
        ]
    }

    /// A temp-SMS order whose code has arrived — the moment the whole product
    /// exists for, and the one state the harness could never render.
    ///
    /// ⚠️ `123456` is deliberately not a plausible code. A screenshot is
    /// marketing, and a realistic-looking OTP beside a real service's logo
    /// invites the reading that it came from that service.
    static func sampleOrder(status: OrderStatus, otp: String?,
                            id: String = "sample-order",
                            serviceId: String = "whatsapp",
                            countryId: String = "us",
                            ageSeconds: TimeInterval = 74) -> ServerOrder {
        let now = Date()
        return ServerOrder(
            id: id, userId: "sample-user", serviceId: serviceId,
            countryId: countryId, smspvaId: "sample",
            smspvaNumber: "+12025550143", costCredits: 6, status: status,
            otp: otp, rawMessage: otp.map { "Your code is \($0)" },
            createdAt: now.addingTimeInterval(-ageSeconds),
            expiresAt: now.addingTimeInterval(480 - ageSeconds),
            arrivedAt: otp == nil ? nil : now.addingTimeInterval(-2),
            closedAt: nil, tier: "standard")
    }

    /// History with BOTH outcomes in it. An all-green list would be the same
    /// dishonesty as a seeded success rate — the refund line is a real part of
    /// the product and the Orders screen exists partly to show it.
    static var sampleOrderRows: [ServerOrder] {
        [
            sampleOrder(status: .received, otp: "123456", id: "o1",
                        serviceId: "whatsapp", countryId: "us", ageSeconds: 300),
            sampleOrder(status: .received, otp: "123456", id: "o2",
                        serviceId: "telegram", countryId: "gb", ageSeconds: 8_400),
            sampleOrder(status: .expired, otp: nil, id: "o3",
                        serviceId: "tiktok", countryId: "nl", ageSeconds: 92_000),
        ]
    }

    /// The temp-EMAIL line, delivered. Free tier, because that is the one a
    /// new user actually meets first.
    static var sampleEmailOrder: ServerEmailOrder {
        ServerEmailOrder(
            id: "sample-email", serviceId: "leboncoin", site: "leboncoin.fr",
            domain: "outlook.com", email: "quiet.harbor4192@outlook.com",
            costCredits: 0, status: .received, code: "123456",
            createdAt: ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(-160)),
            expiresAt: ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(1_160)))
    }
}
#endif
