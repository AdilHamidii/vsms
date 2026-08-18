import SwiftUI

// Four-page onboarding, each page showing the product doing its actual job on
// the same surfaces the user will meet inside the app. No abstract icon badges
// anywhere.
//
// ⚠️ THE ORDER ENCODES THE BUSINESS, AND THIS FILE HAD IT BACKWARDS UNTIL
// 2026-08-18. It led with the rented second number, which was correct for the
// three days after 2026-08-05 and was reverted on 08-08: `AppState.tab` is
// `.home` and `TabBar` reads Home · Number · eSIM · Account. So the first
// screen of the app was selling the SECOND product — a $9.99 subscription —
// while the store listing, the keywords and essentially all acquisition are
// about temp SMS. Order now: temp SMS → temp e-mail → second number → what you
// pay. The eSIM product gets no page: `app_config.esim_paused` is true, so
// nothing in that catalog is on sale, and a page selling something nobody can
// buy is worse than silence. (Read that flag, not this comment — and note
// `lines_paused`, which is a DIFFERENT product and is currently false.)
//
// ⚠️ EVERY PAGE SELLS THE SITUATION, NOT THE FEATURE. A reader has about two
// seconds per page to recognise their OWN circumstances, which is why the copy
// names them — a marketplace listing, a sign-up form that wants a number, a
// side business — rather than describing what the thing is.
//
// ⚠️ THE PAGES MUST DIFFER STRUCTURALLY, NOT JUST EVENTUALLY. Two demos that
// resolve to the same card teach a fast reader nothing. At frame zero:
//   • page 1 is a `HeroCard` — one number, one arriving message.
//   • page 2 is an ordinary `Card` holding an ADDRESS and a mail row: no flag,
//     no phone number, a subject line instead of a bubble.
//   • page 3 is a LIST — several conversations, a call, and the allowance.
//   • page 4 has no demo card at all. It is the quiet one on purpose.
//
// ⚠️ NOTHING ON THIS SCREEN MAY QUOTE A CREDIT AMOUNT. Got wrong twice, both
// times shipping to users: a `GiftCard` reading "+3 credits" survived the copy
// rewrite that was supposed to remove the promise, and shipped in 1.8 and 1.9
// while the server granted zero. Onboarding runs BEFORE sign-in, so it cannot
// read `app_config` even if we wanted it to, while the grant is a server value
// that changes without a release — it has been 0, 1, 3 and 5, and is 0 today.
//
// ⚠️ A MONEY PRICE IS A DIFFERENT CATEGORY AND IS ALLOWED — but only StoreKit's
// own localized string, never a literal. A hardcoded "$9.99" is what put $4.99
// against €5.99 on the credit ladder's top revenue product. `subs.displayPrice`
// is the same source `LineCheckoutScreen` discloses from, so the two can never
// disagree, and the row is simply omitted when StoreKit has not answered yet
// rather than guessed at.
//
// 🔴 WHAT PAGE 3 MAY CLAIM IS NARROWER THAN IT LOOKS, AND THIS IS MEASURED,
// NOT CAUTIOUS. As of 2026-08-18 the rented line can RECEIVE texts (3 of 3,
// from US/CA numbers only) and can CALL OUT (first connected call 08-18,
// France, via `voice_rates`). It CANNOT send texts — lifetime outbound is
// 1 sent against 6 failed, every cross-border attempt refused `40010`, and
// `send-line-message` now refuses them up front — and it CANNOT receive calls:
// inbound calling has never once worked and carries four open client bugs.
// So the demo shows arriving texts and an outgoing call, and the copy says
// "give it out and call back". Do not restore the outgoing-text row or write
// "it rings" until there is a row in `line_messages` / `line_calls` proving
// otherwise.
//
// ⚠️ THE REFUND PROMISE BELONGS TO CREDITS, NOT TO THE SUBSCRIPTION, which is
// why page 4 follows the two credit-paid products and never mentions the line.
// Credits come back when no code arrives; the rented line is a StoreKit
// subscription with no refund path we control.
struct OnboardingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only ever read for `displayPrice`. Injected by `AuthGate`, which puts it
    /// in the environment for every pre-sign-in screen.
    @Environment(SubscriptionStore.self) private var subs
    var onDone: () -> Void

    @State private var page = 0

    private static let pageCount = 4
    private var isLast: Bool { page == Self.pageCount - 1 }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                // A real pager, so the gesture every user already tries works
                // and page 2 is reachable from page 3. Before this there was no
                // swipe and no way back: reaching the second page was one-way,
                // by button only.
                TabView(selection: $page) {
                    DisposableCodePage(reduceMotion: reduceMotion).tag(0)
                    MailboxPage(reduceMotion: reduceMotion).tag(1)
                    OwnershipPage(reduceMotion: reduceMotion,
                                  priceText: subs.displayPrice,
                                  onReturning: finish).tag(2)
                    TermsPage().tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)
                footer
            }
        }
        // Pre-warm StoreKit so page 3 can quote the REAL localized price rather
        // than a literal. Costs nothing — it is the same fetch
        // `LineCheckoutScreen` would make a minute later, and `loadProduct()`
        // is a no-op once the product is in hand.
        .task { await subs.loadProduct() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 7) {
            BrandWordmark(size: 20)
            Spacer(minLength: 12)
            // 🔴 LABELLED "Skip", NOT "Sign in". The button did exactly this
            // before and called itself "Sign in", so the one control that
            // leaves the pitch read as the one control that commits to an
            // account. It is the escape hatch for a reinstalling subscriber and
            // for anyone who does not want to read four pages — both of whom
            // are entitled to find it on sight.
            if !isLast {
                Button(action: finish) {
                    Text("Skip")
                        .font(RFont.text(13, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(theme.chipBg, in: Capsule())
                        .contentShape(Capsule())
                }
                .pressable()
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : RMotion.content, value: isLast)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .frame(height: 44)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            pageDots
            if isLast {
                PrimaryButton(label: String(localized: "Create my account"), action: finish)
                // Used to be 11.5pt `text3` — the faintest text on the page,
                // carrying the entire promise of what happens on the next
                // screen. It is the reason someone taps, so it is legible now,
                // and it states the trade rather than just naming Apple.
                Text("One tap with Apple next. No email list, and your real number never comes into it.")
                    .font(RFont.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                PrimaryButton(label: String(localized: "Continue"), action: advance)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.pageCount, id: \.self) { i in
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
        withAnimation(reduceMotion ? nil : RMotion.panel) {
            page = min(page + 1, Self.pageCount - 1)
        }
    }

    /// Skip and the final CTA land in the same place, and that is deliberate:
    /// both mean "I am done reading", and the next screen is the same screen.
    private func finish() {
        RHaptic.select()
        onDone()
    }
}

// MARK: - Page 1 · the disposable code

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

    /// The refund promise moved to page 4, where credits are explained before
    /// they are promised back. What stays here is the shape of the deal, which
    /// is what separates this product from page 3's subscription.
    private var terms: some View {
        Card(elevation: .flat, fill: theme.chipBg) {
            VStack(spacing: 0) {
                BenefitRow(icon: RIcon.bolt, label: "Pay per number, no subscription")
                RowRule()
                BenefitRow(icon: "globe", label: "Numbers in dozens of countries, for hundreds of services")
            }
        }
    }
}

// MARK: - Page 2 · the disposable address

/// Temp e-mail had NO pre-sign-in surface at all before 2026-08-18, despite
/// being the cheapest thing in the app and the one described in CLAUDE.md as an
/// acquisition hook rather than an earner. A reader who does not want to hand
/// over a phone number at all was never told they did not have to.
private struct MailboxPage: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel("One-time address")
                    .riseIn(appeared, index: 0)

                Text("Or skip the phone\nnumber entirely.")
                    .displayType(34)
                    .lineSpacing(1)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .riseIn(appeared, index: 1)

                Text("Plenty of sign-ups only want an e-mail address. Take a throwaway one, catch the confirmation, and keep your real inbox out of it.")
                    .font(RFont.text(15))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .riseIn(appeared, index: 2)

                MailboxDemo(reduceMotion: reduceMotion)
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

    /// 🔴 "Free addresses EVERY DAY" WAS A PLURAL WE DO NOT HONOUR. The free
    /// tier is a per-user daily cap in `app_config.email_free_daily_cap`, and
    /// it is **1** — a server value that changes without a release, exactly
    /// like the credit grant, so neither the count nor the cadence may be
    /// stated here.
    ///
    /// What IS stable is which DOMAINS cost nothing: that lives in the
    /// `PRICING` map in `create-email-order`, a code constant that only moves
    /// on a deploy. So the row claims the domain, not the allowance.
    private var terms: some View {
        Card(elevation: .flat, fill: theme.chipBg) {
            VStack(spacing: 0) {
                BenefitRow(icon: "envelope",
                           label: "Some domains cost nothing at all",
                           tint: theme.live)
                RowRule()
                BenefitRow(icon: RIcon.shield, label: "Real consumer domains, not a forwarding trick")
            }
        }
    }
}

// MARK: - Page 3 · what owning a number looks like

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

                // 🔴 "and call them back" is the strong half and the only half
                // that is proven in both directions — see the header. The
                // previous copy leaned on messaging, which is the half that
                // does not work outbound.
                Text("Marketplace listings. Dating apps. A side business. Keep one number for all of it, read what arrives, and call them back from it.")
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
                // 🔴 REWRITTEN 2026-08-18 AND NARROWED TO WHAT IS MEASURED.
                // This said "exchange texts and calls with US and Canadian
                // phones", which claims outbound texting — 1 sent against 6
                // failed, and now refused up front by `send-line-message`.
                // Receiving is proven (3 of 3) and outbound calling is proven
                // (first connected call 2026-08-18). Widen this only against
                // rows in the database, not against a provider's capability
                // flag: `domestic_two_way: true` is exactly what we believed
                // before the 10DLC refusals started.
                BenefitRow(icon: "flag", label: "A Canadian number that receives texts from US and Canadian phones")
                RowRule()
                BenefitRow(icon: RIcon.phone, label: "Call out to the US, Canada and dozens more countries")
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

// MARK: - Page 4 · what you pay, and what comes back

/// The quiet page, and the only one with no demo card — which is itself the
/// structural difference from the three before it.
///
/// ⚠️ IT EXISTS TO DEFINE "CREDITS" BEFORE ANYTHING PROMISES THEM BACK. The
/// refund line used to sit on the temp-SMS page as fine print, telling a reader
/// who had never been told what a credit is that theirs would return. The
/// promise is only worth something once the noun means something.
private struct TermsPage: View {
    @Environment(\.theme) private var theme

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel("What you pay")
                    .riseIn(appeared, index: 0)

                Text("No code,\nno charge.")
                    .displayType(34)
                    .lineSpacing(1)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .riseIn(appeared, index: 1)

                // ⚠️ Describes what a credit IS and never how many you get. The
                // signup grant is a server value that has been 0, 1, 3 and 5.
                Text("Numbers and addresses are paid for with credits you buy in the app. A number that never receives its code costs you nothing — the credits go back to your balance on their own.")
                    .font(RFont.text(15))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .riseIn(appeared, index: 2)

                promises
                    .padding(.top, 24)
                    .riseIn(appeared, index: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .task { withAnimation(RMotion.content) { appeared = true } }
    }

    /// Every row here is enforced somewhere in the backend, not a sentiment:
    /// the refund on every terminal path (`expire_order_claim`, `cancel-order`,
    /// reconciled across all wallets), no analytics SDK in the project at all,
    /// and `delete-account` as an actual endpoint.
    private var promises: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel("What we promise")
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                BenefitRow(icon: "arrow.uturn.left",
                           label: "Credits come back when no code arrives",
                           tint: theme.live)
                RowRule()
                BenefitRow(icon: RIcon.shield,
                           label: "No ads, no tracking, no email list",
                           tint: theme.live)
                RowRule()
                BenefitRow(icon: "trash",
                           label: "Delete your account, and everything in it, from the app")
                    .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Page 3's demo · a line you own

/// What OWNERSHIP looks like: a conversation list, a call, and the month's
/// allowance — three things page 1's single card cannot show.
///
/// It is a list from frame zero, on purpose. The previous pair of demos were
/// structurally identical until an animation finished 2.6s in, so anyone who
/// tapped Continue early compared two copies of the same card.
///
/// Everything in it is a mock of our own UI, not data: no measured figure is
/// quoted anywhere. The allowance numbers are the product's stated inclusions
/// and must stay in step with `LineCheckoutScreen`'s bullets and the
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
    ///
    /// 🔴 EVERY ROW HERE IS SOMETHING THE PRODUCT ACTUALLY DOES. The middle row
    /// used to read "You: Yes, 7pm 👍" — an outgoing text, which is the one
    /// thing this line cannot send. It is now an outgoing CALL, which is
    /// proven, and the list still makes its point: a number that keeps a
    /// history with different people, which page 1's disposable number cannot.
    private var threads: some View {
        VStack(spacing: 0) {
            threadRow(initial: "M",
                      tint: theme.ink,
                      name: "Marketplace",
                      snippet: "Is the bike still available?",
                      stamp: "now",
                      unread: true)
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived ? 0 : -6)
            RowRule(inset: 62).opacity(arrived ? 1 : 0)
            callRow
            RowRule(inset: 62)
            threadRow(initial: "R",
                      tint: theme.text2,
                      name: "Rental viewing",
                      snippet: "Sorry, running 10 min late",
                      stamp: "1h",
                      unread: false)
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

    /// An OUTGOING call, restored on 2026-08-18 when calling first connected.
    ///
    /// It was an incoming call once, then a third conversation for the year the
    /// dialer did not exist. Outgoing rather than incoming is not a style
    /// choice: inbound calling has never worked and carries four open client
    /// bugs, so an "Incoming call" row would be the one thing on this card that
    /// has never happened for anybody.
    private var callRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.arrow.up.right.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent2)
                .frame(width: 32, height: 32)
                .background(theme.inkSoft, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text("Dana")
                    .font(RFont.text(14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Outgoing call · 4 min")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("2m")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    /// Stated as what is INCLUDED, never as a meter reading. A part-filled bar
    /// here would be inventing a usage figure for a user who has none.
    ///
    /// ⚠️ The minutes are shown again as of 2026-08-18. They were withheld
    /// while "the dialer does not exist yet" — a figure a buyer cannot spend is
    /// a promise, not a spec sheet — and calling now connects, so the reason is
    /// gone. The TEXTS figure stays because the allowance is real and inbound
    /// works; the outbound limitation is stated in the benefit list rather than
    /// here, where a bare number cannot carry it.
    /// ⚠️ TWO figures and "every month" do NOT fit on one line, and the failure
    /// is silent: with both inclusions on a single row the texts figure wrapped
    /// mid-number and rendered as "20 / 0 texts" on a 6.3" screen — a wrong
    /// number, not just an ugly one. `fixedSize` on each pair is what forbids
    /// the wrap; the caption moved to its own line because there is no width
    /// left for it on the narrowest supported device.
    private var allowance: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                // 🔴 THE "200 TEXTS" FIGURE IS GONE, and the rule that removed
                // it is the one that used to justify hiding the minutes: **a
                // figure a buyer cannot spend is a promise, not a spec sheet.**
                // It has simply reversed. Calling ships and is metered, so the
                // minutes are a real inclusion. Sending does not ship, and
                // INBOUND IS NEVER METERED — so there is no way for a buyer to
                // spend a text allowance at all, and printing one sells a
                // capability that does not exist.
                included(icon: RIcon.phone, figure: "100", unit: "minutes")
                Spacer(minLength: 0)
            }
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
        // The number and its unit are one atom. Without this the HStack is
        // free to wrap inside the figure itself.
        .fixedSize(horizontal: true, vertical: false)
    }

    private func run() async {
        livePulse = true
        if reduceMotion { arrived = true; return }
        try? await Task.sleep(nanoseconds: 900_000_000)
        withAnimation(RMotion.panel) { arrived = true }
    }
}

// MARK: - Page 1's demo · the code lands

/// A `HeroCard`, where page 3's demo is an ordinary card. That is a genuine
/// material difference — accent glow and a different fill — so the pages are
/// told apart at a glance and not only by reading them.
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

    /// Disposability, said out loud. It is the whole difference from page 3 and
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

// MARK: - Page 2's demo · the address, and what lands in it

/// Deliberately NOT a `HeroCard` and NOT a thread list: an address row and a
/// mail row, so page 2 is distinguishable from both its neighbours at frame
/// zero. See the file header's structural rule.
private struct MailboxDemo: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    @State private var arrived = false
    @State private var livePulse = false

    var body: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                head
                addressRow
                Rectangle().fill(theme.sep).frame(height: 1).padding(.top, 14)
                mailRow
            }
        }
        .task { await run() }
    }

    private var head: some View {
        HStack(spacing: 8) {
            MicroLabel("Temporary address")
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
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    /// No flag and no dial code — the two things every other demo in this file
    /// leads with. An address is the point of difference, so it gets the row a
    /// phone number gets elsewhere.
    ///
    /// The domain is a real one we sell, and the local part is nonsense on
    /// purpose: a plausible-looking human address would read as somebody's.
    private var addressRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.accent2)
            MonoText("quiet-heron-482@outlook.com", size: 15, weight: .medium, color: theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    /// Mock digits, kept out of the translatable string.
    private var codeGlyph: Text {
        Text(verbatim: "731904")
            .font(RFont.mono(12, weight: .bold))
            .foregroundStyle(theme.text2)
    }

    /// Faded in, never inserted — same reason as `LineDemo.threads`.
    private var mailRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "N")
                .font(RFont.display(14, weight: .bold))
                .foregroundStyle(theme.onInk)
                .frame(width: 32, height: 32)
                .background(theme.ink, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: "Netflix")
                        .font(RFont.text(14, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                    Text("now")
                        .font(RFont.text(11))
                        .foregroundStyle(theme.text3)
                }
                Text("Finish creating your account")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                // The code is a placeholder for the same reason `CodeDemo`'s
                // bubble uses one: a translator cannot reorder a sentence that
                // has been concatenated, and word order around the digits does
                // differ by language.
                Text("Enter this code to confirm: \(codeGlyph)")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : -6)
    }

    private func run() async {
        livePulse = true
        if reduceMotion { arrived = true; return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        withAnimation(RMotion.panel) { arrived = true }
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
