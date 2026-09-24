# vSMS design overhaul — "verify-first" (UI/UX only)

Branch `design-overhaul` (cut from `main` @ `faa0f2b`, 2026-09-24). If the result
is not good, the branch is deleted and `main` is untouched.

Inputs: owner conversation 2026-09-24; current-state screenshots; the two standing
consultant reports and their spec reviews in `docs/design-overhaul/consultants/`,
which carry the citations behind the decisions below.

## 1. Goal

Make it obvious within seconds what vSMS sells and which option fits the user's
job, and raise conversion at every money moment — without touching the backend.

**The problem being solved (measured, not assumed):**
- "Number" names two products. The Temp tab sells temp SMS as "Get a number for
  X" with a Number | E-mail switch; the Number tab sells the subscription, which
  also promises "codes". A quarter of new users bounce between the two tabs in
  their first session, and that cohort produces most support taps.
- Home stacks three products at equal weight before the user states a need.
- The temp-SMS screen is a form with jargon ("typical wait", "Medium network").
- Inactive tabs are icon-only; a clock icon means "Temp".
- 166 of 303 ordering users quit after one order; failure is a dead end.
- 69% of signups never order; sign-in is required before anything is visible.
- Line checkout: 72 reached checkout → 19 opened Apple's sheet → 3 paid.

**Success = these move after release:** orders per **install** (from ASC
analytics — see the warning below), first-session bounce between product tabs,
share of users placing a second order after a failed first one, line checkout →
Apple sheet, credit paywall → purchase, free-e-mail share of first orders.
**Guardrails (the cost side of a harder conversion push):** the ratings average
(`scripts/app-ratings.py`) and Apple refund notifications — Apple lists both as
5.6.4 quality signals.

⚠️ **Deferred sign-in breaks every signup-based ratio.** Signups become people
who already chose to buy or claim, so "signup → order" (the 69%) jumps for
artefactual reasons. Judge activation per install only.

## 2. Constraints and non-goals

- **Backend untouched.** No file under `supabase/` changes; `git diff main --
  supabase` must be empty before every commit. No new endpoint, column, grant,
  price, cron or config key. Verified 2026-09-24: services, countries, the
  client's `routes` columns and `line_country_menu` / `line_locality_menu` are
  anon-readable; `email-domains`, `search-line-numbers`, `record-events`,
  `service_country_ranks` and every write need a session. StoreKit products
  load without a session. ⚠️ **Corrected 2026-09-24 (Plan 1 Task 4 review,
  checked live in `pg_policies`): `app_config` is NOT anon-readable** — its
  `app_config_read` policy is `to authenticated`, and `MaintenanceAPI` /
  `AppStatusAPI` refuse client-side without a session. So a guest sees no
  maintenance notice, banner or `support_url` until sign-in; guest mode must
  re-run both reads right after sign-in (§10 step 5). Widening the policy to
  `anon` is a backend change and stays out of this branch unless the owner
  asks for it.
- **Onboarding untouched** (`Onboarding/OnboardingScreen.swift`), owner request.
- **Owner rules kept:** nothing pre-selected on first run (user picks service
  AND country; the app may rank and recommend with a reason); no supplier named
  or hinted; no delivery promise or forecast (past-tense descriptions of people
  who succeeded only); no hardcoded server-owned numbers or StoreKit prices; the
  10-second gated delivery explainer stays; e-mail on a phone-only service is a
  WARNING, not a block (owner, 2026-09-23).
- **Truthful persuasion only.** Owner accepts aggressive tactics; excluded are
  fake timers or scarcity, false badges or counts, unsubstantiated superlatives,
  promised outcomes, hidden renewal terms, "refund"/"money back" wording for a
  credits return, cancel friction.
- iOS 18 minimum; iOS 26 Liquid Glass with an 18 fallback. 7 languages.
- Not in scope: Live Activity (needs server push while backgrounded), win-back
  offers, Retention Messaging API, price changes, eSIM screens (stay unreachable,
  untouched).

## 3. Owner decisions (2026-09-24)

