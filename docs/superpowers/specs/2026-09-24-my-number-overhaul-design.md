# My number tab overhaul — design spec

**Status:** design approved by the owner on 2026-09-24 (the "Approve, write the spec" answer). The spec itself still needs the owner's review before the plan is written.
**Branch:** `design-overhaul`. **Parent spec:** `2026-09-24-design-overhaul-design.md`. Its §2 constraints, §5 visual system and §7 copy rules all apply here.
**Inputs:** the audit at `docs/design-overhaul/my-number-audit.md`, and "My number direction 1" in both consultant files (`docs/design-overhaul/consultants/*.md`).

## 1. Goal

The owner's verdict on the tab is that it "looks horrible and out of shape". The audit confirms it. The tab uses none of the overhaul's tokens: its gutter is 20pt against 16pt elsewhere, its radii are off-system, and it shows 4–8 accent-green elements per screen. Every number is set in SF Mono. The largest element for a subscriber is a paid, irreversible swap button. Every drill-in is a full-screen cover without a back swipe. The paywall inverts the D4 price hierarchy. Three surfaces carry a false claim that "a Canadian number sends texts reliably".

The goal is one coherent tab that looks like Verify, sells the number honestly, and gives a subscriber their number, messages and calls without a misplaced button.

**Success:**
- the line checkout → Apple sheet rate (`line_checkout_view` → `line_purchase_result`)
- `line_swap_open` counts from settings, compared with the old hero button (an accidental-tap proxy)
- no increase in `line_checkout_exit{how: back}`
- guardrails: Apple refund notifications, and the ratings average from `scripts/app-ratings.py`

## 2. Constraints (in addition to the parent §2)

- **The backend stays untouched.** No new endpoint, column or config key. Everything shown comes from data the client already reads: `my_line`, `line_country_menu` / `line_locality_menu`, `search-line-numbers`, StoreKit, `app_config` keys already whitelisted, and `lineSwapCredits`.
- **Owner decisions in force:**
  - **No plan talk on this tab** (2026-09-01, re-confirmed 2026-09-24). Renewal dates and Manage subscription stay in Account. The tab shows no renewal information.
  - **Store proof line** (2026-09-24): "Has received codes from WhatsApp, TikTok and DoorDash" — past tense, naming exactly those three. The unmeasured "and most other apps" is dropped.
  - **Price on the store.** Part of the approved design; it reverses the 2026-09-09 "no price on the store" decision. The price comes from StoreKit only. If the owner objects during spec review, the price row is removed and nothing else changes.
- **Legally and commercially load-bearing elements, all carried over** (audit §4):
  - `LineStoreScreen.unreliableSendingCountries` stays the ONE list. It drives the store notice, the checkout's uncollapsed `capabilityNote`, the thread's failed-send copy, and the new swap-sheet notice.
  - 🔴 Removing the US/PR warning means `force_block` in the same commit (CLAUDE.md).
  - Paywall 3.1.2(a) items: the price, period and renewal sentence; EULA and Privacy named as such; Restore.
  - The 911 disclosure appears on the paywall, in Number settings and in the dialer.
  - "Good to know" stays on the paywall.
  - The intro price appears only behind the eligibility gate.
  - The `CheckoutVisit` static stays.
  - The provisioning failure copy ("Please don't subscribe again") stays.
  - Suspended and released banners never promise the number back.
  - The keypad and call-back controls are hidden, never disabled, when there is no voice client.
  - `InCallOverlay` renders above covers.
  - Swap: the price, balance and "given up for good" appear on the confirm page only, and `IAPStore` stays in the sheet environment.
  - Every existing event keeps its name and props.

## 3. Visual rules (the fix for "out of shape")

1. **One column.** 16pt gutter (`RSpace.gutter`), 20pt cards (`RRadius.card`), 14pt row groups (`RRadius.group`). Use grouped lists, not a card per row. No shadows: `Card(.raised)` shadows go, because the parent spec forbids them.
2. **One green per screen.** The accent fill goes only on the screen's primary action. Mint (`theme.live`) is used only for success and live state. Every other control is neutral (`theme.chipBg` / `theme.elev`).
3. **One number voice.**
   - Titles use `.displayType(30)`.
   - Every phone number and price uses `numberStyle(...)`. SF Mono is removed from the tab, from `Buttons.swift`'s price sub-label, and from `InCallOverlay`.
   - Headers use `PhoneFormat.national`; rows use `PhoneFormat.compact`.

