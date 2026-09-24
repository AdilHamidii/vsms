# "My number" tab — design audit (read-only, 2026-09-24)

Branch `design-overhaul` @ `571bd58`. Scope: every screen and state the My number
tab reaches, ahead of the visual overhaul (spec
`docs/superpowers/specs/2026-09-24-design-overhaul-design.md` §5, §6.10, §7). No
code was changed. Evidence is file:line on this branch plus simulator frames
(iPhone 17 Pro, 1206×2622 @3x, so 3 px = 1 pt).

Frames: `/Users/adyl/.claude/jobs/c5c3d119/tmp/mn-<fixture>-<dark|light>.png`
for `lineIntro`, `lineStore`, `linePaywall`, `linePaywallYearly`, `lineInbox`,
`thread` and `verifyLine`, captured from a private Debug build
(`-derivedDataPath …/dd-audit`).

---

## 1. Inventory

### 1.1 Routing (`Screens/LineScreen.swift`, 866 lines)

`LineScreen` (LineScreen.swift:9-42) switches on `state.line`:

| condition | renders |
|---|---|
| a live line (`status.isLive`) | `LiveLineView` (private, :77-588) |
| `!linesLoaded` | a bare `theme.bg` (anti-flash; normally never seen) |
| otherwise, including a **released** line | `LineStoreScreen` |

Its `.task` calls `loadLine` on every visit. No events.

Everything else the tab reaches is a **`fullScreenCover`** driven by
`state.flow` (ContentView.swift:551, cases at :713-740): `.lineStoreMore`,
`.lineCheckout`, `.lineProvisioning`, `.thread`, `.compose` and `.dialer`.
There is no `NavigationStack` push anywhere in the tab. Settings, swap, the
number picker and peer naming are `.sheet`s.

### 1.2 Screen by screen

