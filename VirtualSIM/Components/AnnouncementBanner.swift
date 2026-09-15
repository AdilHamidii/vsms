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
///
/// It lives at the top of **Home** (owner decision 2026-09-15; it was on the
/// Temp tab until then). That is strictly better reach, not merely a different
/// place: `.home` is element 0 of every `launchOrder` variant BY CONSTRUCTION,
/// so Home is the first screen on EVERY cold launch, while the Temp tab is
/// only seen by people who go looking for it.
///
/// 🔴 **There is no megaphone icon, deliberately** (owner, 2026-09-15). A
/// decorative "loud" glyph on every notice makes routine news look like an
/// alarm, and then a real alarm looks like routine news. The
/// `exclamationmark.triangle.fill` survives for `isWarning` ONLY, where it
/// carries meaning rather than volume — that asymmetry is the whole point, so
/// do not "restore consistency" by giving the normal case an icon back.
struct AnnouncementBanner: View {
    @Environment(\.theme) private var theme

    let announcement: Announcement
    let onDismiss: () -> Void

    private var tint: Color { announcement.isWarning ? theme.warn : theme.ink }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Warnings only. See the type comment: volume is carried by the
            // tinted surface below, which every announcement gets.
            if announcement.isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }

            Text(announcement.text)
                .font(RFont.text(16))
                .lineSpacing(3)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(RMotion.content) { onDismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.text3)
                    // The glyph is tiny; without this the tap target is far
                    // below the 44pt minimum and the banner reads as stuck.
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss announcement"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 18)
        // A tinted FILL, not a hairline. The old 1pt border read as a hint at
        // the bottom of a busy screen; the fill makes it a surface, which is
        // what "eye-catching without shouting" costs. Opacity stays low
        // because the theme has to work in both light and dark.
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(tint.opacity(0.45), lineWidth: 1.5)
        }
    }
}
