import SwiftUI

/// A segmented control whose selection capsule GLIDES between segments
/// (matched geometry, spec §3a). The system `Picker(.segmented)` cannot take
/// the overhaul's tokens or this motion, so this is the one custom control on
/// the My number tab: the store's country choice and the subscriber's
/// Messages · Calls · Number.
///
/// Neutral by the one-green rule: an `elev` capsule on a `chipBg` track, no
/// accent, no shadow. 44pt tall including the track.
struct CapsuleSegmentedControl<Tag: Hashable, Label: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selection: Tag
    let tags: [Tag]
    @ViewBuilder let label: (Tag, Bool) -> Label

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tags, id: \.self) { tag in
                let active = tag == selection
                Button {
                    guard !active else { return }
                    RHaptic.select()
                    withAnimation(RMotion.unlessReduced(RMotion.standard, reduceMotion)) {
                        selection = tag
                    }
                } label: {
                    label(tag, active)
                        .font(RFont.text(14, weight: .semibold))
                        .foregroundStyle(active ? theme.text : theme.text2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if active {
                                Capsule()
                                    .fill(theme.elev)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(theme.chipBg, in: .capsule)
    }
}