| # | screen / state | file (lines) | shows | events | must keep (legal/commercial) |
|---|---|---|---|---|---|
| 1 | **Store (no line)** | `LineStoreScreen.swift` (929) | kicker "Second number", 28pt title, pitch card ("Great for WhatsApp", headline, body naming TikTok/DoorDash, 4 benefit rows incl. the swap priced from `lineSwapCredits`), "Choose your number" CTA, `usSoon` reach note ("Receives texts from US and Canadian numbers and services"), `smsEscape` ghost button. **No price** on this screen (owner decision 2026-09-09; `priceNote` :868 is dead code kept for a one-line revert). | `line_store_view` (:125) | the NANP-only inbound note (`usSoon`, :878) — the pitch's unqualified "texts" is honest only while it exists (:257-268); only proven services named; swap row wording must change if a cooldown is ever set (:326); **no credit pill** (the line never touches the wallet). |
| 1a | **Picker sheet: numbers page** | same, `numbersPage` :401, `placeSheet` :658 | `SheetHeader` "Choose your number", country chips (`LineCountryChip`), "Available now in {place}" + Change, **sending notice**, 3 `LineOfferRow`s or a skeleton or the unavailable state, "Show different numbers". | `line_choose_number_tapped` (:393), `line_numbers_shown` (:161), `line_place_changed` (:174), `line_number_picked` (:491) | 🔴 **`sendingNotice` (:563) and `unreliableSendingCountries = ["US","PR"]` (:607)**, the one list that checkout and the thread read too; `voiceOnlyNotice` (:518) on a positive `supports_sms = false`. |
| 1b | Picker sheet: countries / cities / country-wide | same :709-776, rows in `Components/LinePickerRows.swift` (495) | grouped `Card` lists. | `line_place_changed` | fails closed on unsellable countries (server). |
| 1c | Store unavailable | same `unavailable` :624 | `EmptyState` with 3 causes (paused / country not sellable / unknown = `fail` tint). | — | a load failure must not read as a healthy absence. |
| 1d | Store as a cover (`.lineStoreMore`, "Rent another number") | same, `onClose` :49, ✕ in `header` :816 | same screen with a close button. | same | the ✕ exists because the cover had no exit (owner report 2026-09-06). |
| 2 | **Paywall** | `LineCheckoutScreen.swift` (1079) | ✕ + **Restore** header (:181); intro ("Second number", "Your {city} number, ready now.", 29pt); `HeroCard` number (avatar, flag + place + area code, **SF Mono 31** number, "Held for you · m:ss" / "Available now" pill); `capabilityNote`; "What you get" ledger (9 rows incl. the swap); plan picker (Monthly with "{intro} for your first month", Yearly with SAVE n%); `priceBlock`; collapsed "Good to know" (4 rows); 911 card; Terms/Privacy links; `BottomBar` CTA "Subscribe" + price sub + "Cancel any time in Settings". Unavailable/loading/reserving/confirming labels on the CTA (:938). | `line_checkout_view` (:145), `line_plan_selected` (:721), `line_checkout_exit` (:1049, `how`/`seconds`/`plan`/`intro`/`country`/`capability_note`/`good_to_know_expanded`), `line_purchase_result` (SubscriptionStore.swift:419) | 🔴 **`capabilityNote` uncollapsed on US/PR (:326-359)** — "if it is ever removed, force_block US and PR in the same commit" (CLAUDE.md); **3.1.2(a)**: price, period, renewal sentence (:825-839), EULA + Privacy links named as such (:884), Restore on screen (:195); **911 disclosure** (:858); the "Good to know" rows stay ON this screen (:567-576); intro shown only behind the eligibility gate (`monthlyIntroOffer` is set only after `isEligibleForIntroOffer`); period follows the plan in the CTA (:906). The `CheckoutVisit` static (:1060) must survive any restructure or `line_checkout_exit` double-fires. |
| 3 | **Provisioning cover** | `LineProvisioningScreen.swift` (183) | avatar + spinner, "Setting up your number", SF Mono 19 number, "taking longer" line after 8s; **failed** state: "We couldn't finish setting up your number … Please don't subscribe again." + Close. | `line_provisioned` (:50) | the failed copy ("don't subscribe again") is the only guard against a double charge. |
| 3a | In-tab provisioning (`isSettingUp`) | LineScreen.swift:468 | spinner + two lines; no segments, no FAB, no Change number. | — | — |
| 4 | **Live line: header** | LineScreen.swift:238-297 | flag, status dot, **SF Mono 17** number (tap = copy), "Tap the number to copy it" / "Copied", three 36pt icon chips (Copy, Share, Gear), multi-line `Menu` switcher (:359) with elsewhere-unread badge. | — | tap-to-copy + explicit Copy; the renewal date was removed on purpose (owner 2026-09-01: no plan talk on this tab). |
| 4a | Change number (primary) | `LineSwitchNumberButton.swift` (98) at LineScreen.swift:112 | full-width **accent-filled** 56pt "Change number"; hidden when `lineSwapCredits` is nil or the line is not `.active`; "Your new number is …" line after a swap. | (sheet events below) | 🔴 never names the price (choose first, pay last); hidden, not disabled, without a server price. |
| 4b | Status banners | `LineStatusBanner` :634, `VoiceReadinessNotice` :830 | grace (warn), past due (fail), suspended/released (fail, must NOT promise the number back), failed; voice outbound-only / unavailable. Silent when healthy. | — | 🔴 suspended copy must never promise the old number (:680-687); banners stay under the header, not in settings (:60-64). |
| 5 | **Messages segment** | LineScreen.swift:510-582, `ThreadRow` :708 | thread cards (44pt avatar, name or number, code chip in **SF Mono 13**, preview, relative time, unread dot); **empty = `proofOfLife` card** ("Your number is live", names WhatsApp, TikTok, DoorDash). Context menu Add name / Copy. | — | proof-of-life must not say "call it and see" (:506); only proven services named. |
| 6 | **Recents segment** | `LineRecentsView.swift` (332) | `AllowanceStrip` (minutes left + bar), day headers, `RecentRow` (avatar, name in `fail` red when missed, direction icon, time, call-back chip) expanding to four action tiles (Call back, Messages, Copy, Add name); empty = `EmptyState` "No calls yet". | — | call-back glyph hidden (not disabled) without a voice client. |
| 7 | **FAB** | LineScreen.swift:426-461 | 60pt accent circle, bottom-trailing; compose on Messages, keypad on Recents (hidden without voice). | — | 🔴 keypad half HIDDEN, never disabled, with no voice client. |
| 8 | **Thread** (cover) | `ThreadScreen.swift` (607) | ✕, avatar, number, call + ⋯ chips; day pill; bubbles; green "Copy 123456" chips under codes; composer + "N texts left this month"; failed-send copy. | — | 🔴 failed-send copy on a US/PR sender reads the same `unreliableSendingCountries` (:248-256, :553-554). |
| 9 | Compose (cover) | `ComposeScreen.swift` (261) | ✕, "New message", "From {number}", To field (**SF Mono 16**), body. | — | NANP-only refusal up front; remaining texts at ≤10. |
| 10 | **Dialer** (cover) | `DialerScreen.swift` (488) | keypad, **SF Mono 30** entry, notices (country not callable, need N credits, emergency, minutes used), `live`-green call button. | `voice_login_failed` (CallController.swift:235) | 🔴 the emergency line (:263); per-minute credit refusal before dialling; long-press-0 gesture (telephony.md trap 7). |
| 11 | **InCallOverlay** | `InCallOverlay.swift` (193) | 27pt name, **SF Mono** number + timer, mute/speaker/keypad, red End. Duplicated into the dialer cover because a root overlay renders below every cover. | `voice_push_handoff_failed` (CallController.swift:992) | 🔴 must render ABOVE covers (telephony.md trap 5); CallKit owns the lock-screen UI. |
| 12 | **Number settings** (sheet) | `LineSettingsScreen.swift` (151) | `SheetHeader` "Number settings"; card: Number + Minutes left; ghost "Change number"; "Rent another number" (accent-tinted capsule); "Important" 911 card. | — | 911 disclosure; **no Manage subscription here** (Account → Support only, telephony.md). |
| 13 | **Swap sheet** | `LineSwapSheet.swift` (509) | "Replacing {number}", numbers / countries / cities pages, confirm page (Current → New in **SF Mono 18**, Price + Your balance, "given up for good" warning, Switch or "Top up · N more credits" → `CreditsSheet`), done page (**SF Mono 20**). Errors inline. | `line_swap_open` (:428), `line_swap_numbers_shown` (:449), `line_swap_number_picked` (:458), `line_swap_confirm_view` (:307), `line_swap_topup_shown` (:293), `line_swap_result` (:485, :494) | price + balance + "given up for good" on the last page only; never offer what `begin_line_swap` refuses for money; needs `IAPStore` in env (crash otherwise). |
| 14 | Peer name sheet | `PeerNameSheet` (medium detent) | name a peer. | — | — |

