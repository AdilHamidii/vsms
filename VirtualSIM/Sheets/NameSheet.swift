import SwiftUI

/// Set the name Home greets the user by.
///
/// ── Why it is a sheet and not a settings row ──────────────────────────────
///
/// The greeting is the only place this name is ever shown, so the control that
/// sets it lives on the greeting. Burying it in Account would mean a user who
/// dislikes what the app calls them has to go looking for the fix in a screen
/// that never mentions it.
///
/// ── Two properties that are not obvious from the body ─────────────────────
///
/// 🔴 **The local copy is adopted only after the PATCH lands.**
/// `AppState.setDisplayName` rebuilds `profile` after the write and returns
/// false when it fails; this sheet stays OPEN on false. Dismissing on a failed
/// write would show a name that exists on this device and nowhere else — a
/// rename that looks like it worked until the next cold launch.
///
/// ⚠️ **A landed write also clears the parked Apple name**, inside
/// `setDisplayName`. That matters here because this sheet is how a user
/// overrides the name Apple handed us at sign-in, and without the clear the
/// next boot flush would put Apple's name back with no signal.
struct NameSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(Session.self) private var session

    @State private var name = ""
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    /// A name the WRITE would take AND the GREETING would then show.
    ///
    /// 🔴 Both halves are needed, and the second is the one that bit.
    /// `acceptableDisplayName` only trims and length-caps, but
    /// `AppState.greetingName(email:)` additionally refuses a value containing
    /// `@` or equal to the e-mail's local part — because
    /// `handle_new_user()` seeds `display_name` from the address and greeting
    /// somebody by their own handle reads as the app quoting a database row
    /// back at them. Gate on the first rule alone and typing your own handle
    /// SAVES: the PATCH lands, the sheet dismisses, and the eyebrow is
    /// unchanged — a rename that silently did nothing, which is the worst of
    /// the three possible outcomes because it looks like the app is broken.
    ///
    /// ⚠️ The rule is mirrored here rather than shared because `greetingName`
    /// reads the STORED profile, and this has to judge a string that has not
    /// been written yet. Keep the two in step: if `greetingName` gains a
    /// rejection, add it here in the same commit, or this sheet starts
    /// offering saves that show nothing again.
    ///
    /// ⚠️ **One rejection is deliberately NOT mirrored: the nil-e-mail case.**
    /// Since 2026-09-10 `greetingName` fails CLOSED with no address to compare
    /// against, because greeting from an unverifiable `display_name` means
    /// greeting almost everybody by their handle. Mirroring that here would
    /// refuse EVERY name whenever `session.email` is unknown — a sheet whose
    /// Save can never light up. So in that state a save really does land and
    /// really does show nothing until the e-mail is known again; that is the
    /// lesser of the two, and it is rare (an install predating the Keychain
    /// e-mail key, or a refresh payload with no user e-mail).
    private var acceptable: String? {
        guard let trimmed = AppState.acceptableDisplayName(name),
              !trimmed.contains("@") else { return nil }
        if let email = session.email,
           let localPart = email.split(separator: "@", maxSplits: 1).first,
           trimmed.compare(String(localPart), options: .caseInsensitive) == .orderedSame {
            return nil
        }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "What should we call you?")

            Text("Shown on your Home screen, nowhere else.")
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            TextField(text: $name) { Text("Your name") }
                .font(RFont.text(17, weight: .medium))
                .foregroundStyle(theme.text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { if acceptable != nil { Task { await save() } } }
                // Hard limit rather than a counter: 40 is a greeting's worth,
                // and past it the Home eyebrow wraps instead of saying more.
                // Trimming here keeps the field and the write agreeing on what
                // will actually be stored.
                .onChange(of: name) { _, new in
                    if new.count > 40 { name = String(new.prefix(40)) }
                    if failed { failed = false }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(theme.chipBg, in: .rect(cornerRadius: RRadius.md))
                .padding(.horizontal, 16)

            if failed {
                Text("Couldn't save your name. Try again.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.fail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }

            // HIDDEN while there is nothing to save, never disabled: a greyed
            // button still advertises an action, and the empty field already
            // says what is missing. Same rule as `LineScreen.actionFAB`.
            if acceptable != nil {
                PrimaryButton(label: String(localized: "Save"), disabled: saving) {
                    Task { await save() }
                }
                .padding(.horizontal, 16)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background(theme.bg)
        .onAppear {
            // Prefilled with the name we would GREET them by, not the raw
            // column: `greetingName` returns nil when the stored value is the
            // e-mail handle `handle_new_user()` seeded, and prefilling the
            // field with that address would invite the user to accept it.
            name = state.greetingName(email: session.email) ?? ""
            focused = true
        }
    }

    private func save() async {
        guard let value = acceptable else { return }
        // `session.userId` is non-nil for anything rendered behind `AuthGate`,
        // but the write needs it and there is no honest guess — so a missing
        // id surfaces as the same failure line rather than a silent no-op.
        guard let userId = session.userId else {
            failed = true
            return
        }
        saving = true
        let ok = await state.setDisplayName(value, userId: userId,
                                            using: ProfileAPI(client: api))
        saving = false
        if ok {
            RHaptic.success()
            dismiss()
        } else {
            failed = true
        }
    }
}
