import SwiftUI

extension View {
    /// Prices, balances, codes and phone numbers. SF Pro with monospaced
    /// DIGITS (columns line up, the rest stays proportional) and a numeric
    /// content transition so a changing value rolls instead of popping.
    /// Replaces SF Mono for money and numbers: next to SF Pro it read as
    /// terminal output (consultant report, 2026-09-24).
    func numberStyle(size: CGFloat, weight: Font.Weight = .semibold,
                     color: Color? = nil) -> some View {
        font(.system(size: size, weight: weight, design: .default))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(color ?? .primary)
    }

    /// The overhaul's one emphasis rule: ONLY the selected option carries a
    /// border. Labels on other options ("Our pick", "Best value per credit")
    /// are text tags, so two highlights never compete.
    func selectedEmphasis(_ selected: Bool, radius: CGFloat = RRadius.card,
                          color: Color) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected ? color : .clear, lineWidth: 1)
        }
    }
}
