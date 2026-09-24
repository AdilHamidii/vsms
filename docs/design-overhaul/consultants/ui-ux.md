# UI/UX conversion consultant — report 1 (2026-09-24)

Standing consultant for the `design-overhaul` branch. To re-create it in a new
session: brief a subagent as a senior iOS UI/UX + conversion designer, give it
this file, the psychology report beside it and the product facts in CLAUDE.md,
and ask for cited, specific recommendations. [E] = evidence/cited, [O] = opinion.

## Top five
1. "MOST POPULAR" on credits.12 is false. Production, 90 days to 2026-09-24:
   credits.5 50 sold / 34 users, credits.12 36 / 25, credits.8 17 / 14,
   credits.30 12 / 9, credits.60 3 / 2 (re-verified by the main session). Apple
   5.6 / 2.3.1 misleading marketing.
2. The line paywall's dominant "$3.99" is against the letter of 3.1.2: Apple's
   rejection template says the billed amount must be the most conspicuous pricing
   element and intro pricing subordinate (https://developer.apple.com/forums/thread/807082).
   Approved 5× so far; pushing it harder raises risk.
3. On Ways in, the line is often the cheaper honest answer (WhatsApp/US = 24
   credits = an $8.99 pack at 0 balance vs $3.99 first month, line proven for
   WhatsApp). The comparison screen is the strongest line funnel.
4. Refunds mean more credits never buy more tries; the truthful upsell is a
   better-band country (price predicts delivery) or "enough for 2 codes".
5. Biggest activation lever: sign-in before any use. Apple 5.1.1(v). Deferred
   sign-in is the #1 owner question.

## Structure critique
- Keep "Verify" as the tab name (names the job, ASO token `verify`), with the
  screen's first line "Get a code for an app"; check German fits at largest
  Dynamic Type.
- Ways in adds a tap: recommended card's button goes straight to country; a
  "Recent" row for returning users skips Ways in (country still their pick).
- Best pick = a fixed owner-approved rule table; reason states a property, never
  "most likely to work".
- Subscriber Verify: pinned "Your number +1 … · Copy" strip; "Use your number ·
  included" first on Ways in for compatible services.
- Credits: balance pill on Verify (opens packs); Wallet at top of Account with
  ledger (refunds green "+6"); refund rows in Activity; never on My number.
- Four tabs right. Native `TabView` (Liquid Glass on 26, standard bar on 18,
  labels guaranteed); in-progress via `tabViewBottomAccessory` on 26,
  `safeAreaInset` ResumeBar on 18.

## Visual directions
- **A "Ledger" (recommended)**: calm, exact, bank-like (Cash App/Revolut/Wallet).
  Near-black base, surfaces #16171A / #1E1F23, 1px hairlines white 8%. Green for
  primary actions only; semantic success/refund mint, amber for Medium/Low, red
  almost never. SF Pro Display Bold 34/28 titles, SF Pro Text 17 body; all numbers
  `.monospacedDigit()` + `.contentTransition(.numericText())`, NOT SF Mono. 20pt
  continuous cards, 14pt row groups, 56pt capsule CTAs, one elevation, no shadows.
  Glass only on nav/controls layer (tab bar, accessory, sticky CTA tray, sheet
  headers); iOS 18 fallback `.bar`/`.regularMaterial`. One spring (0.35/0.85);
  matched-geometry logo flight grid → Ways in → waiting; honour Reduce Motion /
  Transparency.
- **B "Native"**: inset-grouped system lists, StoreKit views. Cheapest, trustworthy,
  weak brand, constrains comparison layouts.
- **C "Signal"**: bright, rounded, bouncy. Rejected: playful reads as scammy in a
  distrusted category.
- **Recommendation: A on B's bones** — native TabView/lists/sheets/nav, Ledger skin
  on cards, numbers, paywalls. Consistent with onboarding's dark card vocabulary.
  Accent picker may stay but never recolours semantic success/refund.

## Screen by screen
- **Splash**: wordmark + existing truthful progress bar only.
- **Verify**: large title "What do you want to verify?"; search under it, not
  autofocused; 8 logo tiles (2×4) ordered by storefront order volume, tap =
  `commitServicePick`; category chips row (Social · Dating · Shopping · Money ·
  Games · Work); drop "More"; "Search N apps" with N from catalog; Recent row;
  credits pill; nothing preselected.
- **Ways in** ("Ways to verify WhatsApp"): vertical stack; recommended card first
  and expanded (1pt accent border, "Best pick for WhatsApp" accent text, one-line
  factual reason, 3 check rows, own filled button); others compact rows (glyph ·
  name · price line · chevron); unavailable ways visible, greyed, with reason.
  Price grammar: "Free · your 1 free address" or "1 credit"; one-time "4–24
  credits, depends on country · refunded if no code" (real range, never "from 4");
  line "$3.99 first month, then $5.99/mo" from StoreKit. "You have 5 credits" under
  one-time row.
- **Country picker**: sections High / Medium / Low / No published rate; row = flag
  · name · band word + meter · credits; sort by pool rate then price; search
  pinned; band legend (hidden under `delivery_metrics_hidden`); Low row → inline
  note "Another country usually works better".
- **Checkout**: medium-detent sheet: service + country, price, "balance after",
  refund line, better-odds steer; 10-second explainer gates first order; if short,
  CTA "Add credits · then get number" → packs → back with CTA live + success
  haptic; never auto-place the order.
- **Credit paywall**: keep context row; dim packs that don't cover ("Not enough
  for this order"); preselect smallest covering; storefront `priceFormatStyle`
  per-credit (fix "0,60 US$ / cr"); replace false "Most popular"; sticky "Buy 20
  credits · $8.99" + "Credits never expire · refunded if no code arrives".
- **Waiting**: three real steps (number + Copy ✓ reserved / paste & request /
  code appears here); real elapsed timer + "Refunded automatically in 7:12 if no
  code arrives" (real deadline); reroll shows its real hold countdown; Live
  Activity / Dynamic Island (highest-leverage new surface) [O].
- **Code received**: 56pt code with numericText roll-in + success haptic; Copy
  (auto-copy is an owner question); Done; quiet keep-number upsell below.
- **Failure/recovery**: "No code this time. 6 credits are back." then "Try this
  instead": named High-band country as one-tap re-order → free e-mail (if
  accepted) → your own number (if proven) → same country fresh number; the
  past-tense 9-in-10 line.
