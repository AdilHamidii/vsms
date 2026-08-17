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
// ⚠️ PAGE 1 SELLS THE SITUATION, NOT THE FEATURE. It used to open with "A
// second number that's yours." — a sentence that says WHAT the thing is to a
// reader who has not yet been given a reason to want one. Page 1 has about two
// seconds to make someone recognise their OWN circumstances, so it now names
// them: a marketplace listing, a dating app, a side business, a contractor who
// needs a callback number. "Give out a number, not your number."
//
// ⚠️ THE TWO PAGES MUST DIFFER STRUCTURALLY, NOT JUST EVENTUALLY. Both demos
// used to be the identical card — header row, number row, divider, one message
// bubble — and diverged only when the second page's animation reached its final
// phase about 2.6s in. A user tapping Continue after one second saw the same
// card twice and learned nothing. So:
//   • page 1 shows what OWNERSHIP looks like — a conversation LIST with two
//     threads, a call, and the monthly allowance. Different at frame zero.
//   • page 2 keeps the single disposable-code card, and is a `HeroCard`, a
//     visibly different material from page 1's list.
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
// ⚠️ NOTHING ON THIS SCREEN MAY QUOTE A CREDIT AMOUNT. Got wrong twice, both
// times shipping to users: a `GiftCard` reading "+3 credits" survived the copy
// rewrite that was supposed to remove the promise, and shipped in 1.8 and 1.9
// while the server granted zero. Onboarding runs BEFORE sign-in, so it cannot
// read `app_config` even if we wanted it to, while the grant is a server value
// that changes without a release — it has been 0, 1, 3 and 5.
//
// ⚠️ A MONEY PRICE IS A DIFFERENT CATEGORY AND IS ALLOWED — but only StoreKit's
// own localized string, never a literal. A hardcoded "$9.99" is what put $4.99
// against €5.99 on the credit ladder's top revenue product. `subs.displayPrice`
// is the same source `LineCheckoutScreen` discloses from, so the two can never
// disagree, and the row is simply omitted when StoreKit has not answered yet
// rather than guessed at. Stating it here at all is deliberate: nothing before
// sign-in told anyone this app sells a subscription.
struct OnboardingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only ever read for `displayPrice`. Injected by `AuthGate`, which puts it
    /// in the environment for every pre-sign-in screen.
    @Environment(SubscriptionStore.self) private var subs
    var onDone: () -> Void

    @State private var page = 0

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Group {
                    if page == 0 {
                        OwnershipPage(reduceMotion: reduceMotion,
                                      priceText: subs.displayPrice,
                                      onReturning: goToSignIn)
                            .transition(pageTransition)
                    } else {
                        DisposableCodePage(reduceMotion: reduceMotion)
                            .transition(pageTransition)
                    }
                }
                .frame(maxHeight: .infinity)
                footer
            }
        }
        // Pre-warm StoreKit so page 1 can quote the REAL localized price rather
        // than a literal. Costs nothing — it is the same fetch
        // `LineCheckoutScreen` would make a minute later, and `loadProduct()`
        // is a no-op once the product is in hand.
        .task { await subs.loadProduct() }
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal: .move(edge: .leading).combined(with: .opacity))
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 7) {
            BrandWordmark(size: 20)
            Spacer(minLength: 12)
            // The returning-user escape hatch. A reinstalling subscriber has no
            // interest in a pitch for something they already pay for, and
            // before this there was no way past onboarding except reading it.
            Button(action: goToSignIn) {
                Text("Sign in")
                    .font(RFont.text(13, weight: .semibold))
                    .foregroundStyle(theme.accent2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.chipBg, in: Capsule())
                    .contentShape(Capsule())
            }
            .pressable()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .frame(height: 44)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            pageDots
            if page == 0 {
                PrimaryButton(label: "Continue", action: advance)
            } else {
                // "Get started" named nothing. The next tap after this one is
                // choosing a city and then actual digits, so the button says so.
                PrimaryButton(label: "Choose my number", action: {
                    RHaptic.select()
                    onDone()
                })
                // Used to be 11.5pt `text3` — the faintest text on the page,
                // carrying the entire promise of what happens on the next
                // screen. It is the reason someone taps, so it is legible now,
                // and it states the trade rather than just naming Apple.
                Text("One tap with Apple next. No password to make, no email list, and your real number never comes into it.")
                    .font(RFont.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(page == i ? theme.text : theme.sepStrong)
                    .frame(width: page == i ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : RMotion.select, value: page)
        .accessibilityHidden(true)
    }

    private func advance() {
        RHaptic.select()
        withAnimation(reduceMotion ? nil : RMotion.panel) { page = 1 }
    }

    private func goToSignIn() {
        RHaptic.select()
        onDone()
    }
}

// MARK: - Page 1 · what owning a number looks like

private struct OwnershipPage: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool
    /// StoreKit's localized price, or nil while it is still unknown. Never a
    /// literal — see the file header.
    let priceText: String?
    let onReturning: () -> Void

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Matches `LineStoreScreen`'s own kicker, so the category the
                // reader meets here is the one they land in after signing in.
                MicroLabel("Second number")
                    .riseIn(appeared, index: 0)

                Text("Give out a number,\nnot your number.")
                    .displayType(34)
                    .lineSpacing(1)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .riseIn(appeared, index: 1)

                // "a number to call back on" also implied voice. The situations
                // are the persuasive part, not the medium — every one of these
                // works over text.
                Text("Marketplace listings. Dating apps. A side business. The buyer who wants to message you about the sofa. None of them need the number your family uses.")
                    .font(RFont.text(15))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .riseIn(appeared, index: 2)

                LineDemo(reduceMotion: reduceMotion)
                    .padding(.top, 24)
                    .riseIn(appeared, index: 3)

                terms
                    .padding(.top, 18)
                    .riseIn(appeared, index: 4)

                returningRow
                    .padding(.top, 12)
                    .riseIn(appeared, index: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .task { withAnimation(RMotion.content) { appeared = true } }
    }

    /// The three things a reader is entitled to know before they are asked to
    /// sign in: what it costs, where the number is, and what we do with them.
    ///
    /// ⚠️ "Canadian numbers" belongs HERE, not in a trust footer. The demo card
    /// shows a 🇨🇦 flag and a +1 number, which a reader in Berlin or Bogotá will
    /// read as "a number local to me" — and the store only corrects that after
    /// they have signed in and picked a city. Saying it on the same screen as
    /// the flag is the whole point.
    private var terms: some View {
        Card(elevation: .flat, fill: theme.chipBg) {
            VStack(spacing: 0) {
                if let priceText {
                    BenefitRow(icon: "creditcard",
                               figure: priceText,
                               label: "a month, cancel anytime")
                } else {
                    BenefitRow(icon: "creditcard",
                               label: "A monthly subscription, cancel anytime")
                }
                RowRule()
                // ⚠️ Rewritten 2026-08-18 with the pivot. It said the number
                // "exchanges texts and calls with US and Canadian phones",
                // which sold SENDING — dropped product-wide, because it is the
                // one capability needing carrier registration (10DLC) and
                // lifetime outbound is 1 sent against 6 failed.
                //
                // What replaces it is the two things that are true and were
                // both under-sold: it RECEIVES, and it calls OUT to a priced
                // list of destinations. "worldwide" is deliberately not
                // claimed — `voice_rates` carries 50 enabled destinations and
                // 49 explicit refusals, so the honest word is the count.
                BenefitRow(icon: "flag", label: "Canadian numbers that receive US and Canadian texts and call out to 50+ countries")
                RowRule()
                BenefitRow(icon: RIcon.shield,
                           label: "No ads, no tracking, no email list",
                           tint: theme.live)
            }
        }
    }

    /// The Restore path, stated as what actually restores things.
    ///
    /// A "Restore purchases" button here would be theatre: the server is the
    /// authority on whether a line exists (`my_line`), and that read needs an
    /// account. Signing in with the same Apple ID IS the restore, so it says
    /// that instead of offering a button that could only ever say "sign in
    /// first".
    private var returningRow: some View {
        Button(action: onReturning) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent2)
                    .frame(width: 32, height: 32)
                    .background(theme.inkSoft, in: RoundedRectangle(cornerRadius: RRadius.xs, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already have a number?")
                        .font(RFont.text(14, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text("Sign in with the same Apple ID. Nothing lives on this phone.")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.elev, in: RoundedRectangle(cornerRadius: RRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: RRadius.md, style: .continuous))
        }
        .pressable()
    }
}

// MARK: - Page 2 · the disposable code

private struct DisposableCodePage: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel("One-time code")
                    .riseIn(appeared, index: 0)

                Text("Verify once.\nThen throw it away.")
                    .displayType(34)
                    .lineSpacing(1)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .riseIn(appeared, index: 1)

                Text("Some things want a phone number once and never again. Take a throwaway number for that one code, read it here, and let it go.")
                    .font(RFont.text(15))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .riseIn(appeared, index: 2)

                CodeDemo(reduceMotion: reduceMotion)
                    .padding(.top, 24)
                    .riseIn(appeared, index: 3)

                terms
                    .padding(.top, 18)
                    .riseIn(appeared, index: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .task { withAnimation(RMotion.content) { appeared = true } }
    }

    /// The refund promise holds at ANY signup-grant amount including zero,
    /// which is what makes it safe on a pre-sign-in screen: a number that never
    /// delivers a code is refunded in full, enforced on every terminal path
    /// (`expire_order_claim`, `cancel-order`) and verified in the ledger. No
    /// amount is quoted, only the guarantee.
    private var terms: some View {
        Card(elevation: .flat, fill: theme.chipBg) {
            VStack(spacing: 0) {
                BenefitRow(icon: "arrow.uturn.left",
                           label: "No code, no charge. Your credits come straight back",
                           tint: theme.live)
                RowRule()
                BenefitRow(icon: RIcon.bolt, label: "Pay per number, no subscription")
            }
        }
    }
}

