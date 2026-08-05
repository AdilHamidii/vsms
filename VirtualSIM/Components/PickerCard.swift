import SwiftUI

/// A full-width option in a small, mutually-exclusive set — a card that states
/// what it buys, not a chip that states its own name.
///
/// ── What this replaced, and why a chip was the wrong shape ────────────────
///
/// The Standard / Real SIM choice is the most expensive decision on the
/// checkout screen: it is the only control there that changes what the user
/// pays. It was rendered as two ~60pt chips crammed into the trailing edge of a
/// receipt row, and **the explanation of what Real SIM actually buys existed
/// only as an `.accessibilityHint`** — a sentence no sighted user has ever
/// seen. So the expensive choice was the smallest thing on screen and the only
/// one with its reasoning hidden.
///
/// A chip can carry a name and a price. It cannot carry a reason, and a tier
/// picker with no stated reason is a surcharge the user discovers rather than
/// chooses.
///
/// (`PickerCard`, the two-up service/country tile this file used to hold, is
/// gone with Home's duplicate picker layer — Home's hero now carries tappable
/// `ReceiptRow`s, the same component Checkout uses, so the two screens read as
/// one object instead of three stacked decision surfaces.)
struct OptionCard: View {
    @Environment(\.theme) private var theme

    let title: LocalizedStringKey
    /// The price of THIS option, always shown. A picker that reveals the
    /// difference only after selection makes the surcharge a surprise.
    var price: LocalizedStringKey? = nil
    /// What choosing this actually buys — one sentence, in the user's terms.
    /// Required, because the absence of this is the bug the component exists
    /// to fix.
    let detail: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard !selected else { return }
            RHaptic.select()
            withAnimation(RMotion.select) { action() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // A radio mark, not a checkmark: these are exclusive, and a
                // checkbox glyph on an exclusive choice reads as "you may have
                // both".
                ZStack {
                    Circle()
                        .strokeBorder(selected ? theme.ink : theme.sepStrong,
                                      lineWidth: selected ? 6 : 1.5)
                        .frame(width: 20, height: 20)
                }
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(RFont.display(16, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 0)
                        if let price {
                            Text(price)
                                .font(RFont.mono(14, weight: .medium))
                                .foregroundStyle(selected ? theme.accent2 : theme.text2)
                        }
                    }
                    Text(detail)
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .fill(selected ? theme.inkSoft.opacity(0.45) : theme.elev)
            }
            .overlay {
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .strokeBorder(selected ? theme.ink.opacity(0.55) : theme.sep,
                                  lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: RRadius.md))
        }
        .pressable(0.985)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The credits glyph in a `ReceiptRow`'s leading slot.
///
/// Shared rather than re-declared per screen: it used to be a `private struct`
/// inside CheckoutScreen, and Home now renders the same Cost row, so a second
/// private copy is exactly the duplicated-constant shape this repo keeps
/// getting bitten by. `ReceiptIconBox` cannot stand in for it — the app's coin
/// mark is `CoinIcon`, not an SF Symbol, and CreditPill uses the same glyph.
struct CoinIconBox: View {
    @Environment(\.theme) private var theme
    var body: some View {
        CoinIcon(size: 14, color: theme.text2)
            .frame(width: 32, height: 32)
            .background(theme.chipBg, in: .rect(cornerRadius: 9))
    }
}

/// Compatibility shim — call-sites that have a Country use FlagImage directly.
/// This wrapper exists so an emoji string can still be passed in places that
/// don't have a full Country reference (none right now, kept for safety).
struct FlagBox: View {
    @Environment(\.theme) private var theme
    let flag: String
    var size: CGFloat = 32
    var radius: CGFloat = 9

    var body: some View {
        Text(flag)
            .font(.system(size: size * 0.56))
            .frame(width: size, height: size)
            .background(theme.chipBg, in: .rect(cornerRadius: radius))
    }
}