Also on the funnel but outside the tab: `OtpScreen.keepNumberCard` (`line_upsell_shown` :480 / `line_upsell_tapped` :459) and the Verify tab's "Your own number" row.

### 1.3 States with no fixture

No fixture renders: the store's **picker sheet** (so `sendingNotice` has never been captured), the **top of the paywall** (hero number and US `capabilityNote`; the fixture scrolls past it and is Toronto, i.e. CA), the "Good to know" rows expanded, the store's unavailable state, the store as a cover, provisioning and provisioning-failed, the in-tab provisioning state, the **empty inbox (`proofOfLife`)**, **Recents** (full or empty), the **dialer**, **in-call**, **compose**, **settings**, the **swap sheet** (all five pages), the grace / past-due / suspended / failed banners, `VoiceReadinessNotice`, the multi-line switcher, and the FAB with the ResumeBar showing.

⚠️ **`lineStore` and `lineIntro` are byte-identical** (md5 `e2db14d4…` dark,
`723abd0f…` light). Since 2026-09-09 the numbers live in the sheet, and the
`lineStore` fixture seeds offers without opening it
(ContentView.swift:879-930). The fixture's own comment ("the store with real
numbers and the price on it") is stale on both counts. `verifyLine` no longer
shows any line surface except the tab badge (T8 removed the subscriber strip).

