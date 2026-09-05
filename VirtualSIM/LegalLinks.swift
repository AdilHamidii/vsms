import Foundation

/// Single source of truth for legal + support URLs. Update these once you
/// publish the Notion pages — they're referenced from AccountScreen and
/// SignInScreen.
enum LegalLinks {
    static let supportEmail = "adil.hamidii123@gmail.com"

    /// WhatsApp Business — THE support channel since 2.9 (owner decision
    /// 2026-09-05). It replaced the in-app chat, which relayed to Telegram and
    /// left a refund request unanswered for eleven days. The number is the
    /// owner's own rented vSMS line, verified with WhatsApp Business — which
    /// is also the evidence behind the Number tab saying WhatsApp works.
    static let supportWhatsAppE164 = "+14375243093"

    /// `wa.me` deep link: opens WhatsApp when installed and WhatsApp's own web
    /// page otherwise (no `LSApplicationQueriesSchemes` needed — it is https),
    /// with the first message prefilled so the owner can find the account
    /// without asking. The short id is the first 8 characters of the user id:
    /// enough to match a row, not a credential. Not localized on purpose — the
    /// owner reads it, not the user.
    static func supportWhatsApp(userId: String?) -> URL {
        let info = Bundle.main
        let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var text = "Hi vSMS support — app \(version) (\(build))"
        if let id = userId, id.count >= 8 { text += ", account \(id.prefix(8))" }
        var parts = URLComponents(string: "https://wa.me/" + supportWhatsAppE164.filter(\.isNumber))!
        parts.queryItems = [URLQueryItem(name: "text", value: text)]
        return parts.url!
    }
    static let help    = URL(string: "https://superficial-watch-d12.notion.site/Help-3704b908b4b780fd8d39ea0fd6078efd?source=copy_link")!
    static let terms   = URL(string: "https://superficial-watch-d12.notion.site/Terms-3704b908b4b78000a931d5ea6fcc6023?source=copy_link")!
    static let privacy = URL(string: "https://superficial-watch-d12.notion.site/Privacy-Policy-3704b908b4b7801aa6fbfe1bacdaec09?source=copy_link")!
    static let refund  = URL(string: "https://superficial-watch-d12.notion.site/Refund-Policy-3704b908b4b7803dbe5cef0346e00e20?source=copy_link")!
    /// Apple's standard EULA — what the App Store metadata declares (no custom
    /// EULA is set in ASC), so the in-app link must point at the same document.
    /// Required in the subscription purchase flow by guideline 3.1.2(c).
    static let eula    = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
