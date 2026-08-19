import SwiftUI

/// The app's ONLY error surface — which is exactly why it could not keep
/// auto-dismissing everything.
///
/// Every error vanished after 4 seconds, with no action button. So "Couldn't
/// place your order", "We couldn't complete that. Your credits are unchanged"
/// and a failed account deletion each got four seconds of a user's attention
/// and then erased themselves, leaving a screen that looked fine and a user
/// who had no idea whether they had been charged. No error anywhere in the app
/// was recoverable in place, and the ones that mattered most were the ones
/// most likely to be missed — they arrive at the end of a tap the user was
/// already looking away from.
///
/// Two classes now:
///
/// - **informational** — "that country is out of stock", "pick another
///   domain", "you can cancel shortly". Nothing was spent, the next step is
///   obvious and is on screen already. Auto-dismisses, as before.
/// - **blocking** — anything that ended, or might have ended, a PAID action.
///   Persists until dismissed and carries an action.
///
/// **The default is blocking**, and that direction is deliberate: a
/// misclassified informational error costs one tap, while a misclassified paid
/// failure is the bug being fixed here.
struct ErrorBanner: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    /// A true retry for whatever failed. Optional so existing call sites keep
    /// compiling; when absent the banner still offers the universally correct
    /// action for a money-path failure — go and look at what actually
    /// happened.
    var retry: (label: String, action: () -> Void)? = nil

    var body: some View {
        // `APIError.appleSignInCanceled` maps to the empty string, so a user
        // dismissing Apple's own sheet used to raise an empty banner: an icon,
        // a close button and no text.
        // A screenshot run drives the UI from synthetic state, so its network
        // calls legitimately fail — the email frame came back with "Please
        // sign in again to continue." across the top of the product. The
        // banner is honest about a real session and pure noise here, and this
        // compiles away in Release.
        if let entry = state.lastBannerError, !entry.message.isEmpty, !ScreenshotMode.isActive {
            let message = entry.message
            let blocking = Self.isBlocking(entry)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: blocking
                          ? "exclamationmark.triangle.fill"
                          : "exclamationmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(blocking ? theme.fail : theme.warn)
                    Text(message)
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(RMotion.content) { state.lastError = nil }
                    } label: {
                        Image(systemName: RIcon.close)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.text2)
                            .padding(6)
                            .background(theme.chipBg, in: .circle)
                    }
                    .pressable()
                    .accessibilityLabel(Text("Dismiss"))
                }

                if blocking {
                    HStack(spacing: 8) {
                        action
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous)
                    .strokeBorder((blocking ? theme.fail : theme.warn).opacity(0.30),
                                  lineWidth: 1)
            )
            .shadow(color: theme.shadow(.lifted), radius: RElevation.lifted.radius,
                    x: 0, y: RElevation.lifted.y)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: message) {
                // An informational error still clears itself; a blocking one
                // waits for the user, because the whole point is that they see
                // it. `id: message` means a NEW message restarts the timer
                // rather than inheriting the previous one's.
                guard !blocking else {
                    RHaptic.warn()
                    return
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if state.lastError == message {
                    withAnimation(RMotion.content) { state.lastError = nil }
                }
            }
        }
    }

    /// The recovery offered on a blocking error.
    ///
    /// With no `retry` supplied, the honest generic action is not "try again"
    /// — retrying is exactly what a user must not do blind when money may have
    /// moved. It is to go and read what actually happened, which Orders shows
    /// for SMS, e-mail and eSIM, including the refund line on a failed one.
    ///
    /// ⚠️ **The rented line is NOT in Orders** — it is the fourth product line
    /// and this comment predates it. Sending a line failure there is a dead
    /// end: the user taps "Check your orders", lands on a list that says
    /// nothing about the number they just failed to rent, and is left with no
    /// account of what happened. Seen for real on a `line_unavailable` refusal
    /// (the Telnyx float guard) — the message was right and the button was
    /// wrong. On the Number tab there is nowhere better to send them, so the
    /// banner offers only its dismiss, which is the honest answer rather than
    /// a confident wrong one.
    @ViewBuilder
    private var action: some View {
        if let retry {
            actionButton(label: retry.label, icon: RIcon.refresh) {
                state.lastError = nil
                retry.action()
            }
        } else if state.tab != .line {
            actionButton(label: String(localized: "Check your orders"),
                         icon: RIcon.inbox) {
                state.lastError = nil
                state.flow = .orders
            }
        }
    }

    private func actionButton(label: String, icon: String,
                              _ run: @escaping () -> Void) -> some View {
        Button {
            RHaptic.select()
            withAnimation(RMotion.content) { run() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(label))
                    .font(RFont.text(13, weight: .semibold))
            }
            .foregroundStyle(theme.accent2)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(theme.inkSoft, in: .capsule)
        }
        .pressable()
    }

    // MARK: - Classification

    /// Error codes whose message means "that option is unavailable, pick
    /// another" — nothing was spent, and the alternative is already on screen.
    ///
    /// Everything NOT in this list is treated as blocking, including every
    /// money path, every auth failure, and any HTTP status we do not recognise.
    private static let informationalCodes = [
        "no_numbers_available", "route_unavailable", "premium_unavailable",
        "real_sim_required", "smspva_error", "provider_unreachable",
        "smspva_unreachable", "cancel_too_early", "not_cancelable",
        "esim_out_of_stock", "plan_unavailable", "email_out_of_stock",
        "domain_unavailable", "email_unsupported_service", "free_limit_reached",
        "unknown_service", "order_not_found", "unknown_order",
        // Same family as `line_exists`: a limit the user can clear themselves,
        // not a fault. Blocking treatment would offer "Check your orders",
        // which is not where lines live.
        "lines_paused", "line_exists", "line_limit_reached", "number_taken",
        // The line's SEND failures. Blocking treatment renders "Check your
        // orders", whose action does `flow = nil` + `tab = .orders` — so a
        // failed text closed the conversation, DISCARDED the composer draft,
        // and landed the user on a tab that contains no messages at all.
        //
        // `message_send_failed` is the one that actually bites: the other three
        // are pre-empted by `ThreadScreen.blockReason`, which disables the
        // composer, so they only fire on a stale-cache race. A transient
        // provider fault is the ordinary case, and it is the one that was
        // throwing people out of the thread.
        "allowance_exhausted", "line_suspended", "recipient_blocked",
        "message_send_failed",
    ]

    /// 🔴 CLASSIFY ON THE CODE, NEVER ON THE RENDERED SENTENCE.
    ///
    /// This used to build a `Set<String>` by rendering every code above with a
    /// body of `{"error":"<code>"}` and then testing the live message for
    /// membership. That is exact string equality, so it collapses the moment a
    /// message interpolates anything the server sent — and one does:
    /// `cancel_too_early` carrying `retry_after_seconds` renders "Hang on. You
    /// can cancel in 42 seconds…", which was in no set, so the friendliest
    /// message in the app was shown as a BLOCKING error — warning haptic, red
    /// triangle, no auto-dismiss, and a "Check your orders" action — on the
    /// waiting screen, which carries the highest cancel pressure anywhere in
    /// the product. `AppState.BannerError` now carries the code alongside the
    /// sentence so the comparison is on identity rather than on prose.
    ///
    /// A nil code stays BLOCKING. That covers our own locally-composed strings
    /// and every transport failure, and it keeps the failure mode of an
    /// out-of-date list at "this persists when it needn't" rather than "this
    /// vanishes when it mustn't".
    private static func isBlocking(_ entry: AppState.BannerError) -> Bool {
        guard let code = entry.code else { return true }
        return !informationalCodes.contains(code)
    }
}
