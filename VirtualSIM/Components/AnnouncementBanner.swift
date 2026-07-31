import SwiftUI

/// Owner-written notice, posted from Telegram with `/announce`.
///
/// Two deliberate restraints:
///
/// * **It is never a claim the app makes.** The text is written by a person and
///   rendered verbatim — no localization, no reformatting, no inferred severity.
///   `kind` picks the colour and nothing else. That keeps it distinguishable
///   from the app's own measured statements (delivery records, balances), which
///   are held to a much stricter evidence bar.
/// * **It is dismissible, and dismissal is per-announcement.** A banner that
///   cannot be dismissed becomes noise on the primary screen; a dismissal that
///   sticks forever silently turns the channel off for the people who have
///   already engaged with it once.
struct AnnouncementBanner: View {
    @Environment(\.theme) private var theme

    let announcement: Announcement
    let onDismiss: () -> Void

    private var tint: Color { announcement.isWarning ? theme.warn : theme.ink }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: announcement.isWarning
                  ? "exclamationmark.triangle.fill" : "megaphone.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            Text(announcement.text)
                .font(RFont.text(13))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(RMotion.content) { onDismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.text3)
                    // The glyph is tiny; without this the tap target is far
                    // below the 44pt minimum and the banner reads as stuck.
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss announcement"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 12)
        .background(theme.elev, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        }
    }
}
