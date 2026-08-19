import SwiftUI

/// What a FREE e-mail domain actually costs THIS account right now.
///
/// 🔴 ONE definition, read by both surfaces that render it. `HomeScreen` and
/// `EmailDomainSheet` used to resolve it independently — and Home simply did
/// not resolve it at all: it printed "Free" whenever `domain.isFree`, ignoring
/// both the subscription entitlement and the fact that the free address is one
/// per account FOR LIFE. So a user who had already spent theirs was invited in
/// with "Get email address · Free", tapped it, and was refused with
/// `subscription_required` straight into a paywall. The app was advertising
/// something it had already decided not to give them.
///
/// Only ever meaningful for a free domain: gmail.com is priced in credits and
/// was part of neither the old daily allowance nor the subscription.
///
/// ⚠️ This is a UI HINT, exactly like the two inputs it derives from. The
/// authority is `begin_email_order` in SQL — the device can be offline,
/// restored from a backup, or simply wrong. It decides what the screen SAYS,
/// never what the server ALLOWS.
///
/// ⚠️ Lives in its own file on purpose: it needs `SwiftUI` for
/// `LocalizedStringKey`, and importing SwiftUI into `MailSubscriptionStore.swift`
/// makes `Transaction` ambiguous between SwiftUI and StoreKit.
enum FreeEmailAccess {
    /// The user subscribes — addresses come with it.
    case included
    /// The one lifetime free address is still unspent.
    case free
    /// Spent, and now behind the paywall.
    case subscription

    static func resolve(isEntitled: Bool, hasUsedFree: Bool) -> FreeEmailAccess {
        if isEntitled { return .included }
        return hasUsedFree ? .subscription : .free
    }

    /// The word on the price tag.
    var label: LocalizedStringKey {
        switch self {
        case .included:     return "Included"
        case .free:         return "Free"
        case .subscription: return "Subscription"
        }
    }

    /// The same three words as a plain `String`, for call sites that take one
    /// (`PrimaryButton.sub`). ⚠️ A `String` does NOT reach the string catalog
    /// on its own — `String(localized:)` is what puts it there.
    var subtitle: String {
        switch self {
        case .included:     return String(localized: "Included")
        case .free:         return String(localized: "Free")
        case .subscription: return String(localized: "Subscription")
        }
    }

    /// Green is this app's semantic "this costs you nothing". It must not be
    /// spent on the one state where the address is behind a paywall.
    var readsAsFree: Bool { self != .subscription }
}