| # | decision |
|---|---|
| D1 | Direction A, verify-first: tabs **Verify · My number · Activity · Account** |
| D2 | **Defer sign-in**: browse as a guest, Sign in with Apple at the first claim or payment |
| D3 | "Your own number" may be the recommended way **only for services with a measured record on rented lines**. Bar: ≥ 3 codes on ≥ 2 different lines in the last 90 days (owner-editable client constant). Measured 2026-09-24 from inbound `line_messages`: **WhatsApp 16 codes / 7 lines ✓**; TikTok 1 / 1 and DoorDash 1 / 1 do not meet it. Re-derive before changing the set. |
| D4 | Line paywall uses the **compliant price layout**: the billed $5.99/month most prominent, the $3.99 first month subordinate, CTA "Subscribe" |
| D5 | The 30-credit pack is highlighted, labelled **"Our pick"** (the owner asked for it on the 30; "Most popular" there would be false — 90-day sales: 5-pack 50, 12-pack 36, 8-pack 17, 30-pack 12, 60-pack 3). Rendered as a text tag only, shown only when the shortfall is ≥ 13 credits (so it never suggests buying 4–6× what the order needs). Owner may reword. |
| D6 | Two standing consultants (UI/UX, psychology) advise throughout the branch |

## 4. Information architecture

```
Onboarding (unchanged) ─► Verify (guest or signed in)
Tabs (native TabView, labels always visible):
  Verify      — "What do you want to verify?" → Ways in → Country → Checkout
                → Waiting → Code | No code (recovery loop)
  My number   — no line: store → country → digits → paywall → provisioning
                live line: Messages · Calls · Number (settings), as today
  Activity    — SMS + e-mail orders merged; In progress / Past; "Again"
  Account     — Wallet (balance, buy, history) · Subscriptions · Invite · vRoam
                · Support · Appearance · Legal · Delete account
```

**Vocabulary (identical in every screen and language):**
- **Free e-mail**: temp e-mail address.
- **One-time number**: temp SMS; paid in credits; "credits back" if no code.
- **Your own number**: the subscription.
The word "number" never appears without "one-time" or "your own" (or a literal
phone number).

**Removed:** Home tab and its cards; Temp tab and its Number | E-mail switch;
the dead `AppTab.orders` case. `/tabs number|temp` (server key `launch_tab`)
stops affecting new builds — Verify is always first, My number second. The key
stays for old builds.

**Kept, restyled:** every live-line feature, every sheet's behaviour, ResumeBar
(iOS 18: `safeAreaInset`; iOS 26: `tabViewBottomAccessory` — verify on 26.0 that
it can be absent when nothing is in progress; if an empty capsule renders, use
`safeAreaInset` on 26 too), ErrorBanner, AnnouncementBanner (moves to the top of
Verify), MaintenanceView.

## 5. Visual system — "Ledger on native bones"

- Native `TabView`, `NavigationStack`, lists and sheets; the custom skin applies
  to cards, numbers and paywalls.
- Palette: near-black base; surfaces ≈ #16171A / #1E1F23; hairlines white 8%.
  Accent green **only** for the primary action. Mint (`live`) = success and
  credits back. Amber = Medium/Low band. Red almost never. The user accent picker
  stays; it never recolours semantic colours (already true in `Theme.swift`).
- Type: SF Pro Display Bold large titles (34/28), SF Pro Text 17 body. Every
  number uses `.monospacedDigit()` + `.contentTransition(.numericText())`; SF Mono
  is retired from prices and phone numbers.
- Shape: 20pt continuous-corner cards, 14pt row groups, 56pt capsule CTAs, one
  content elevation, no drop shadows. Add a spacing scale token (there is none).
- Emphasis rule: **only the selected option gets a border or fill**; every other
  label ("Our pick", "Best value per credit", "Recommended for …" on a
  non-selected card) is a text tag.
- Liquid Glass only on the navigation/controls layer (tab bar, bottom accessory,
  sticky CTA tray, sheet headers); fallback `.bar` / `.regularMaterial`.
- Motion: one spring (response 0.35, damping 0.85) added to `RMotion`; matched
  geometry of the service logo Verify → Ways in → Waiting. Honour Reduce Motion
  and Reduce Transparency.
- Haptics: `.selection` on picks; `.success` on code arrival and on credits
  added; no error haptic on a delivery failure.
- Splash: wordmark + the existing truthful progress bar and slow-connection line
  (boot logic unchanged); no marketing copy.

## 6. Screens

### 6.1 Verify
- Large title "What do you want to verify?", subtitle "Get a code for an app.
  No code? Your credits come back."
- Search field under the title, not autofocused; placeholder "Search N apps"
  with N from the loaded catalog. Verify on iOS 26 that `.searchable` keeps the
  field under the title; otherwise use an in-content field.
