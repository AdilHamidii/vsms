import SwiftUI

enum RIcon {
    static let home    = "house"
    static let inbox   = "tray"
    static let user    = "person"
    static let search  = "magnifyingglass"
    static let chev    = "chevron.right"
    static let chevDn  = "chevron.down"
    static let close   = "xmark"
    static let copy    = "doc.on.doc"
    static let check   = "checkmark"
    static let plus    = "plus"
    static let bolt    = "bolt.fill"
    static let coin    = "circle.hexagongrid.fill"
    static let filter  = "line.3.horizontal.decrease"
    static let refresh = "arrow.clockwise"
    static let arrow   = "arrow.right"
    static let globe   = "globe"
    static let clock   = "clock"
    static let spark   = "sparkles"
    static let gear    = "gearshape"
    static let shield  = "checkmark.shield"
    static let trash   = "trash"
    static let back    = "chevron.left"
    static let info    = "info.circle"
    static let phone   = "phone"
    static let message = "message"
    static let send    = "arrow.up"
}

struct CoinIcon: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, lineWidth: max(1, size / 13))
            Text("c")
                .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }
}