---

## 2. Critique per frame

Reference system (spec §5, `DesignSystem/`): gutter `RSpace.gutter` 16; spacing 4/8/12/16/24/32; cards `RRadius.card` 20, groups `RRadius.group` 14; 56pt capsule CTAs; one content elevation, **no drop shadows**; accent green **only** on the primary action; mint (`live`) = success; `.numberStyle` (`.monospacedDigit`) for every number, **SF Mono retired**; tab title `.displayType(30)` as on Verify (TempScreen.swift:261-262).

**Whole tab: zero use of the new tokens.** `RSpace` appears 4 times across all line files, all of them FAB or bottom-padding constants (LineScreen.swift:71-74, LineStoreScreen.swift:113-114). `RRadius.card` / `.group`, `numberStyle` and `selectedEmphasis` are used nowhere in the tab. The gutter is a literal `20` everywhere (LineScreen.swift ×6, LineStoreScreen.swift:101, LineCheckoutScreen.swift:85/236, LineRecentsView.swift:59/81, LineSettingsScreen.swift:23).

### 2.1 `lineIntro` / `lineStore` (store, no line) — dark and light

1. **Gutter is 20pt, not 16.** The card's left edge sits at x≈61 px (20pt); on Verify the segment and card edge sit at x≈48 px (16pt) (compare `mn-verifyLine-dark.png`). Switching tabs shifts the content column 4pt.
2. **Two headlines saying the same thing.** Title "A US or Canadian number that lives in this app" (:87) and, 90pt below, the card headline "A real American or Canadian number for your calls, texts and codes." (:269). "US" versus "American" in adjacent lines. The kicker "Second number" contradicts the tab label "My number" and the spec vocabulary "Your own number" (§4).
3. **The title style is off-system**: kicker plus `RFont.display(28)` with a hand tracking of -0.7 (:810-813), against Verify's `.displayType(30)` with no kicker. It is a third style after Verify and the paywall's `.displayType(29)` (LineCheckoutScreen.swift:252).
4. **Six green things on a screen whose only action is one button.** The filled CTA, four accent-tinted icon tiles (`BenefitRow`), and the mint seal plus "Great for WhatsApp" (:239-245). Mint `#0E9F6E` and accent `#279400` also sit side by side: the "Receive verification codes" tile is mint (:319) and its neighbours are accent. Two greens one row apart read as a rendering mistake, not as semantics.
5. **The card radius is 22** (`Card` default `RRadius.lg`, Card.swift), and the `usSoon` note and the ghost button are 18 or a capsule. Nothing on the screen uses 20 or 14.
6. **Drop shadows.** `Card(elevation: .raised)` (:229) casts a visible shadow in light (`mn-lineIntro-light.png`, under the pitch card). The spec says none.
7. **Dead vertical void.** About 110pt of empty space between the reach note and "Just need a one-off verification code?" (y≈1515-1630 display): `Spacer(minLength: 24)` inside a `minHeight` frame (:97, :113). The escape button then reads as orphaned chrome floating above the tab bar.
8. **The reach note looks disabled.** `usSoon` (:878) is a grey `chipBg` card with a flag icon in `text2`, the same weight as the ghost button beneath it. A load-bearing honesty line has the lowest contrast on the screen.
9. **Hairline rules run to the card's trailing edge** while the text inset is 54 (:287). That is fine in native lists, but here the rows are inside a rounded card with 16pt padding, so the rules hit the curve (x≈874 display).
10. The body copy names **TikTok and DoorDash** (:279) and the empty inbox repeats them (LineScreen.swift:567). Owner decision D3 (spec §3) measured only WhatsApp as meeting the bar. This is copy, but §6.10's "Has received codes from" row depends on it.

### 2.2 `linePaywall` / `linePaywallYearly` — dark and light

