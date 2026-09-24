import SwiftUI

/// One spacing scale for the whole app. Before the 2026-09 overhaul every
/// padding was hand-set per call site (borrowing `RRadius` numbers), so two
/// cards that should line up did not. New code uses these; old screens adopt
/// them as they are rebuilt.
enum RSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Horizontal screen gutter.
    static let gutter: CGFloat = 16
}