## 4. Information architecture

### 4.1 No live line → the store (tab root)

Top to bottom:
- **Title and pitch.** Title "Your own number", no kicker. Subtitle "A number that stays yours. Receive codes, texts and calls here."
- **Country control.**
  - A native segmented control built from the live sellable country list (`line_country_menu`), never hardcoded. With more than 3 sellable countries it falls back to a menu.
  - "Other city ›" opens the locality page.
- **Honest ledger, directly under the country control:**
  - ✓ Receive texts and verification codes
  - ✓ Calls
  - ✗ "Texts you send to US numbers usually don't arrive." Shown for every country, because the recipient's network enforces it (CA→US 0 of 8).
  - This one ledger replaces the store's old sending notice and its false Canada branch.
- **Proof line:** "Has received codes from WhatsApp, TikTok and DoorDash."
- **Numbers.** Three available numbers as one grouped list, inline instead of in a sheet. Each row shows the number in `numberStyle` at 20pt, with the city beneath. Below the list: "Show different numbers". Loading shows skeleton rows; the unavailable state keeps its three causes.
- **Price row:**
  - "{regular}/month" is the more prominent part.
  - Beneath it: "{intro} your first month · new subscribers", shown only behind the eligibility gate. StoreKit only.
  - If StoreKit hasn't loaded, the row is hidden (never a placeholder price).
- **Allowance.** The monthly text and minute allowance appears before purchase **only if the client already has a server-sourced value before purchase**. The plan verifies this. If no such value exists, it is recorded as an open item for the owner; nothing is hardcoded.
- **One-off code link.** "Just need a one-off code?" routes to Verify through `openCodeStore()`.
- **Flow:** tap a number → paywall → Subscribe → Apple sheet. That is 3 taps; today it takes 4 taps and a sheet.
- The picker sheet is removed. Its country and city pages become pushed pages on the tab's `NavigationStack`.

### 4.2 Paywall (a cover, as today)

- **Header:** a `.bar` material header with ✕ and Restore, so the scrolled card is not clipped flat.
- **Number card:** the chosen number (national format, `numberStyle`), flag and place. The "Held for you · m:ss" pill stays only where the server actually holds the number.
- **US/PR note:** uncollapsed when the country is in `unreliableSendingCountries`.
- **"What you get":** 4–5 rows, down from 9. The swap row is kept.
- **Plans:**
  - Monthly: "{regular}/month" at plan size, with "{intro} your first month · new subscribers" beneath, smaller. The intro sits behind the gate.
  - Yearly: a plain second row.
  - Only the selected plan carries a border.
- **Price sentence:** "Then {regular} every month until you cancel. Cancel any time in Settings." When no intro applies, the regular sentence.
- **Rental line:** "Only need it for a month? Turn off renewal after buying — it stays yours until the end of the month you paid for."
- **"Good to know":** collapsed, as today.
- **911 card.**
- **Links:** Terms of Use (EULA) · Privacy Policy · Restore, in one row.
- **CTA:** "Subscribe", with no typewriter price. Under it: "Cancel any time in Settings".

### 4.3 Live line → the subscriber home (tab root)

- **Title:** large title "My number".
- **Number card:**
  - The formatted number in `numberStyle` 28, with flag and city.
  - Copy and Share, as 44pt neutral buttons.
  - The line switcher `Menu`, for multiple lines, stays next to the number.