- Guest or new user: 8 logo tiles (2×4), a static client list ordered by order
  volume (reviewed at implementation), then category chips that map 1:1 to real
  `Service.category` values: Messaging · Social · Dating · Commerce · Finance ·
  Delivery (never Gambling). No "More" tile.
- Returning user: a "Recent" row (last 3 services) above the tiles.
- Subscriber: a strip at the top, "Your number +1 … · Copy".
- Credits pill top-right (signed-in only; tap opens packs).
- A tile tap is the user's pick via `AppState.commitServicePick` (clears
  `needsServiceChoice`, leaves `needsCountryChoice` set).

### 6.2 Ways to verify {service}
- Vertical stack. The recommended way is first and expanded, with "Recommended
  for {service}" in accent text (never "best"), a one-line factual reason, 3 check
  rows and its own filled button. The other ways are compact rows (glyph · name ·
  price line · chevron).
- **Recommendation rule table** (client constant, owner-editable; facts only):
  1. user still has the free address AND service not in
     `Service.phoneOnlySignupIds` → **Free e-mail**. Reason: "Free, and {service}
     accepts e-mail sign-up."
  2. service in the measured-line set (D3; today WhatsApp) → **Your own
     number**. Reason: "{service} codes have arrived on numbers kept in vSMS.
     {service} may ask for a code again later — a number you keep can receive
     it." One-time number is listed second.
  3. otherwise → **One-time number**. Reason for a phone-only service:
     "{service} signs up with a phone number."
  4. Subscriber, service in the measured-line set → "Use your number · included"
     first.
- **Phone-only service, e-mail row:** stays visible and tappable, de-emphasised,
  with "{service} signs up with a phone number, not an e-mail" (warn, not block).
- **Price grammar, with money beside credits (guests too):**
  - Free e-mail: "Free · your first address"; signed in and past the free
    address: "{credit_price} credit(s)" from `email-domains`. Guests see only the
    free line (no `credit_price` without a session).
  - One-time number: "{min}–{max} credits · about {money} · credits back if no
    code". Range over the service's High and Medium countries (fallback: all
    countries) so one clamped outlier cannot print "4–180". Money = the smallest
    covering pack's per-credit price from StoreKit.
  - Your own number: "{intro} first month, then {regular}/month", StoreKit only.
- Signed-in: "You have N credits" under the one-time row.

### 6.3 Country
- Sections in this order: **High network rate · Medium · No published rate ·
  Low** (unrated delivers 29–33% per try, Low 17%: "no information beats reported
  dead"). Row: flag · name · band word + meter · credits. Within a section: pool
  rate, then price; never cheapest-first. Search pinned. One-line band legend
  (hidden with the meters under `delivery_metrics_hidden`).
- Tapping a Low row shows an inline note, not a block: "Low network rate. Codes
  have arrived far less often here than in High-rate countries."
- The user's tap clears `needsCountryChoice`; nothing is chosen for them.

### 6.4 Checkout (sheet, medium detent)
- Service + country, "24 credits · you'd buy 30 for {price}" when short (or
  "Balance after: N"), "Credits back automatically if no code arrives", the
  existing better-odds steer.
- First time the user chooses a one-time number: `DeliveryInfoSheet` shows here,
  before paying, with the same 10-second + scroll gate. Copy rewritten as
  behaviours, refund first: request the code in the app right after pasting;
  wait at least 2 minutes; "if no code comes: on a High route, try again with a
  fresh number; on a Low route, pick another country" (band-branched, CLAUDE.md
  copy rule 2). `PrefKey.deliveryInfoAcked` bumps to V3 (the advice changes).
  ⚠️ This knowingly overrides "it does not raise over a live `state.flow`" —
  checkout is a flow. Update CLAUDE.md in step 3.
- Balance short: CTA "Add credits · then get number" → pack sheet → back here
  with the CTA live and a success haptic ("20 credits added"). Never auto-order.
- Guest: CTA "Get number" → sign-in sheet (6.9) → back here.

### 6.5 Credit packs (sheet)
- Keep the context row ("WhatsApp · US · costs 24 · you have 5").
- Packs that do not cover the shortfall are dimmed: "Not enough for this order".
- The smallest covering pack is preselected (the ONLY bordered/filled row),
  labelled "Covers what you need · N left over". "Our pick" text tag on the
  30-pack when the shortfall is ≥ 13 (D5). "Best value per credit" text tag on
  whichever pack has the lowest per-credit price in THIS storefront, computed from
  live StoreKit prices (the euro ladder has inverted before). "Most popular"
  removed.