1. 🔴 **The intro price is the most prominent figure, against D4.** `priceBlock` renders `$3.99` at `.displayType(30)` with "first month" (:790-799). The billed `$5.99` appears only at 15pt in the plan row (:767-770) and inside a 12pt sentence. The CTA sub repeats "$3.99 first month" (:951-954). Spec §6.10 / D4 require the reverse: "{regular}/month" at plan size, intro subordinate beneath.
2. **SF Mono in the CTA.** "$3.99 first month" and "$59.99/yr" render in `RFont.mono(15)` (Buttons.swift:60). The typewriter "first month" beside SF Pro "Subscribe" is the most visibly off-brand element in the tab. The hero number is also mono 31 (:429).
3. **Eight accent elements** (dark frame): the selected radio, the selected border and tinted fill (:730-736), the intro note in `theme.ink` text (:762), the SAVE 17% badge (:750-756), the price-block border and fill (:786-787), the icon tile, both legal links tinted `ink` (:891) and the CTA. The emphasis rule (only the selected option gets a border or fill) is broken twice: the price block is a second bordered, filled "selected" surface directly under the selected plan.
4. **"Cancel" is said twice, differently.** "Cancel any time in your Apple ID settings." (price block, :830-837) and "Cancel any time in Settings" (under the CTA, :919). Spec §6.10 wants one sentence under the CTA: "{intro} first month, then {regular}/month. Cancel anytime in Settings."
5. **The header clips content like a torn page.** The ✕/Restore row is a plain `HStack` above the `ScrollView` (:48-49) with no material or hairline, so the "What you get" card is cut flat at y≈255 display with its rounded top missing. The spec wants a glass or `.bar` header on sheets and CTA trays.
6. **Restore is a 13pt `text2` word in the corner** (:229-231), and Terms/Privacy are two green 12pt links far from the CTA (:884-891). Spec §6.10 groups Terms of Use (EULA), Privacy Policy and Restore purchases as one link row.
7. **Dead band above the CTA.** About 83pt between "Privacy Policy" and the CTA, made of the `BottomBar` scrim (56, BottomBar.swift) plus padding. On top of that the fixture's forced scroll (:100-104) hides the hero, so **no frame shows the number being bought or the US capability note**.
8. **The radius mix on one screen**: `HeroCard` 28 (`RRadius.xl`), the ledger `Card` 22, the plan rows, price block, capability note and 911 card 18 (`RRadius.md`). None are 20 or 14.
9. **"Good to know" looks like navigation, not disclosure.** `MicroLabel` has `maxWidth: .infinity` (BottomBar.swift `MicroLabel`), so the chevron is pushed to the far trailing edge (x≈858 display) and reads as a push row. It also sits between the price and the CTA, the exact adjacency the code comments (:78-81) say must stay clear.
10. **The yearly row shows no per-month equivalent and the monthly row no period.** "$5.99" and "$59.99" appear without "/month" or "/year" in the rows (:767). Only the block beneath says "per year".
11. **Shadows in light**: the ledger card casts a shadow (`mn-linePaywall-light.png`, y≈470 display).

### 2.3 `lineInbox` (live line, Messages) — dark and light

