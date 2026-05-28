import SwiftUI

struct ServiceLogo: View {
    let service: Service
    var size: CGFloat = 40
    var radius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(service.tint)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .inset(by: 0.25)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Text(service.glyph)
                    .font(.system(size: size * 0.45, weight: .bold, design: .default))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}
