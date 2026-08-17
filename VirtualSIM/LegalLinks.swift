import Foundation

/// Single source of truth for legal + support URLs. Update these once you
/// publish the Notion pages — they're referenced from AccountScreen and
/// SignInScreen.
enum LegalLinks {
    static let supportEmail = "adil.hamidii123@gmail.com"
    static let help    = URL(string: "https://superficial-watch-d12.notion.site/Help-3704b908b4b780fd8d39ea0fd6078efd?source=copy_link")!
    static let terms   = URL(string: "https://superficial-watch-d12.notion.site/Terms-3704b908b4b78000a931d5ea6fcc6023?source=copy_link")!
    static let privacy = URL(string: "https://superficial-watch-d12.notion.site/Privacy-Policy-3704b908b4b7801aa6fbfe1bacdaec09?source=copy_link")!
    static let refund  = URL(string: "https://superficial-watch-d12.notion.site/Refund-Policy-3704b908b4b7803dbe5cef0346e00e20?source=copy_link")!
    /// Apple's standard EULA — what the App Store metadata declares (no custom
    /// EULA is set in ASC), so the in-app link must point at the same document.
    /// Required in the subscription purchase flow by guideline 3.1.2(c).
    static let eula    = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
