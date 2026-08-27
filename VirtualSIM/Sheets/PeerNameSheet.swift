import SwiftUI

/// Name a peer, phone-app style. Writes through `AppState.setContactName`,
/// which persists per device only — the server never learns these.
///
/// Presented as a small detented sheet from recents rows, the conversation
/// list and the thread header. Saving an empty field removes the name, which
/// is also the only "delete" affordance a nickname needs.
struct PeerNameSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    let e164: String
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            SheetHeader(title: "Add name")

            VStack(spacing: 14) {
                PeerAvatar(e164: e164, name: name.isEmpty ? nil : name, size: 64)
                Text(verbatim: PhoneFormat.national(e164))
                    .font(RFont.mono(15))
                    .foregroundStyle(theme.text2)
            }

            TextField("Name", text: $name)
                .font(RFont.text(17, weight: .medium))
                .textInputAutocapitalization(.words)
                .focused($focused)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(theme.chipBg, in: .rect(cornerRadius: RRadius.md))
                .padding(.horizontal, 20)

            PrimaryButton(label: name.trimmingCharacters(in: .whitespaces).isEmpty
                          && state.contactName(for: e164) != nil
                          ? "Remove name" : "Save") {
                state.setContactName(name, for: e164)
                dismiss()
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background(theme.bg)
        .onAppear {
            name = state.contactName(for: e164) ?? ""
            focused = true
        }
    }
}
