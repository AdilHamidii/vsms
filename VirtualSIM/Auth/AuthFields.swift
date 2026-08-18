import SwiftUI

/// The app's first text fields outside a search box.
///
/// There was **no `SecureField` anywhere in this project** before email
/// sign-in, and exactly one extracted field component (`SheetSearchField`),
/// which carries sheet-specific chrome. These two are the same visual
/// treatment factored for forms, so the auth screens do not each grow their
/// own.
///
/// ⚠️ THE `textContentType` VALUES ARE THE FEATURE, not decoration. They are
/// what makes iOS offer a saved password, propose a strong new one, and — for
/// `.oneTimeCode` — surface the emailed code above the keyboard so the user
/// never leaves the app to read it. Getting them wrong costs nothing at build
/// time and everything at the keyboard.
struct AuthTextField: View {
    @Environment(\.theme) private var theme

    let placeholder: LocalizedStringKey
    @Binding var text: String
    var contentType: UITextContentType? = .emailAddress
    var keyboard: UIKeyboardType = .emailAddress
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(RFont.text(16))
            .foregroundStyle(theme.text)
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .focused($focused)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(theme.chipBg, in: RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous)
                    .stroke(focused ? theme.ink.opacity(0.55) : theme.sep, lineWidth: focused ? 1.5 : 1)
            )
            .animation(RMotion.select, value: focused)
    }

    /// Lets a parent drive focus without owning the styling.
    func focusBinding(_ binding: FocusState<Bool>.Binding) -> some View {
        self.focused(binding)
    }
}

/// Password entry, with a reveal toggle.
///
/// The eye is not a nicety: password rules are invisible while typing, and a
/// user who cannot see what they typed retries blind against an error that
/// says only "that doesn't match".
struct AuthSecureField: View {
    @Environment(\.theme) private var theme

    let placeholder: LocalizedStringKey
    @Binding var text: String
    /// `.password` when signing in, `.newPassword` when creating one — the
    /// second is what asks iOS to *suggest* a strong password rather than
    /// offer an existing one.
    var contentType: UITextContentType = .password
    var submitLabel: SubmitLabel = .go
    var onSubmit: () -> Void = {}

    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .font(RFont.text(16))
            .foregroundStyle(theme.text)
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .focused($focused)

            Button {
                revealed.toggle()
                RHaptic.select()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.text3)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide password" : "Show password")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(theme.chipBg, in: RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous)
                .stroke(focused ? theme.ink.opacity(0.55) : theme.sep, lineWidth: focused ? 1.5 : 1)
        )
        .animation(RMotion.select, value: focused)
    }
}

/// The inline error line every auth screen uses.
///
/// Deliberately NOT `ErrorBanner`: that reads `AppState`, which does not exist
/// above `ContentView`, and a banner floating over a form is the wrong shape
/// for "this field is wrong". Matches what `SignInScreen` already did.
struct AuthErrorLine: View {
    @Environment(\.theme) private var theme
    let message: String?

    var body: some View {
        Group {
            if let message, !message.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 1)
                    Text(verbatim: message)
                        .font(RFont.text(13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.fail)
                .transition(.opacity)
            }
        }
        .animation(RMotion.content, value: message)
    }
}

/// Header shared by every auth screen: the wordmark, and a back control on
/// anything that is not the first screen.
struct AuthHeader: View {
    @Environment(\.theme) private var theme
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 34, height: 34)
                        .background(theme.chipBg, in: .circle)
                        .contentShape(.circle)
                }
                .pressable(0.9)
                .accessibilityLabel("Back")
            }
            BrandWordmark(size: 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .frame(height: 44)
    }
}

/// Is this plausibly an address? Deliberately permissive.
///
/// The server is the authority (`email_address_invalid` comes back from
/// GoTrue), and an over-strict client regex rejecting a valid address is a
/// bug the user cannot work around — they cannot edit our regex, and they do
/// own that mailbox. This only catches the obvious typo before a round trip.
func looksLikeEmail(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
    let domain = t[t.index(after: at)...]
    return !domain.isEmpty && domain.contains(".") && !domain.hasSuffix(".")
        && !t.contains(" ") && t.filter { $0 == "@" }.count == 1
}
