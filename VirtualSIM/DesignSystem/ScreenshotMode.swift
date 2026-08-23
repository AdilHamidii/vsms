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
        case email           // temp e-mail, code delivered
        case emailStore      // temp e-mail, choosing a free domain
        case linePaywall     // the subscription screen, monthly selected
        // The same screen with the YEARLY plan selected. Two frames rather
        // than one because each App Store Connect subscription wants a review
        // screenshot of ITSELF being bought, and the selected row is the only
        // thing that differs — the price, the period under the CTA and the
        // trial line all follow the selection.
        case linePaywallYearly
        // The e-mail subscription's paywall, monthly selected. Its own group,
        // its own two App Store Connect products, and therefore its own pair
        // of review screenshots — a frame of the LINE paywall would show a
        // different price for a different subscription.
        case mailPaywall
        // The same screen with the YEARLY plan selected, for the same reason
        // `linePaywallYearly` exists: each App Store Connect subscription
        // wants a review screenshot of ITSELF being bought, and the selected
        // row is the only thing that differs — the price, the period under the
        // CTA and the trial line all follow the selection.
        case mailPaywallYearly
        case lineInbox       // an owned number, with conversations
        case home            // the temp-SMS store
        case waiting         // waiting for a code
        case code            // the code arrived
        case orders
        // The Buy credits sheet, for the credit packs' IAP review screenshots.
        // Same reason the paywall needs a pricing shim: `simctl` does not apply
        // the scheme's StoreKit configuration, so without one every row renders
        // "Unavailable" — see `IAPStore.screenshotPricing`.
        case credits
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
    ///
    /// 🔴 EVERY PREVIEW HERE IS INBOUND, AND THAT IS NOT A STYLE CHOICE. A
    /// `"You: Yes, 7pm 👍"` row lived at `t2` and rendered an OUTGOING message
    /// — a capability this product refuses at the server on every attempt
    /// (`outbound_sms_retired`, outbound SMS dropped 2026-08-18). These
    /// fixtures feed App Store screenshots, so that row was a marketing claim
    /// that we can send texts, in the same class as the listing copy that
    /// promised texts "in and out" and had to be purged. **If a fixture line
    /// starts with "You:", it is a bug.**
    static var sampleThreads: [LineThread] {
        let now = Date()
        return [
            // The lead thread is a verification code, because that is what the
            // number is bought FOR and it is the half that demonstrably works
            // (inbound 3 of 3 lifetime). It also renders the one-tap
            // "Copy 123456" affordance in `MessageBubble`.
            LineThread(id: "t1", lineId: "sample-line", peerE164: "+18885550111",
                       lastMessageAt: now.addingTimeInterval(-120),
                       lastPreview: "Your verification code is 123456",
                       unreadCount: 2, blocked: false,
                       createdAt: now.addingTimeInterval(-3_600)),
            LineThread(id: "t2", lineId: "sample-line", peerE164: "+14165550199",
                       lastMessageAt: now.addingTimeInterval(-2_400),
                       lastPreview: "Is the bike still available?",
                       unreadCount: 0, blocked: false,
                       createdAt: now.addingTimeInterval(-86_400)),
            LineThread(id: "t3", lineId: "sample-line", peerE164: "+16135550144",
                       lastMessageAt: now.addingTimeInterval(-7_200),
                       lastPreview: "Sorry, running 10 min late",
                       unreadCount: 0, blocked: false,
                       createdAt: now.addingTimeInterval(-172_800)),
        ]
    }

    /// The open conversation behind the `thread` frame — **inbound only**.
    ///
    /// 🔴 It used to alternate directions, on the reasoning that "a one-sided
    /// list does not show that this is a real two-way number". It is not a
    /// two-way number: `send-line-message` refuses every send with
    /// `outbound_sms_retired`, the composer was deleted from `ThreadScreen`,
    /// and the store pitch carries "Sending texts — Not yet". Two outgoing
    /// bubbles in an App Store screenshot were a claim the app cannot honour.
    ///
    /// What replaces them is the strongest honest pitch there is: codes
    /// arriving, each with the one-tap Copy affordance under it.
    static var sampleMessages: [LineMessage] {
        let now = Date()
        func msg(_ id: String, _ dir: LineMsgDirection, _ body: String,
                 _ ago: TimeInterval) -> LineMessage {
            LineMessage(
                id: id, threadId: "t1", lineId: "sample-line", direction: dir,
                e164From: dir == .inbound ? "+18885550111" : "+14375550128",
                e164To: dir == .inbound ? "+14375550128" : "+18885550111",
                body: body, status: .delivered, segments: 1,
                sentAt: dir == .outbound ? now.addingTimeInterval(-ago) : nil,
                receivedAt: dir == .inbound ? now.addingTimeInterval(-ago) : nil,
                createdAt: now.addingTimeInterval(-ago))
        }
        // ⚠️ `123456` / `654321` are deliberately not plausible codes, and no
        // sender is named — the same rule as `sampleOrder`. A realistic code
        // next to a real brand invites the reading that it came from that
        // brand.
        return [
            msg("m1", .inbound, "Your verification code is 123456. It expires in 10 minutes.", 900),
            msg("m2", .inbound, "New sign-in from a device we don't recognise. If this wasn't you, ignore this message.", 600),
            msg("m3", .inbound, "Your login code is 654321. Never share it with anyone.", 120),
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
            closedAt: nil, tier: "standard", provider: "5sim")
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

    /// The domain picker, which is what the e-mail line actually IS: two free
    /// consumer domains and one paid. Stock figures are realistic rather than
    /// flattering — the free tier is genuinely the scarcest inventory, and a
    /// picker showing thousands of free addresses would be a claim we cannot
    /// keep.
    ///
    /// ⚠️ icloud.com must never appear here. It was removed from `PRICING` on
    /// 2026-07-31 because handing out throwaway addresses on Apple's own
    /// consumer domain, from an app on Apple's store, is an avoidable review
    /// risk — putting it in a screenshot would reintroduce exactly that.
    static var sampleEmailDomains: [EmailDomainOption] {
        [
            EmailDomainOption(domain: "outlook.com", credits: 0, available: 128),
            EmailDomainOption(domain: "hotmail.com", credits: 0, available: 64),
            EmailDomainOption(domain: "gmail.com", credits: 1, available: 4210),
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
