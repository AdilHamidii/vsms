import SwiftUI

/// Flag rendered as a real flag PNG (via flagcdn.com) cropped into a rounded
/// square. Falls back to the Unicode flag emoji while loading or on failure.
struct FlagImage: View {
    @Environment(\.theme) private var theme
    let country: Country
    var size: CGFloat = 32
    var radius: CGFloat = 9

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.chipBg)

            if let bundled = BundledImageStore.shared.flag(forCode: country.flagImageCode) {
                Image(uiImage: bundled)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: radius))
            } else if let url = country.flagImageURL(width: 160) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(.rect(cornerRadius: radius))
                    case .empty, .failure:
                        emojiFallback
                    @unknown default:
                        emojiFallback
                    }
                }
            } else {
                emojiFallback
            }
        }
        .frame(width: size, height: size)
    }

    private var emojiFallback: some View {
        Text(country.flag)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
    }
}

/// Same idea, circle-shaped — used in the Country picker sheet.
struct FlagCircle: View {
    @Environment(\.theme) private var theme
    let country: Country
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(theme.chipBg)

            if let bundled = BundledImageStore.shared.flag(forCode: country.flagImageCode) {
                Image(uiImage: bundled)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else if let url = country.flagImageURL(width: 160) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(.circle)
                    case .empty, .failure:
                        Text(country.flag).font(.system(size: size * 0.55))
                    @unknown default:
                        Text(country.flag).font(.system(size: size * 0.55))
                    }
                }
            } else {
                Text(country.flag).font(.system(size: size * 0.55))
            }
        }
        .frame(width: size, height: size)
    }
}
