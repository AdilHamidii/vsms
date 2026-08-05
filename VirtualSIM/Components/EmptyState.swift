import SwiftUI

/// The screen for the first hour of ownership — so it gets designed, not
/// skipped.
///
/// The app reimplemented this five times, and every copy was the same three
/// things: a 30pt grey glyph, a grey title, a grey sentence. An empty inbox is
/// what a user who just paid $9.99 actually looks at, and "No messages yet /
/// Give it out and see" gives them nothing to do about it.
///
/// Two rules the old copies broke:
///  - an empty state that has an obvious next action MUST offer it; a dead end
///    is only honest when there genuinely is nothing to do,
///  - it must distinguish "nothing here yet" from "we could not load it".
///    Those look identical when both render as grey text, and one of them is a
///    bug the user could work around by retrying.
struct EmptyState: View {
    @Environment(\.theme) private var theme

    var icon: String
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    /// Semantic tint — `theme.fail` for a genuine failure, accent for an empty
    /// but healthy state. Silence about which one this is was the old bug.
    var tint: Color? = nil
    var primary: (label: String, action: () -> Void)? = nil
    var secondary: (label: String, action: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill((tint ?? theme.ink).opacity(0.10))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(tint ?? theme.accent2)
            }

            Text(title)
                .font(RFont.display(18, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
                .padding(.top, 18)

            Text(message)
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 12)

            if let primary {
                PrimaryButton(label: primary.label, action: primary.action)
                    .padding(.top, 20)
            }
            if let secondary {
                GhostButton(label: secondary.label, action: secondary.action)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
    }
}
