import SwiftUI

// Two-page onboarding, each page showing the product doing its actual job on
// the same surfaces the user will meet inside the app. No abstract icon badges
// anywhere.
//
// ⚠️ THE ORDER ENCODES THE BUSINESS, AND THE BUSINESS CHANGED ON 2026-08-05:
// rented second numbers first, temp SMS second, temp e-mail as a hook, eSIM
// eventually. Page 1 used to be the temp-SMS pitch ("Get the code, keep your
// number"), which described the app's SECOND product as though it were the
// whole thing — the first screen of the app contradicting its own front tab.
//
// Page 1 is now the rented line, and its demo is deliberately a TWO-WAY thread:
// an inbound message and a reply. That is the entire difference between this
// product and the other three, all of which are receive-only and disposable,
// and a one-sided demo would look identical to page 2.
//
// Page 2 keeps temp SMS AND carries the refund promise, rather than splitting
// them across a third page. Activation here is a single-session event — median
// signup → first order is 123 seconds — so every extra page is real friction
// paid by every user forever.
//
// ⚠️ THE REFUND PROMISE BELONGS TO TEMP SMS ONLY, which is why it sits on page
// 2 and not page 1. Credits come back when no code arrives; the rented line is
// a StoreKit subscription with no refund path we control. Moving that sentence
// onto the line's page would promise something Apple, not us, decides.
//
// Page 2 USED TO PROMISE WELCOME CREDITS ("you'll find 3 free credits
// waiting"), and this header used to warn that the number must match
// `handle_new_user()` or it becomes "a promise the server doesn't keep". That
// is exactly what happened: the signup grant was disabled on 2026-08-03
// (app_config.signup_bonus_credits = 0) and the screen kept promising three.
//
// ⚠️ THAT FIX WAS ONLY HALF-APPLIED, and the missing half shipped in 1.8 and
// 1.9. The prose above was rewritten, but the CARD was not: a `GiftCard`
// rendering a hardcoded "+3 credits / Covers your first number" stayed on this
// page. So when the signup grant was set to 0 permanently on 2026-08-04 (owner
// decision — the product is paid, and a user who has paid actually uses the
// number), the very first screen of the app promised three credits and the
// server granted none. Fixed here by deleting the card, not by re-numbering it.
//
// THE RULE, since this has now been got wrong twice: NOTHING on this screen may
// quote a credit amount. Onboarding runs BEFORE sign-in, so it cannot read
// `app_config` even if we wanted it to, while the grant is a server value that
// changes without a release — it has been 0, 1, 3 and 5. Any number here is a
// promise the server has not agreed to keep.
//
// What replaces it holds at ANY grant amount, including zero: a number that
// never delivers a code is refunded in full. That is enforced on every terminal
// path (expire_order_claim, cancel-order) and was verified end-to-end in the
// ledger, so it is a claim we can always keep.
struct OnboardingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onDone: () -> Void

    @State private var page = 0

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 16)
                Group {
                    if page == 0 {
                        VStack(spacing: 30) {
                            LineDemo(reduceMotion: reduceMotion)
                                .padding(.horizontal, 22)
                            lineCopyBlock
                        }
                        .transition(pageTransition)
                    } else {
                        VStack(spacing: 30) {
                            InboxDemo(reduceMotion: reduceMotion)
                                .padding(.horizontal, 22)
                            copyBlock
                        }
                        .transition(pageTransition)
                    }
                }
                Spacer(minLength: 16)
                footer
            }
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal: .move(edge: .leading).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 7) {
            BrandWordmark(size: 20)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .frame(height: 44)
    }

    /// Page 1 — the rented line. No price: the store screen holds that back
    /// until the user has chosen a city and their own digits, and quoting
    /// $9.99 before sign-in would front-load the one number this screen has no
    /// context for.
    private var lineCopyBlock: some View {
        copy(
            title: "A second number\nthat's yours.",
            body: "Rent a real phone number and text and call from it right here — while your own number stays private."
        )
    }

    /// Page 2 — temp SMS, and the refund promise that belongs to it.
    ///
    /// The promise holds at ANY signup-grant amount including zero, which is
    /// what makes it safe on a pre-sign-in screen: a number that never delivers
    /// a code is refunded in full, enforced on every terminal path.
    private var copyBlock: some View {
        copy(
            title: "Or just need\none code?",
            body: "Grab a throwaway number for a single verification. No code, no charge — your credits go straight back, every time."
        )
    }

    private func copy(title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            Text(title)
                .font(RFont.display(30, weight: .bold))
                .tracking(-0.8)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text)
            Text(body)
                .font(RFont.text(15))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
        }
        .padding(.horizontal, 24)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            // Per page, because the two claims belong to two different
            // products. "Refunded instantly" is a credits promise and is only
            // true of temp SMS; the rented line is a subscription, where the
            // honest reassurance is that cancelling is one tap in Settings and
            // not something we gate. One line covering both would be wrong on
            // whichever page the reader is looking at.
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.live)
                Text(page == 0
                     ? "No ads or tracking. Cancel anytime from your Apple ID settings."
                     : "No ads or tracking. No code, no charge — refunded instantly.")
                    .font(RFont.text(12.5))
                    .foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            pageDots
            if page == 0 {
                PrimaryButton(label: "Continue", action: {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85)) {
                        page = 1
                    }
                })
            } else {
                PrimaryButton(label: "Get started", action: onDone)
                Text("Sign in with Apple next — that's the only detail we ask for.")
                    .font(RFont.text(11.5))
                    .foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 2)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(page == i ? theme.text : theme.sep)
                    .frame(width: page == i ? 16 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: page)
        .accessibilityHidden(true)
    }
}

