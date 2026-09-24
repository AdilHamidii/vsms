# vSMS design overhaul — "verify-first" (UI/UX only)

Branch `design-overhaul` (cut from `main` @ `faa0f2b`, 2026-09-24). If the result
is not good, the branch is deleted and `main` is untouched.

Inputs: owner conversation 2026-09-24; current-state screenshots; the two standing
consultant reports in `docs/design-overhaul/consultants/` (`ui-ux.md`,
`psychology.md`), which carry the citations behind the decisions below.

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

**Success = these move after release (read on existing events + ASC analytics):**
orders per install (activation), first-session bounce between product tabs, share
of users placing a second order after a failed first one, line checkout → Apple
sheet, credit-paywall → purchase, free-e-mail share of first orders.

## 2. Constraints and non-goals

- **Backend untouched.** No file under `supabase/` changes; `git diff main --
  supabase` must be empty before every commit. No new endpoint, column, grant,
  price, cron or config key. Everything below uses reads and calls the client
  already makes (verified: services, countries, the client's `routes` columns,
  `app_config` whitelist and `line_country_menu`/`line_locality_menu` are
  anon-readable; `email-domains`, `search-line-numbers`, `record-events`,
  `service_country_ranks` and every write need a session).
- **Onboarding untouched** (`Onboarding/OnboardingScreen.swift`), owner request.
- **Owner rules kept:** nothing pre-selected on first run (user picks service
  AND country; the app may rank and recommend with a reason); no supplier named
  or hinted; no delivery promise or forecast (past-tense descriptions of people
  who succeeded only); no hardcoded server-owned numbers or StoreKit prices; the
  10-second gated delivery explainer stays; e-mail on a phone-only service is a
  WARNING, not a block (owner, 2026-09-23).
- **Truthful persuasion only.** Owner accepts aggressive tactics; excluded are
  fake timers or scarcity, false badges or counts, promised outcomes, hidden
  renewal terms, "money back" wording for a credits return, cancel friction.
- iOS 18 minimum; iOS 26 Liquid Glass with an 18 fallback. 7 languages.
- Not in scope: Live Activity (needs server push to update while backgrounded),
  win-back offers, Retention Messaging API, price changes, eSIM screens (stay
  unreachable, untouched).

## 3. Owner decisions (2026-09-24)

| # | decision |
|---|---|
| D1 | Direction A, verify-first: tabs **Verify · My number · Activity · Account** |
| D2 | **Defer sign-in**: browse as a guest, Sign in with Apple at the first claim or payment |
| D3 | "Your own number" may be the recommended way **only for services where a code has actually landed on a rented line** (today: WhatsApp, TikTok, DoorDash) |
| D4 | Line paywall uses the **compliant price layout**: $5.99/month most prominent, $3.99 first month subordinate |
| D5 | The 30-credit pack gets the highlight badge. Label is **"Our pick"** (the owner asked for it on the 30; "Most popular" there would be false — 90-day sales: 5-pack 50, 12-pack 36, 8-pack 17, 30-pack 12, 60-pack 3). Owner may reword. |
| D6 | Two standing consultants (UI/UX, psychology) advise throughout the branch |

## 4. Information architecture