1. **The subscriber's home leads with a money action.** A full-width accent-filled 56pt "Change number" (LineScreen.swift:112, `style: .primary`) is the biggest object on screen, above the inbox. It is a paid 8-credit swap that *gives up the number for good*. With the green FAB, the green unread dot (:781) and the tab tint, that makes four accent elements.
2. **Misaligned column.** `SegmentedTabs` is padded 16 (:129) while the header, Change number and thread rows are padded 20 (:113, :294, :538). The segment's edge sits at x≈48 px, the rows at x≈61 px, visibly offset in both frames.
3. **No screen title at all.** Verify opens on a 30pt question; this tab opens on a 17pt mono number in a bar. A new subscriber is not told where they are.
4. **SF Mono** on the header number (:248) next to SF Pro thread titles, and on the code chip (:761). The two numbers in the same viewport are in two faces.
5. **The icon chips are 36pt** (:303), under the 44pt minimum, three in a row plus a status dot, and Copy is duplicated (tap-to-copy number plus Copy chip) beside an instruction line that repeats it ("Tap the number to copy it", :337).
6. **Unread is signalled three times**: the tab badge "2", the segment count "2" (in `text3`, too faint to register, SegmentedTabs.swift) and a green row dot.
7. **Cards per row instead of a grouped list.** Each thread is its own 16-radius card with 8pt gaps (:524, :786). That is neither `RRadius.card` 20 nor the spec's native lists and 14pt groups. The avatars are anonymous person glyphs on arbitrary hues, which are the loudest colour on the screen.
8. **The FAB floats in a 500pt void** above the tab bar (y≈1600-1737 display). With three threads the screen is two-thirds empty, and nothing in that space teaches anything.
9. **The segment order fights the default**: Recents | Messages, opening on Messages (:93, :124-128). The right-hand segment is the home.
10. The custom `SegmentedTabs` (a `chipBg` track with a shadowed thumb) is a hand-rolled segmented control inside a native `TabView` shell. Spec §5 says native bones.

### 2.4 `thread` — dark and light

1. **A cover, not a push.** The thread opens as a `fullScreenCover` with ✕ (ContentView.swift:723), so the tab bar vanishes, there is no swipe-back, and the ✕ says "dismiss" for what is a drill-in.
2. **The number format disagrees with the list.** The header reads "+1 (888) 555-0111"; the inbox row reads "(888) 555-0111".
3. **Green Copy chips under every code** are accent-filled secondary actions (they are the main affordance, but they repeat, and with the green tab and send button that makes several accent elements).
4. **Alignment**: bubbles start at x≈37 display, timestamps at x≈46 (`.padding(.horizontal, 4)` ×5 in ThreadScreen.swift). Two left edges.
5. The composer has a disabled grey send circle and an always-on "142 texts left this month" footer (ThreadScreen.swift:341), while checkout deliberately sells no texts-per-month figure (LineCheckoutScreen.swift:491-497). A metered cap nobody was told about appears only after purchase.

### 2.5 Screens with no frame (critique from code)

- **Recents**: 🔴 **double gutter.** `strip` already has `.padding(.horizontal, 20)` (LineRecentsView.swift:81) and sits inside a `LazyVStack` that is padded 20 again (:59), so with any calls the allowance strip is inset **40pt** while the rows are inset 20. Rows are 16-radius cards (:283) and the action tiles are 12 (:299). Missed calls tint the whole name red (:249), the one place in the tab that uses `fail` for a normal event.
- **The allowance's reset date is shown nowhere.** The only caller passes `showsResetDate: false` (LineRecentsView.swift:90), justified by "The hero header already states the renewal date" (:78-80). That has been false since 2026-09-01 (LineScreen.swift:322-324). Settings shows only "Minutes left" (LineSettingsScreen.swift).
- **Settings sheet**: three differently styled actions stacked. A ghost "Change number" (capsule, `chipBg`), then "Rent another number" as an accent-tinted capsule (`inkSoft`, LineSettingsScreen.swift `rentAnotherSection`), then the 911 card in muted `text2` with an unfilled triangle, weaker than the same disclosure on the paywall (`warnSoft` card).
- **Dialer / in-call / compose / swap / provisioning**: all use SF Mono for numbers (DialerScreen.swift:214, InCallOverlay.swift:89/95, ComposeScreen.swift:150, LineSwapSheet.swift:324/404, LinePickerRows.swift:338, LineProvisioningScreen.swift:115). The dialer's call button is `live` mint (DialerScreen.swift:311), which is semantically "success", not "action".
- **FAB × ResumeBar**: the FAB is inset `RSpace.xl` from the safe area (:71), and `resumeBarInset()` is applied to every tab (ContentView.swift:129-142). With an order in flight the ResumeBar and the 60pt FAB stack in the bottom-right corner. Unverified, since no frame exists (`waitingClosed` is captured on Verify).
- **In-tab provisioning** (LineScreen.swift:468-483) and the provisioning cover (LineProvisioningScreen.swift) are two different designs for the same state.

