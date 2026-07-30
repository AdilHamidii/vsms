import SwiftUI

/// Pick the mail domain for a temporary address.
///
/// The email analogue of `CountrySheet`: the service is fixed, the domain
/// varies. Stock is live and per (service, domain) — measured 2026-07-30,
/// hotmail.com had 1,028 available for google.com and TWO for discord.com — so
/// an out-of-stock option is rendered as unbuyable rather than hidden. Hiding it
/// would make the free tier look like it does not exist, when in fact it is
/// simply empty right now.
struct EmailDomainSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (EmailDomainOption) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose an email domain")
            if state.isLoadingEmailDomains && state.emailDomains.isEmpty {
                loading
            } else if state.emailDomains.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(theme.bg)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular).tint(theme.text2)
            Text("Checking availability")
                .font(RFont.text(13)).foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var empty: some View {
        Text("Couldn't check availability. Please try again.")
            .font(RFont.text(14))
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.text2)
            .padding(.horizontal, 32).padding(.vertical, 36)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.emailDomains) { option in
                    row(option)
                    if option.id != state.emailDomains.last?.id {
                        Rectangle().fill(theme.sep).frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                }
            }
            .background(theme.elev, in: .rect(cornerRadius: 22))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func row(_ option: EmailDomainOption) -> some View {
        Button {
            onPick(option)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // verbatim: a mail domain is a brand, not a translatable
                    // string, and "gmail.com" must never become "Google Mail".
                    Text(verbatim: option.displayName)
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(option.inStock ? theme.text : theme.text2)
                    Text(option.inStock
                         ? String(localized: "Available now")
                         : String(localized: "Out of stock right now"))
                        .font(RFont.text(12))
                        .foregroundStyle(option.inStock ? theme.text2 : theme.text3)
                }
                Spacer(minLength: 0)
                priceTag(option)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!option.inStock)
    }

    @ViewBuilder
    private func priceTag(_ option: EmailDomainOption) -> some View {
        if option.isFree {
            Text("Free")
                .font(RFont.text(12, weight: .semibold))
                .foregroundStyle(option.inStock ? theme.live : theme.text3)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(option.inStock ? theme.liveSoft : theme.chipBg,
                            in: .capsule)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(option.credits)")
                    .font(RFont.display(15, weight: .semibold))
                    .foregroundStyle(option.inStock ? theme.text : theme.text3)
                Text("cr")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.text2)
            }
        }
    }
}