```
Onboarding (unchanged) ─► Verify (guest or signed in)
Tabs (native TabView, labels always visible):
  Verify      — "What do you want to verify?" → Ways in → Country → Checkout
                → Waiting → Code | No code (recovery loop)
  My number   — no line: store → country → digits → paywall → provisioning
                live line: Messages · Calls · Number (settings), as today
  Activity    — SMS + e-mail orders merged; In progress / Past; one-tap "Again"
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
the credit balance on first screen for guests; the dead `AppTab.orders` case.
`/tabs number|temp` (server key `launch_tab`) stops affecting the order in new
builds — Verify is always first, My number second. The key stays for old builds.

**Kept, restyled:** every live-line feature, every sheet's behaviour, ResumeBar
(iOS 18: `safeAreaInset`; iOS 26: `tabViewBottomAccessory`), ErrorBanner,
AnnouncementBanner (moves to the top of Verify), MaintenanceView.

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
- Large title "What do you want to verify?", subtitle "Get a code for an app".
- Search field under the title, not autofocused; placeholder "Search N apps"
  with N from the loaded catalog.
- Guest or new user: 8 logo tiles (2×4) ordered by order volume (a static
  client list, like today's seven, reviewed at implementation), then category
  chips (Social · Dating · Shopping · Money · Games · Work) opening the filtered
  picker. No "More" tile.
- Returning user: a "Recent" row (last 3 services) above the tiles.
- Subscriber: a strip at the top, "Your number +1 … · Copy".
- Credits pill top-right (signed-in only; tap opens packs).
- A tile tap is the user's pick via `AppState.commitServicePick` (clears
  `needsServiceChoice`, leaves `needsCountryChoice` set).

### 6.2 Ways to verify {service}
- Vertical stack. The recommended way is first and expanded: 1pt accent border,
  "Best pick for {service}" in accent text, a one-line factual reason, 3 check
  rows, its own filled button. The other ways are compact rows (glyph · name ·
  price line · chevron).
- **Recommendation rule table** (client constant, owner-editable, facts only):
  - service in the proven-line set (WhatsApp, TikTok, DoorDash) → Your own
    number. Reason: "{service} may ask for a code again later. A number you keep
    can receive it." (no odds).
  - service in `Service.phoneOnlySignupIds` → One-time number. Reason:
    "{service} signs up with a phone number."
  - otherwise → Free e-mail if the user still has the free address, else
    One-time number. Reason: "Free, and {service} accepts e-mail sign-up."
  - Subscriber, service in the proven-line set → "Use your number · included"
    first (the same conservative set; it grows only with a measured code).
- **Phone-only service, e-mail row:** stays visible and tappable, de-emphasised,
  with "{service} signs up with a phone number, not an e-mail" (warn, not block).
- **Price grammar:** Free e-mail "Free · your first address" or "1 credit";
  One-time number "{min}–{max} credits, depends on country · credits back if no
  code" (real range for that service from the catalog); Your own number
  "{intro} first month, then {regular}/mo" from StoreKit only.
- Signed-in: "You have N credits · top up from {smallest covering pack price}"
  under the one-time row (StoreKit price, never a literal).

### 6.3 Country
- Sections: High network rate · Medium · Low · No published rate. Row: flag ·
  name · band word + meter · credits. Within a section: pool rate, then price.
  Never cheapest-first. Search pinned. One-line band legend (hidden with the
  meters under `delivery_metrics_hidden`).
- Tapping a Low row shows an inline note, not a block: "Low network rate.
  Another country usually works better."
- The user's tap clears `needsCountryChoice`; nothing is chosen for them.

### 6.4 Checkout (sheet, medium detent)
- Service + country, price, "Balance after: N", "Credits back automatically if
  no code arrives", the existing better-odds steer.
- First time the user chooses a one-time number: `DeliveryInfoSheet` shows here,
  before paying, with the same 10-second + scroll gate and the versioned
  `PrefKey.deliveryInfoAcked`. Its copy is rewritten as three behaviours
  (request the code right after pasting; wait at least 2 minutes; if it fails,
  switch country), refund first. Key bump to V3 because the advice changes.
- Balance short: CTA "Add credits · then get number" → pack sheet → back here
  with the CTA live and a success haptic ("20 credits added"). Never auto-order.
- Guest: CTA "Get number" → sign-in sheet (6.9) → back here.

### 6.5 Credit packs (sheet)
- Keep the context row ("WhatsApp · US · costs 24 · you have 5").
- Packs that do not cover the shortfall are dimmed: "Not enough for this order".
- Preselect the smallest covering pack, labelled "Covers what you need · N left
  over". "Our pick" on the 30-pack (D5). "Best value per credit" on the 60.
  "Most popular" removed.
- Per-credit price formatted with the storefront `priceFormatStyle`.
- Headline under the title: "Credits never expire · credits back if no code".
- Sticky CTA "Buy 20 credits · $8.99". Once-per-session exit offer on dismiss:
  "Free e-mail instead?" when the service accepts e-mail.

### 6.6 Waiting
- Three real steps: 1 the number, large, Copy (✓ once copied); 2 "Paste it into
  {service} and request the code"; 3 "Your code appears here".
- Real elapsed timer + "Credits back automatically in m:ss if no code arrives"
  from `Order.expiresAt`.
- Past-tense arrival line from `arrival_p50/p90` when measured for this service
  ("Codes here have usually arrived within about a minute; some took 3–5"),
  worded global when the scope is global, nothing when unmeasured.
- "Get another number" shows its real hold countdown
  (`AppState.minHoldSeconds(forProvider:)`) instead of refusing a tap.
- "You can leave — we'll notify you when it arrives."
- No percentage bar, no "almost there", no odds.

### 6.7 Code received
- Code at ~56pt, `.numericText` roll-in, `.success` haptic, auto-copied on
  arrival with a "Copied" state, one-tap copy again, then Done.
- Below Done, quiet and dismissible, no price: "One-time numbers can't receive a
  code later. If {service} asks again, a number you keep can." → My number.
  (Replaces `OtpScreen.keepNumberCard`; same `line_upsell_*` events.)
- E-mail code screen follows the same layout; the Mail plan card stays.
- The review prompt keeps its current eligibility/arms; nothing gates on a
  sentiment question.

### 6.8 No code (recovery)
- Headline: "No code this time. N credits are back." Cause line: "{service}
  didn't send a code to this number. That happens with some numbers and isn't
  something you did."
- "Try this instead", in order: (1) a named High-band country as a one-tap
  re-order using the existing `bestPoolRatedCountry` resolution; (2) Free e-mail
  if the service accepts e-mail; (3) Your own number if the service is in the
  proven-line set; (4) same country, fresh number.
- Past-tense line: "9 in 10 people who got a code had it within 3 tries." (the
  existing measured statement; never as a forecast).
- Existing `recovery_shown` / `recovery_action` events kept.

### 6.9 Sign-in sheet (guest mode)
- Triggers: "Get number" at checkout; "Get free e-mail"; "Choose your number"
  in My number; buying credits; opening Activity/Account actions that need an
  account.
- Content: one line saying why ("Sign in to get your number. Your credits and
  codes stay with your account."), Sign in with Apple, "Use e-mail instead".
  Reuses the existing auth screens and `Session`; no auth backend change.
- After sign-in: return to the exact screen with the user's picks intact, then
  continue the action they tapped.

### 6.10 My number
- No line: "A number that stays yours" + "Has received codes from" logo row
  (WhatsApp, TikTok, DoorDash). Country (with the existing
  `LineStoreScreen.sendingNotice` rules) → digits → paywall.
- Paywall (full screen): picked number on top ("Reserved for you" only if the
  server enforces a hold — verify at implementation, else omit); ✓ capability
  rows, the uncollapsed US/PR texting ✗ row and the 911 row; monthly preselected
  with "{regular}/month" at plan size and "{intro} your first month · new
  subscribers" beneath (D4); yearly behind "Other plans"; renewal sentence beside
  the price; "Only need it for a month? Turn off renewal right after buying — the
  number stays yours until {date}."; sticky "Start for {intro}" + "Cancel anytime
  in Settings". Existing intro-eligibility gate unchanged.
- After backing out of Apple's sheet: one line, "Just need one code? A one-time
  number for {last service}".
- Live line: Messages · Calls · Number as today, restyled; add "Manage
  subscription" (Apple's manage sheet) in the Number segment.

### 6.11 Activity
- In progress / Past; SMS and e-mail merged, newest first.
- Outcomes in words: "Code 123456"; "No code · N credits back" (mint).
- Each past order: "Again for {service} · {country}" (the user's own earlier
  pick, which keeps the nothing-pre-selected rule).
- Empty state: "Your codes and credits back show up here" + Verify button.

### 6.12 Account
- Wallet first: balance, Buy credits, history (credits back as mint "+N").
- Subscriptions (line, mail) with manage links; Invite (existing copy and
  `invite` event); vRoam card (existing dismiss key); Support (server-controlled
  link); Appearance; Legal; Delete account with its existing warnings.
- Guest: "Sign in" row at the top; Support and Legal still available.

## 7. Copy rules

Name outcomes, not mechanisms. "Credits back", never "refund" or "money back".
Delivery statements past tense only. Band words, never percentages. No supplier.
Never "number" without "one-time" / "your own". Every price from StoreKit or the
server. Every new string through `Text("literal")` / `String(localized:)` into
`Localizable.xcstrings` (committed JSON dialect) with all 7 languages and
format-specifier parity; no interpolated pluralised nouns.

## 8. Analytics

Keep every event whose meaning is unchanged (`service_selected`, checkout,
paywall, purchase, recovery, delivery info, line checkout, upsell, review).
New: `verify_view` (`guest`, `has_line`, `lines_loaded`), `ways_view`
(`service`, `recommended`), `way_selected` (`way`, `recommended`),
`signin_prompt_shown` / `signin_completed` (`trigger`), `activity_again`.
Retired with the Home tab: `home_view`, `home_card_tapped` (record the retirement
date in CLAUDE.md so the series break is not misread). Guest events are queued
on device and flushed after sign-in (`record-events` needs a session); events of
guests who never sign in are not recorded — compare against ASC installs.

## 9. Screenshot fixtures

Every `ScreenshotMode.Screen` case keeps a reproducible frame; rename where the
screen changed (`homeRouter`/`homeLine`/`home` → `verify`/`verifyLine`/
`ways`), add `ways`, `country`, `checkout`, `recovery`, `activity`, `account`,
`signin`. Update `ContentView.applyScreenshotState` and
`scripts/screenshots/*` in the same commits.

## 10. Build order (each step builds, is reviewable, and is revertible)

1. Design-system tokens (spacing, spring, number styles) + splash.
2. Tab shell (native TabView, 4 tabs) + Verify.
3. Ways in + country + checkout (incl. explainer relocation).
4. Waiting + code received + no-code recovery.
5. Guest mode + sign-in sheet + analytics queue.
6. My number store + paywall.
7. Activity + Account.
8. Screenshot fixtures, localisation pass, CLAUDE.md / rules update.

## 11. Verification

Per step: `xcodebuild` (the only check), `git diff main -- supabase` empty,
simulator screenshots of every touched screen in both states (guest/signed-in,
no line/live line) on iPhone 17 Pro and SE, Dynamic Type XXL and German, Reduce
Motion. Device walk before merge: purchase (sandbox), a real temp order, sign-in
deferral, line checkout. The two consultants review each step's screenshots.

## 12. Risks

- **Guest mode touches cold start and every session-assuming path**
  (`AppState.coldStart` loads profile, orders, lines). Mitigation: guest mode is
  its own step (5) behind the tab shell; every session read gets a guest branch.
- **Apple review**: deferring sign-in is encouraged by 5.1.1(v); the line
  paywall layout moves toward compliance (D4).
- **Series breaks** in Home events; documented (section 8).
- **Scale of change**: ~40 screen files and the string catalog. If a step
  misses, the branch is discarded; `main` is never touched until the owner
  approves a merge.
