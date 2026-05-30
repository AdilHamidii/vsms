import SwiftUI

struct ServiceLogo: View {
    let service: Service
    var size: CGFloat = 40
    var radius: CGFloat = 10

    @State private var sourceIndex = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(service.tint)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .inset(by: 0.25)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )

            let sources = service.logoURLs
            if sourceIndex < sources.count {
                AsyncImage(url: sources[sourceIndex], transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(size * 0.16)
                            .background(.white, in: .rect(cornerRadius: radius))
                            .clipShape(.rect(cornerRadius: radius))
                    case .empty:
                        Color.clear
                    case .failure:
                        Color.clear
                            .task { sourceIndex += 1 }
                    @unknown default:
                        Color.clear
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var fallback: some View {
        if let icon = service.icon, !icon.isEmpty {
            Image(systemName: icon)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            Text(service.glyph)
                .font(.system(size: size * 0.45, weight: .bold, design: .default))
                .tracking(-0.5)
                .foregroundStyle(.white)
        }
    }
}