// MARK: - Rented line demo

// Page 1's card. Deliberately a TWO-WAY thread — an inbound message and a reply
// leaving the card — because that is the only thing separating this product
// from the other three, which are all receive-only and disposable. A one-sided
// demo here would be indistinguishable from `InboxDemo` on the next page.
//
// No price and no credit amount, per the rule in this file's header: onboarding
// runs before sign-in, so it can assert only what holds regardless of what the
// server is configured to do. The price is shown on `LineCheckoutScreen`, after
// the user has picked a city and their own digits.
private struct LineDemo: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    // 0 = number only, 1 = incoming typing, 2 = incoming, 3 = reply sent.
    @State private var phase = 0
    @State private var livePulse = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                numberRow
                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.vertical, 18)
                thread
            }
            .padding(20)
        }
        .task { await run() }
    }

    private var cardHeader: some View {
        HStack {
            Text("YOUR SECOND NUMBER")
                .font(RFont.text(11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.text3)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.live)
                    .frame(width: 6, height: 6)
                    .opacity(livePulse ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: livePulse)
                Text("Yours")
                    .font(RFont.text(11, weight: .semibold))
                    .foregroundStyle(theme.live)
            }
        }
    }

    private var numberRow: some View {
        HStack(spacing: 10) {
            Text("🇨🇦").font(.system(size: 26))
            MonoText("+1 (437) 555-0128", size: 20, weight: .medium, color: theme.text)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase >= 2 {
                incoming.transition(.move(edge: .bottom).combined(with: .opacity))
            } else if phase == 1 {
                TypingDots().transition(.opacity)
            }
            if phase >= 3 {
                outgoing.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Hold the full height from the start so the card does not grow under
        // the copy as the thread fills in.
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
    }

    private var incoming: some View {
        Text("Hey — are we still on for Friday?")
            .font(RFont.text(14))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(theme.elev2, in: .rect(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(theme.sep, lineWidth: 0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The reply is tinted `ink` and sits on the trailing edge — the standard
    /// "this one is from you" grammar, and the whole point of the page.
    private var outgoing: some View {
        Text("Yes, 7pm 👍")
            .font(RFont.text(14))
            .foregroundStyle(theme.onInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(theme.ink, in: .rect(cornerRadius: 15))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func run() async {
        livePulse = true
        if reduceMotion { phase = 3; return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        withAnimation(.easeInOut(duration: 0.25)) { phase = 1 }
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { phase = 2 }
        try? await Task.sleep(nanoseconds: 900_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { phase = 3 }
    }
}

// MARK: - Live "code arrives" demo

private struct InboxDemo: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    // 0 = number only, 1 = sender typing, 2 = code delivered.
    @State private var phase = 0
    @State private var livePulse = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                numberRow
                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.vertical, 18)
                thread
            }
            .padding(20)
        }
        .task { await run() }
    }

    private var cardHeader: some View {
        HStack {
            Text("YOUR TEMPORARY NUMBER")
                .font(RFont.text(11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.text3)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.live)
                    .frame(width: 6, height: 6)
                    .opacity(livePulse ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: livePulse)
                Text("Live")
                    .font(RFont.text(11, weight: .semibold))
                    .foregroundStyle(theme.live)
            }
        }
    }

    private var numberRow: some View {
        HStack(spacing: 10) {
            Text("🇫🇷").font(.system(size: 26))
            MonoText("+33 6 12 34 56 78", size: 21, weight: .medium, color: theme.text)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    private var thread: some View {
        Group {
            if phase >= 2 {
                smsBubble
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if phase == 1 {
                TypingDots()
                    .transition(.opacity)
            } else {
                // Hold the vertical space so the card doesn't jump on delivery.
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
    }

    private var smsBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Instagram")
                .font(RFont.text(12, weight: .semibold))
                .foregroundStyle(theme.text2)
            (
                Text("Your code is ").font(RFont.text(15)).foregroundStyle(theme.text)
                + Text("4827").font(RFont.mono(16, weight: .bold)).foregroundStyle(theme.live)
                + Text(" — don't share it.").font(RFont.text(15)).foregroundStyle(theme.text)
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elev2, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.sep, lineWidth: 0.5)
        )
    }

    private func run() async {
        livePulse = true
        if reduceMotion { phase = 2; return }
        try? await Task.sleep(nanoseconds: 650_000_000)
        withAnimation(.easeInOut(duration: 0.25)) { phase = 1 }
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { phase = 2 }
    }
}

private struct TypingDots: View {
    @Environment(\.theme) private var theme
    @State private var active = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(theme.text3)
                    .frame(width: 7, height: 7)
                    .opacity(active == i ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(theme.elev2, in: .rect(cornerRadius: 16))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.easeInOut(duration: 0.2)) { active = (active + 1) % 3 }
            }
        }
    }
}