- Per-credit price formatted with the storefront `priceFormatStyle`.
- Headline under the title: "Credits never expire · credits back if no code".
- Sticky CTA "Buy 20 credits · $8.99". Once-per-session exit offer on dismiss,
  "Free e-mail instead?", only when the service accepts e-mail AND the user still
  has the free address or holds the Mail plan.

### 6.6 Waiting
- Three real steps: 1 the number, large, Copy (✓ once copied); 2 "Paste it into
  {service} and request the code"; 3 "Your code appears here".
- Real elapsed timer + "Credits back automatically in m:ss if no code arrives"
  from `Order.expiresAt`.
- Past-tense arrival line from `arrival_p50/p90` when measured ("Codes here have
  usually arrived within about a minute; some took 3–5"), worded global when the
  scope is global, nothing when unmeasured.
- "New number available in m:ss" (`AppState.minHoldSeconds(forProvider:)`), then
  "Get another number", with one line stating what happens to the current number.
  Verify in step 4 what a reroll does to the old number (cancel-order's
  late-code rescue vs the hold rule) and state exactly that.
- Leaving: "Closing keeps your order running." If notification authorization is
  `.authorized`: "You can leave — we'll notify you when it arrives." Otherwise:
  "Turn on notifications to hear when it arrives" with a Settings button.
- No percentage bar, no "almost there", no odds.

### 6.7 Code received
- Code at ~56pt, `.numericText` roll-in, `.success` haptic, auto-copied on
  arrival (`UIPasteboard.general.setItems(_, options: [.localOnly: true,
  .expirationDate: now + 5 min])`) with a "Copied" state, one-tap copy again,
  then Done.
- Below Done, quiet and dismissible, no price:
  - measured-line service: "One-time numbers can't receive codes once this order
    closes. If {service} asks again, a number you keep can." → My number.
  - any other service: "Want a number that stays yours? See Your own number."
  (Replaces `OtpScreen.keepNumberCard`; same `line_upsell_*` events.)
- E-mail code screen follows the same layout; the Mail plan card stays.
- The review prompt keeps its current eligibility and arms; no sentiment gate.

### 6.8 No code (recovery)
- Headline: "No code this time. N credits are back."
- Cause line: "No code reached this number. That's common with one-time
  numbers." If the order shows no activity: "Next time, request the code in
  {service} right after pasting." Never blame the user; never claim what the
  service did.
- "Try this instead", ranked by the band of the route that failed:
  - failed route High: (1) same country, fresh number; (2) another High
    country; (3) Free e-mail if the service accepts e-mail; (4) Your own number
    if measured-line service.
  - failed route Medium / Low / unrated: (1) a named High country as a one-tap
    re-order (`bestPoolRatedCountry`); (2) Free e-mail if accepted; (3) Your own
    number if measured-line service; (4) same country, fresh number.
- "9 in 10 people who got a code had it within 3 tries." shows only on the
  user's 1st or 2nd consecutive failure for this service; from the 3rd it is
  hidden and option (1) leads.
- Existing `recovery_shown` / `recovery_action` events kept.

### 6.9 Sign-in sheet (guest mode)
- Triggers: "Get number" at checkout; "Get free e-mail"; "Choose your number"
  in My number; buying credits; account-only actions in Activity/Account.
- Content: one line saying why ("Sign in to get your number. Your credits and
  codes stay with your account."), Sign in with Apple, "Use e-mail instead".
  Reuses the existing auth screens and `Session`; no auth backend change.
- After sign-in: return to the exact screen with the user's picks intact, then
  continue the action they tapped.

### 6.10 My number
- No line: "A number that stays yours" + "Has received codes from" logo row
  listing only the measured-line set (today WhatsApp). Country (with the existing
  `LineStoreScreen.sendingNotice` rules) → digits → paywall.
- Paywall (full screen): picked number on top ("Reserved for you" only if the
  server enforces a hold — verify at implementation, else omit); ✓ capability
  rows, the uncollapsed US/PR texting ✗ row and the 911 row; monthly preselected
  with "{regular}/month" at plan size and "{intro} your first month · new
  subscribers" beneath (D4); yearly behind "Other plans"; sticky CTA
  **"Subscribe"** with, directly under it, "{intro} first month, then
  {regular}/month. Cancel anytime in Settings."; "Only need it for a month? Turn
  off renewal right after buying — the number stays yours for the month you paid
  for."; **Terms of Use (EULA), Privacy Policy and Restore purchases** links.
  Existing intro-eligibility gate unchanged.
- After backing out of Apple's sheet: one line, "Just need one code? A one-time
  number for {last service}".
- Live line: Messages · Calls · Number as today, restyled; add "Manage
  subscription" (Apple's manage sheet) in the Number segment.

### 6.11 Activity
- In progress / Past; SMS and e-mail merged, newest first.
- Outcomes in words: "Code 123456"; "No code · N credits back" (mint).
- Past order with a code: "Again for {service} · {country}" (the user's own
  earlier pick). Past order with no code: "Again" opens the 6.8 suggestions
  instead of re-buying the route that failed.
- Empty state: "Your codes and credits back show up here" + Verify button.

### 6.12 Account
- Wallet first: balance, Buy credits, history (credits back as mint "+N").
- Subscriptions (line, mail) with manage links; Invite (existing copy and
  `invite` event); vRoam card (existing dismiss key); Support (server-controlled
  link); Appearance; Legal; Delete account with its existing warnings.
- Guest: "Sign in" row at the top; Support and Legal still available.

## 7. Copy rules

Name outcomes, not mechanisms. "Credits back", never "refund" or "money back".
Delivery statements past tense only; no superlatives we cannot substantiate.
Band words, never percentages. No supplier. Never "number" without "one-time" /
"your own". Every price from StoreKit or the server. Every new string goes into
`Localizable.xcstrings` (committed JSON dialect) in all 7 languages **in the same
commit that adds it**, with format-specifier parity; `Text("literal")` /
`String(localized:)`; no interpolated pluralised nouns.

## 8. Analytics

Keep every event whose meaning is unchanged (`service_selected`, checkout,
paywall, purchase, recovery, delivery info, line checkout, upsell, review).
New: `verify_view` (`guest`, `has_line`, `lines_loaded`), `ways_view`
(`service`, `recommended`), `way_selected` (`way`, `recommended`),
`signin_prompt_shown` / `signin_completed` (`trigger`), `activity_again`,
`pack_exit_offer_shown` / `_taken`, `line_sheet_abandon_offer_shown` / `_taken`,
`country_low_note_shown`. Retired with the Home tab: `home_view`,
`home_card_tapped` (record the retirement in CLAUDE.md so the series break is not
misread). Guest events are queued on device and flushed after sign-in
(`record-events` needs a session); guests who never sign in are not recorded —
compare against ASC installs.

## 9. Screenshot fixtures

Every `ScreenshotMode.Screen` case keeps a reproducible frame; rename where the
screen changed (`homeRouter`/`homeLine`/`home` → `verify`/`verifyLine`/`ways`),
add `country`, `checkout`, `recovery`, `activity`, `account`, `signin`. Update
`ContentView.applyScreenshotState` and `scripts/screenshots/*` in the same
commits.

## 10. Build order (each step builds, is reviewable, and is revertible)

1. Design-system tokens (spacing, spring, number styles, emphasis rule) + splash.
2. Tab shell (native TabView, 4 tabs) + Verify + **guest-safe cold start**
   (catalog, services, countries, routes and StoreKit products load with no
   session).
3. Ways in + country + checkout (explainer relocation) + **sign-in sheet**.
4. Waiting + code received + no-code recovery.
5. Guest mode completion (every remaining session-assuming path) + analytics
   queue.
6. My number store + paywall.
7. Activity + Account.
8. Screenshot fixtures, localisation review, CLAUDE.md / rules update.

## 11. Verification

Per step: `xcodebuild` (the only check), `git diff main -- supabase` empty,
simulator screenshots of every touched screen in both states (guest/signed-in,
no line/live line) on iPhone 17 Pro and SE, Dynamic Type XXL and German, Reduce
Motion; on iOS 26 also the bottom-accessory and `.searchable` checks (§4, §6.1).
Device walk before merge: purchase (sandbox), a real temp order, sign-in
deferral, line checkout. The two consultants review each step's screenshots.

## 12. Risks

- **Guest mode touches cold start and every session-assuming path**
  (`AppState.coldStart` loads profile, orders, lines). Mitigation: guest-safe
  cold start lands in step 2 so later steps are built on it; the rest in step 5.
- **Apple review**: deferring sign-in is encouraged by 5.1.1(v); the line
  paywall moves toward 3.1.2 compliance (D4) and gains its required links.
- **Series breaks** in Home events and signup-based ratios; documented (§1, §8).
- **Scale of change**: ~40 screen files and the string catalog. If a step
  misses, the branch is discarded; `main` is never touched until the owner
  approves a merge.