- **Subscription paywall**: full-screen after digit pick; picked number on top
  ("Reserved for you" only if real); ✓ capability rows + uncollapsed ✗ US/PR
  texting + 911 row; monthly row "$5.99/month" at plan size with "$3.99 your first
  month · new subscribers" beneath, smaller, accent; yearly a plain second row;
  sticky "Start for $3.99" + "Cancel anytime in Settings".
- **My number**: store "A number that stays yours" + "Has received codes from"
  logos (WhatsApp, TikTok, DoorDash); country + sending notice → number → paywall.
  Subscribers: inbox and calls.
- **Activity**: In progress / Past, SMS + e-mail merged; outcomes in words ("No
  code · 6 credits refunded" in green); empty state with Verify button.
- **Account**: Wallet, Subscriptions (manage links), Invite, Support (Telegram),
  Appearance, Delete account (existing warnings).

## Conversion patterns (risk: review / ratings-refund)
Evidence: hard paywall 10.7% vs freemium 2.1% (RevenueCat SOSA 2026); paywall
after a value moment 2.1× trials (Adapty 2026); stripped paywall beat comparison
chart +111% (Superwall, vendor); Apple 5.6.4 lists refund requests and negative
reviews as quality signals.
- Smallest covering pack preselected; next-up "Best value per credit" (true) — L / M.
- Line: keep monthly preselected (yearly preselect wrong for renters) — L / H if yearly.
- Full-screen line paywall after digit pick; credits sheet at balance < price;
  optional test of a dismissible post-onboarding number offer (X immediate) — L / M.
- Strong hierarchy, secondary AA-contrast — L / L.
- Real limited offer = intro eligibility, no timer; keep $5.99 dominant — M / L.
- Sticky CTA with price — L / L.
- Exit offer once per session on credit-sheet dismiss (smallest covering pack or
  free e-mail) — L / L.
- Recovery after Apple-sheet cancel on line: "Just need one code? One-time number"
  — L / L.
- Per-period reframing of yearly only subordinate — M / L.
- iOS 18 win-back offers for lapsed renters (owner floor question) — L / L.
- Retention Messaging API in the cancel flow — L / L.
- No close-button delay — M / M. Social proof only server-owned true counts; never
  stars at 8 ratings.
Excluded: fake countdowns, fake scarcity, fake "was $X", buried $5.99 renewal,
toggle trials, promised outcomes, "extra credits for retries", untrue badges.
Microcopy: name outcomes; refund first on failure; never "number" without
"one-time" / "your own"; delivery past tense only; band words not %; no suppliers.
States: skeletons for catalog; decode error never "check your connection"; every
empty state has one action. Haptics: selection on picks, success on code and
credits added, no error buzz on delivery failure.

## Owner decisions raised
1. Deferred sign-in. 2. Best-pick table: own number as best pick where one-time is
pricier (WhatsApp/US)? 3. Money equivalent beside credits? 4. "Most popular" fix.
5. $3.99 win-back for lapsed renters — floor for new only or everyone? 6. Test a
post-onboarding full-screen number offer? 7. Auto-copy code? 8. Live Activity?
9. Retention Messaging API? 10. Line paywall price layout ($5.99 dominant vs $3.99
dominant). 11. Keep the six-colour accent picker?

## Sources
Apple Review Guidelines https://developer.apple.com/app-store/review/guidelines/ ·
3.1.2 billed amount https://developer.apple.com/forums/thread/807082 · HIG Tab bars
https://developer.apple.com/design/human-interface-guidelines/tab-bars · HIG
Materials https://developer.apple.com/design/human-interface-guidelines/materials ·
HIG Haptics https://developer.apple.com/design/human-interface-guidelines/playing-haptics ·
Intro offers https://developer.apple.com/documentation/storekit/implementing-introductory-offers-in-your-app ·
Win-back https://developer.apple.com/news/?id=8utnewzk · Retention Messaging
https://www.revenuecat.com/blog/engineering/apple-retention-messaging-api ·
RevenueCat SOSA 2026 https://www.revenuecat.com/state-of-subscription-apps ·
Adapty 2026 https://adapty.io/blog/high-performing-paywall-2026/ · Superwall
https://superwall.com/blog/the-paywall-tactics-behind-usd100k-month-apps ·
NN/g icons https://www.nngroup.com/articles/icon-usability/ · Baymard perceived
security https://baymard.com/blog/perceived-security-of-payment-form · Buell &
Norton https://www.hbs.edu/faculty/Pages/item.aspx?num=40158 · Chernev 2015
https://chernev.com/wp-content/uploads/2017/02/ChoiceOverload_JCP_2015.pdf

## Spec review 1 (2026-09-24) — applied to the spec
1. Rule order: free e-mail first (if free address left and not phone-only), then
   measured-line → own number, else one-time number. 2. Country sections High ·
   Medium · No published rate · Low. 3. Explainer third behaviour branches by band;
   relocation overrides the "not over a live flow" rule → update CLAUDE.md.
4. Line paywall needs EULA, Privacy, Restore. 5. Build order: guest-safe cold
   start in step 2, sign-in sheet in step 3, step 8 = localisation review.
6. Upsell "once this order closes"; auto-copy localOnly + 5-min expiry.
7. Recovery ranked by failed band; cut "isn't something you did". 8. Only the
   selected pack bordered; exit offer only with free address or Mail plan.
9. Category chips = real `Service.category` values (Messaging · Social · Dating ·
   Commerce · Finance · Delivery; never Gambling). 10. Verify on iOS 26:
   `tabViewBottomAccessory` absent state, `.searchable` placement. 11. Guest e-mail
   line has no credit price; one-time range over High+Medium countries.
12. Notify line by authorization. 13. New events; activation per install only;
   guardrail metrics (ratings average, refund notifications). 14. "Again" on a
   failed order opens recovery suggestions.
