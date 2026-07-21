import SwiftUI

/// Honest, up-front notice about the one thing this product can't guarantee:
/// that a code actually arrives.
///
/// Delivery is genuinely unreliable for some services — sites like Meta's
/// actively reject numbers they recognise as temporary — and a user who
/// discovers that *after* paying reads it as a scam. Saying it before the
/// purchase (and again while they wait) costs nothing, because rerolling and
/// refunds are already free. Pairing the warning with the remedy is what keeps
/// it from reading as a disclaimer.
///
/// Two densities: `.full` on Checkout (pre-purchase, has room to explain) and
/// `.compact` on Waiting (already anxious, wants one line and a way out).
struct DeliveryNotice: View {
    @Environment(\.theme) private var theme

    enum Density { case full, compact }
    var density: Density = .full

    var body: some View {
        switch density {
        case .full:   fullNotice
        case .compact: compactNotice
        }
    }

    private var fullNotice: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.info)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.warn)
                    Text("Codes don't always arrive")
                        .font(RFont.display(15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                }

                Text("Some services block temporary numbers, so a code may never come through. If that happens you're not charged — and trying another number is free, as many times as you like.")
                    .font(RFont.text(13))
                    .tracking(-0.1)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("We're sorry for the hassle. We're actively working on improving delivery rates.")
                    .font(RFont.text(12))
                    .tracking(-0.1)
                    .foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: RIcon.info)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text3)
                .padding(.top, 1)
            Text("Some services block temporary numbers, so a code may not arrive. Trying another is free — you only pay for one that works. Sorry for the hassle; we're working on it.")
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
