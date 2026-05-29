import Foundation

/// Single source of truth for legal + support URLs. Update these once you
/// publish the Notion pages — they're referenced from AccountScreen and
/// SignInScreen.
enum LegalLinks {
    static let supportEmail = "support@example.com"
    static let help    = URL(string: "https://example.notion.site/vsim-otp-help")!
    static let terms   = URL(string: "https://example.notion.site/vsim-otp-terms")!
    static let privacy = URL(string: "https://example.notion.site/vsim-otp-privacy")!
    static let refund  = URL(string: "https://example.notion.site/vsim-otp-refund")!
}
