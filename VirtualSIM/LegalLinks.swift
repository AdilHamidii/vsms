import Foundation

/// Single source of truth for legal + support URLs. Update these once you
/// publish the Notion pages — they're referenced from AccountScreen and
/// SignInScreen.
enum LegalLinks {
    static let supportEmail = "adil.hamidii123@gmail.com"

    /// Where the Support buttons go when the server has not said otherwise:
    /// the owner's Telegram support account, @vSMSAPP (2026-09-23).
    ///
    /// Support was a hardcoded `wa.me` link to +14375243093 from 2.9 to 2.17,
    /// and WhatsApp Business banned that account on 2026-09-23 — which
    /// dead-ended the Support button in every installed build at once, with a
    /// release as the only fix. The destination is now `app_config.support_url`
    /// (the owner's `/supportlink` bot command); this is only the fallback.
    static let supportDefault = URL(string: "https://t.me/vSMSAPP")!

    /// The only hosts a server-supplied support link may point at. Both accept
    /// a prefilled draft as `?text=`. Anything else falls back to
    /// `supportDefault`: this URL is opened on a tap, so a mistyped or hostile
    /// config value must never be able to send users somewhere arbitrary.
    /// ⚠️ The ops bot's `/supportlink` validator (`_shared/tgHandlers.ts`)
    /// applies the same rule — keep the two in step.
    static let supportAllowedHosts: Set<String> = ["t.me", "wa.me"]

    /// The first message, prefilled in the chat. Owner decision 2026-09-23:
    /// exactly this and nothing else — no build, no account id — in every
    /// locale. Deliberately not localized.
    static let supportDraft = "Hi vSMS Support"

    /// A server-supplied support link reduced to its bare
    /// `https://<host>/<path>` form, or nil when it is not acceptable: not
    /// https, a host outside `supportAllowedHosts`, credentials or a port, or
    /// no path (a bare `https://t.me` names nobody). Any query or fragment is
    /// dropped, because `supportURL` appends the draft and would otherwise
    /// carry two.
    static func validSupportBase(_ raw: String?) -> URL? {
        guard let raw,
              var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), supportAllowedHosts.contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil,
              !parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// The link every Support button opens: the last value
    /// `AppState.refreshAppStatus` stored (`PrefKey.supportURL`), else
    /// `supportDefault`, with `supportDraft` appended as `?text=`.
    ///
    /// Read at TAP time, so a value fetched this session is used this session —
    /// unlike `launch_tab` there is no layout to protect. Both hosts are https,
    /// so the link opens the app when installed and the web page otherwise,
    /// with no `LSApplicationQueriesSchemes` entry.
    static var supportURL: URL {
        let base = validSupportBase(UserDefaults.standard.string(forKey: PrefKey.supportURL))
            ?? supportDefault
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        parts.queryItems = [URLQueryItem(name: "text", value: supportDraft)]
        return parts.url ?? base
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