// MARK: - Page 1's demo · a line you own

/// What OWNERSHIP looks like: a conversation list, a call, and the month's
/// allowance — three things page 2's single card cannot show.
///
/// It is a list from frame zero, on purpose. The previous pair of demos were
/// structurally identical until an animation finished 2.6s in, so anyone who
/// tapped Continue early compared two copies of the same card.
///
/// Everything in it is a mock of our own UI, not data: no measured figure is
/// quoted anywhere. The two allowance numbers are the product's stated
/// inclusions and must stay in step with `LineCheckoutScreen`'s bullets and the
/// `sms_allowance` / `voice_allowance_seconds` schema defaults.
private struct LineDemo: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    @State private var arrived = false
    @State private var livePulse = false

    var body: some View {
        Card(elevation: .lifted) {
            VStack(alignment: .leading, spacing: 0) {
                head
                numberRow
                rule.padding(.top, 14)
                threads
                rule
                allowance
            }
        }
        .task { await run() }
    }

    private var rule: some View {
        Rectangle().fill(theme.sep).frame(height: 1)
    }

    private var head: some View {
        HStack(spacing: 8) {
            MicroLabel("Your second number")
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.live)
                    .frame(width: 6, height: 6)
                    .opacity(livePulse ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: livePulse)
                Text("Yours")
                    .font(RFont.text(11, weight: .semibold))
                    .foregroundStyle(theme.live)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    private var numberRow: some View {
        HStack(spacing: 10) {
            Text(verbatim: "🇨🇦").font(.system(size: 24))
            MonoText("+1 (437) 555-0128", size: 21, weight: .medium, color: theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    /// ⚠️ The arriving row is ALWAYS rendered and merely faded in, never
    /// conditionally inserted. Inserting it would grow the card by a row's
    /// height a second after the page settles, shoving everything below it —
    /// the exact jump the old demos held blank space to avoid.
    private var threads: some View {
        VStack(spacing: 0) {
            // ⚠️ The ARRIVING row is a verification code, because receiving
            // codes is what this product is now sold as. It used to be a
            // marketplace question, with a second row reading "You: Yes, 7pm
            // 👍" — a rendered OUTBOUND message, i.e. the demo card
            // demonstrated the one capability that was dropped on 2026-08-18.
            threadRow(initial: "#",
                      tint: theme.ink,
                      name: "Verification",
                      snippet: "Your code is 483920",
                      stamp: "now",
                      unread: true)
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived ? 0 : -6)
            RowRule(inset: 62).opacity(arrived ? 1 : 0)
            threadRow(initial: "M",
                      tint: theme.text2,
                      name: "Marketplace",
                      snippet: "Is the bike still available?",
                      stamp: "2m",
                      unread: false)
            RowRule(inset: 62)
            callRow
        }
    }

    private func threadRow(initial: String,
                           tint: Color,
                           name: LocalizedStringKey,
                           snippet: LocalizedStringKey,
                           stamp: LocalizedStringKey,
                           unread: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: initial)
                .font(RFont.display(14, weight: .bold))
                .foregroundStyle(unread ? theme.onInk : theme.text2)
                .frame(width: 32, height: 32)
                .background(unread ? tint : theme.chipBg, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(RFont.text(14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(snippet)
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(stamp)
                    .font(RFont.text(11))
                    .foregroundStyle(theme.text3)
                if unread {
                    Circle().fill(theme.ink).frame(width: 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    /// An INCOMING CALL, restored 2026-08-18.
    ///
    /// It was one originally, then became a third conversation while calling
    /// was unreachable, and stayed one afterwards for a design reason — three
    /// conversations read as a list where two read as a coincidence. That
    /// reason is now outweighed: with sending dropped, three chat rows sell a
    /// two-way messenger this product is not. Two inbound texts plus a call is
    /// the actual shape of the thing.
    private var callRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.arrow.down.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text2)
                .frame(width: 32, height: 32)
                .background(theme.chipBg, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text("Incoming call")
                    .font(RFont.text(14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Answered right here in the app")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("1h")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    /// Stated as what is INCLUDED, never as a meter reading. A part-filled bar
    /// here would be inventing a usage figure for a user who has none.
    private var allowance: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            // ⚠️ This showed "200 texts" and the comment below argued that the
            // 100 minutes were withheld because the dialer did not exist yet:
            // **a figure a buyer cannot spend is a promise, not a spec sheet.**
            // That rule now cuts the other way. Calling ships; sending does
            // not, and inbound is never metered — so the texts figure is the
            // unspendable one and the minutes are the real inclusion.
            included(icon: RIcon.phone, figure: "100", unit: "minutes")
            Spacer(minLength: 0)
            Text("every month")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func included(icon: String, figure: String, unit: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent2)
            Text(verbatim: figure)
                .font(RFont.display(17, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(theme.text)
                .monospacedDigit()
            Text(unit)
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
        }
    }

    private func run() async {
        livePulse = true
        if reduceMotion { arrived = true; return }
        try? await Task.sleep(nanoseconds: 900_000_000)
        withAnimation(RMotion.panel) { arrived = true }
    }
}

// MARK: - Page 2's demo · the code lands

/// A `HeroCard`, where page 1's demo is an ordinary card. That is a genuine
/// material difference — accent glow and a different fill — so the two pages
/// are told apart at a glance and not only by reading them.
private struct CodeDemo: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    // 0 = number only, 1 = sender typing, 2 = code delivered.
    @State private var phase = 0
    @State private var livePulse = false

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 0) {
                head
                numberRow
                Rectangle().fill(theme.sep).frame(height: 1)
                    .padding(.vertical, 16)
                thread
                expiry.padding(.top, 12)
            }
            .padding(20)
        }
        .task { await run() }
    }

    private var head: some View {
        HStack(spacing: 8) {
            MicroLabel("Temporary number")
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.live)
                    .frame(width: 6, height: 6)
                    .opacity(livePulse ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: livePulse)
                Text("Live")
                    .font(RFont.text(11, weight: .semibold))
                    .foregroundStyle(theme.live)
            }
        }
    }

    private var numberRow: some View {
        HStack(spacing: 10) {
            Text(verbatim: "🇫🇷").font(.system(size: 24))
            MonoText("+33 6 12 34 56 78", size: 21, weight: .medium, color: theme.text)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
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
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
    }

    /// The code itself, so the sentence around it stays a single string.
    private var codeGlyph: Text {
        Text(verbatim: "4827")
            .font(RFont.mono(17, weight: .bold))
            .foregroundStyle(theme.live)
    }

    private var smsBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "Instagram")
                .font(RFont.text(12, weight: .semibold))
                .foregroundStyle(theme.text2)
            // ONE catalog entry with a placeholder, not three `Text`s added
            // together. Concatenation split the sentence into fragments a
            // translator could not reorder — and word order around the code
            // genuinely differs by language. (`+` on `Text` is also deprecated
            // in iOS 26.)
            Text("Your code is \(codeGlyph). Don't share it.")
                .font(RFont.text(15))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elev2, in: RoundedRectangle(cornerRadius: RRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                .stroke(theme.sep, lineWidth: 0.5)
        )
    }

    /// Disposability, said out loud. It is the whole difference from page 1 and
    /// was previously left for the reader to infer from the word "temporary".
    private var expiry: some View {
        HStack(spacing: 7) {
            Image(systemName: RIcon.clock)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text3)
            Text("Yours for the length of one verification, then gone.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func run() async {
        livePulse = true
        if reduceMotion { phase = 2; return }
        try? await Task.sleep(nanoseconds: 650_000_000)
        withAnimation(RMotion.content) { phase = 1 }
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        withAnimation(RMotion.panel) { phase = 2 }
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
        .background(theme.elev2, in: RoundedRectangle(cornerRadius: RRadius.md, style: .continuous))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.easeInOut(duration: 0.2)) { active = (active + 1) % 3 }
            }
        }
    }
}
