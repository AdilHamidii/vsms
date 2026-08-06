import SwiftUI

/// The one search field the picker sheets share.
///
/// It lived inline inside `ServiceSheet` and nowhere else, so `CountrySheet` —
/// a flat list of every country in the catalog, behind three sort chips — had
/// no way to search at all. You could search 468 services by name and not
/// search 69 countries. Extracting the field is the whole fix, and it means the
/// two sheets can no longer drift into two different search affordances.
///
/// Two things it adds over the copy it replaces:
///  - a **clear** button. Without one the only way out of a query that matched
///    nothing was to delete it character by character, which is why the empty
///    state also offers a reset.
///  - a **focus ring**. The field sat on `chipBg`, the same fill as the chips
///    directly under it, so nothing on screen indicated the keyboard was aimed
///    at it.
struct SheetSearchField: View {
    @Environment(\.theme) private var theme

    var placeholder: LocalizedStringKey
    @Binding var text: String

    @FocusState private var focused: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: RIcon.search)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(focused ? theme.accent2 : theme.text2)

            TextField(placeholder, text: $text)
                .font(RFont.text(16))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                    RHaptic.select()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.text3)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 6)
        .padding(.vertical, 10)
        .background(theme.chipBg, in: shape)
        .overlay {
            shape.strokeBorder(focused ? theme.ink.opacity(0.5) : .clear, lineWidth: 1.5)
        }
        .animation(RMotion.select, value: focused)
        .animation(RMotion.select, value: text.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}