---

## 3. Structure notes (what a user finds confusing)

1. **Two different tabs behind one label.** A non-subscriber gets a marketing page whose kicker says "Second number"; a subscriber gets a phone app with no title. The tab label "My number" fits neither, and to a non-subscriber it implies they already have one.
2. **The store hides the product behind a button, then a sheet, then a cover.** Numbers are in a sheet (country chips, then Change → cities, then numbers). Tapping a number dismisses the sheet and opens a full-screen paywall (LineStoreScreen.swift:501-502). That is three presentation styles in one purchase. The US sending warning lives only in that sheet and on the paywall, never on the page a reader lands on.
3. **Price appears nowhere until the paywall**, while the swap's credit price is on the store's first screen (:339-342). The only figure a shopper sees before choosing is the cost of *replacing* the number.
4. **The subscriber's primary action is destructive and paid.** "Change number" is the hero button; Share, Copy and Settings are 36pt chips. A first-week subscriber can reasonably read "Change number" as "choose your number" and burn 8 credits plus their number.
5. **Messages and calls are split as segments, but the FAB changes meaning with them** (compose vs keypad, :427-438). On Recents without a voice client there is no FAB at all, so the same corner is sometimes empty. Recents carries the minutes meter; Messages carries no texts meter (that is only in the thread composer).
6. **Settings hold almost nothing.** The number, the minutes, a second "Change number", "Rent another number" and 911. No Manage subscription (it is Account → Support only; spec §6.10 wants it here). No renewal date, no reset date. The grace banner says "Update it to keep your number" (:668) with no button to do so anywhere in the tab.
7. **Every sub-screen is a full-screen cover with ✕** (thread, compose, dialer, checkout, provisioning, store-more), so there is no back navigation, the tab bar disappears for a simple drill-in, and the in-call overlay has to be duplicated into covers (telephony.md trap 5).
8. **Two provisioning screens and two 911 treatments** (paywall `warnSoft` card; settings muted card; dialer line) for one fact each.

---

## 4. Load-bearing items the overhaul must carry (checklist)

- 🔴 `LineStoreScreen.unreliableSendingCountries` stays the ONE list, read by the store notice, checkout's uncollapsed `capabilityNote` and the thread's failed-send copy. Removing the warning means `force_block` US and PR in the same commit.
- 🔴 **Copy defect to resolve with the owner before restyling:** all three surfaces say "A Canadian number sends texts reliably" (LineStoreScreen.swift:575, LineCheckoutScreen.swift:349, ThreadScreen.swift:554), and the CA branch says "Texts you send from a Canadian number arrive normally" (LineStoreScreen.swift:594). CLAUDE.md (corrected 2026-09-24) records **CA→US at 0 of 8, all `40010`**: "a Canadian number is NOT a workaround". The swap sheet shows **no** sending notice at all when a swap moves the line into US/PR (`LineSwapSheet.swift` has no reference to the list).
- 3.1.2(a) on the paywall: renewal price and period, the renewal sentence, **Terms of Use (EULA)**, **Privacy Policy**, **Restore**; D4 inverts the current price hierarchy; the intro stays behind the eligibility gate.
- 911 disclosure on the paywall, in settings and in the dialer.
- "Good to know" stays on the purchase screen.
- Swap: no price on the button; price, balance and "given up for good" on the confirm page; Top-up path; `IAPStore` in the sheet environment.
- Suspended banner must not promise the number back; banners stay on the main surface.
- Hidden-not-disabled rule for the keypad FAB and call-back glyphs.
- In-call UI renders above covers.
- Every event in §1.2 keeps its name and props; `CheckoutVisit` stays a static.
- No credit pill on the store; no hardcoded prices (StoreKit `displayPrice` only; `lineSwapCredits` has no client default).
- Fixtures: fix `lineStore` (open the picker sheet) and add frames for the paywall top on a US number, the empty inbox, Recents, settings, the swap confirm page, the dialer and the banners, per spec §9.