- **Status banners** (grace, past due, suspended, voice readiness) sit under the card, silent when healthy, with the same copy rules.
- **Segments:** native segmented control, **Messages · Calls · Number**. Messages is the default.
  - **Messages:**
    - One inset-grouped list: neutral monogram avatars; unread shown as a bold title plus a dot; the code chip in `numberStyle`, neutral.
    - Empty state: "Codes and texts sent to this number appear here." The old proof-of-life card is replaced; it names no service.
    - Compose is a toolbar button.
  - **Calls:**
    - Recents grouped by day; a missed call shows a red glyph, not a red name.
    - The allowance footer shows minutes left (and the reset date if the client has it; no plan wording).
    - The keypad is a toolbar button, hidden without a voice client.
  - **Number:**
    - Usage: texts and minutes left.
    - A plain "Change number…" row (see 4.5).
    - "Rent another number".
    - The Important card with 911.
    - No renewal or subscription rows (owner decision).
- **The FAB is removed.**

### 4.4 Drill-ins

- **Thread and compose are pushed** on the My number `NavigationStack`, so the back swipe works and the tab bar stays.
  - Push notifications for a line SMS route to the stack: set the tab to `.line` and push the thread.
  - Thread: title in national format; code chip "Copy 123456" neutral; "N texts left" shown only when 10 or fewer remain; failed-send copy reads the one list, with the Canada claim removed.
- **Dialer, paywall and provisioning stay covers.**
  - Dialer: entry in `numberStyle`; the call button uses the accent colour (the one primary action); the emergency line is kept.
- **Swap stays a sheet.** Pages are unchanged, **plus the ledger's ✗ line when the target number is in US/PR**.

### 4.5 Change number (swap)

- Reached in two taps: Number segment → "Change number…" → sheet. It is never the primary action on any screen.
- The confirm page shows the current and new numbers, the price, the balance, and "Your current number is given up for good."
- The existing Top-up path is unchanged.

## 5. Copy corrections (false today)

- Remove "A Canadian number sends texts reliably" from LineStoreScreen:575, LineCheckoutScreen:349 and ThreadScreen:554.
- Remove "Texts you send from a Canadian number arrive normally" from LineStoreScreen:594.
- The store's "also works with TikTok, DoorDash and most other apps" becomes the §2 proof line.
- Every new string goes into all six locales through `scripts/xcstrings-add.py`, in each locale's tone.

## 6. Analytics

- All existing events are kept (audit §1.2).
- **New:**
  - `line_numbers_shown` fires on the inline list; `source: "store_inline"` replaces the sheet's value.
  - `line_swap_open{from: "number_segment"}`.
- **Retired:**
  - `line_choose_number_tapped`. The inline list replaces the button. This is noted in CLAUDE.md.

## 7. Fixtures (spec §9 gaps the audit found)

- **Existing fixture:** `lineStore` now shows the inline numbers.
- **New fixtures:**
  - `linePaywallUS` (top of the paywall, US number, note uncollapsed)
  - `lineInboxEmpty`
  - `lineCalls`
  - `lineNumber` (the Number segment)
  - `lineSwapConfirm`
  - `lineDialer`
  - `lineBanner` (past due)
- Every frame is captured in dark and light, and the backgrounds are sampled.

## 8. Build order

Each item below is a plan task.

1. Tokens pass across the line files: gutter, radii, shadows, SF Mono → `numberStyle`, one-green. No layout change.
2. Copy corrections and the ledger. The single-list rule stays; the swap-sheet notice is added.
3. Store rebuild: inline numbers, country segment, pushed city pages, price row, proof line.
4. Paywall rebuild to D4.
5. Subscriber home: title, number card, Messages · Calls · Number segments, FAB removed, toolbar buttons.
6. Thread and compose pushed on a stack; push-notification routing.
7. Fixtures, and CLAUDE.md / `telephony.md` / `ios-client.md` updates.

## 9. Risks

- **Moving thread and compose from covers to a stack** touches push routing and `InCallOverlay` layering (telephony.md trap 5). The plan must verify on the simulator that an incoming-call overlay still renders above a pushed thread.
- **Inline numbers load `search-line-numbers` on tab appearance** instead of on a button tap. That is more calls, and the function needs a session. A guest never sees the store's numbers until sign-in (Plan 2 guest mode must handle this).
- **The price on the store** reverses a 2026-09-09 owner decision (see §2).
- **Nothing here can be tap-tested on the simulator.** A device walk is needed before merge.
