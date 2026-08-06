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
        case lineStore       // pick a city
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
}
#endif
