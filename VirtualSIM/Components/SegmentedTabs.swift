import SwiftUI

/// The app's segmented control — Orders' Active/Past, the Number tab's
/// Messages/Calls/Number, the eSIM tab's three sections.
struct SegmentedTabs<Tag: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Tag
    let items: [(tag: Tag, label: String, count: Int?)]

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tag) { item in
                let active = selection == item.tag
                Button {
                    guard !active else { return }
                    RHaptic.select()
                    withAnimation(reduceMotion ? nil : RMotion.select) {
                        selection = item.tag
                    }
                } label: {
                    HStack(spacing: 5) {
                        // ⚠️ `LocalizedStringKey`, not the raw String.
                        // `Text(someString)` never consults the string catalog —
                        // only `Text("literal")` does — so every segment label
                        // in the app shipped English to all six locales while
                        // its translation sat unused in `Localizable.xcstrings`,
                        // invisible to a file-level "0 untranslated" audit.
                        // A caller passing DB-derived text misses the lookup and
                        // renders verbatim, which is the correct fallback.
                        Text(LocalizedStringKey(item.label))
                            .font(RFont.display(13, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(active ? theme.text : theme.text2)
                        if let n = item.count {
                            Text("\(n)")
                                .font(RFont.text(11, weight: .medium))
                                .foregroundStyle(theme.text3)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        // One shared thumb that GLIDES between segments rather
                        // than a per-segment background fading in and out. The
                        // movement is what tells the eye the segments are one
                        // control instead of three buttons.
                        if active {
                            RoundedRectangle(cornerRadius: RRadius.xs, style: .continuous)
                                .fill(theme.elev)
                                .shadow(color: theme.shadow(.raised), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "segmentThumb", in: thumb)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
    }
}
