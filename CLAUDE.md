# CLAUDE.md

Guidance for Claude Code working in this repository.

## Where things live

This file is loaded **in full, on every request**. It holds the product shape,
the money paths, the rules whose violation costs cash, and what is currently
open. Everything that only matters while a particular file is open lives in a
scoped rules file that loads automatically for that surface.

| Surface | Loads when | Holds |
|---|---|---|
| **this file** | always | product shape, money paths, gotchas, open issues, provider split, commands |
| `.claude/rules/providers.md` | editing `supabase/functions/**` | 5sim / HeroSMS / Telnyx API behaviour, both pricing syncs, the sellable-number catalogue |
| `.claude/rules/ios-client.md` | editing `VirtualSIM/**` | source layout, palette + Liquid Glass, cold launch, the map's per-frame trap, localization, order-state invariants |
| `.claude/rules/telephony.md` | editing the line / Telnyx / calling code | calling, inbound routing, swaps, the line country catalog, international rates |
| `.claude/rules/ops-bot.md` | editing the Telegram bot | the command registry, formatters, alert shapes, the announcement banner |
| `docs/decisions-archive.md` | never — open it deliberately | the changelog, resolved issues, superseded reasoning |
| `release-prep` skill | cutting a release | archive → patch → export → upload → ASC submission |
| `aso-listing` skill | touching the listing | keywords, screenshots, storefront metrics |

⚠️ **What deliberately did NOT move.** Everything safety-critical stays here,
because a scoped file is not in context when it is not matched: the money
paths, `Non-obvious gotchas`, `Known-open`, the pricing model and margin gates,
and the provider-switch checklist. **Never move a "never do X" rule into a
scoped or lazy surface** — it has to be loaded at the moment it matters, which
is exactly when nobody has the relevant file open.

🔴 **Verify before you trust this file.** When acting on something asserted here
— a file location, a function name, a flag, a state ("this is already fixed") —
confirm it against the code or the live system first, and correct the file when
it is wrong. This is not defensive boilerplate. An audit on 2026-09-09 of the
then-6,400-line version found `blocked_routes` documented as empty while it held
6,393 entries, four retired cron jobs listed as "still running" when they no
longer exist, three live cron jobs documented nowhere, a "this code is not dead"
refutation that had itself gone stale, and a constant documented in three files
that lives in four. **A stale line here is read as current, which turns a
documentation error into a decision error** — work gets skipped because the file
says it is done, or redone because the file says it is not.

## What this is

**vSMS** (App Store name; the Xcode target/scheme is still `VirtualSIM`) — an
iOS app selling four things:

| line | billing | state |
|---|---|---|
| **rented second numbers** — a US/CA number the user keeps, with SMS and calling | **StoreKit subscription** ($5.99/mo, $59.99/yr) | live; a need-card on Home for anyone without a line (first while `launch_tab = line`) |
| **temporary phone numbers** for SMS verification codes | credits | live, the original product |
| **temporary e-mail addresses** | credits + a $2.99/mo subscription | live |
| **eSIM data plans** | credits | 🔴 **PERMANENTLY PARKED** — see below |

SwiftUI client + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).
Bundle id `com.anthersystems.VirtualSIM` · Supabase ref `enugzltysdmjzavisloy` ·
the project root holds `Appidea.md`, the original product brief.

🔴 **The eSIM line is permanently parked (owner decision 2026-08-29): that
business moved to a SEPARATE app.** Do not propose resuming it, do not propose
the top-up, do not build on it here. The infrastructure stays as-is on purpose —
kill switches hold it off, the nightly sync is harmless, and `check-esim-usage`
still serves the 12 legacy eSIMs sold before the provider switch.

### Home leads the app (2026-09-10)

**Superseded on branch `design-overhaul` (2026-09-24):** tabs are Verify · My
number · Activity · Account in a fixed order (the `Tab` declaration order in
`ContentView`'s native `TabView`; `AppTab.order` mirrors it); `/tabs` no longer orders anything in builds from this branch — the
value is still stored, never applied. **The Verify tab's ROOT is the temp code
store (`TempScreen`), owner decision 2026-09-24** — on a grid-first Verify
screen a new user never learned temp e-mail exists; the store's Number /
E-mail segment says so on screen one. Its header is "What do you want to
verify?" in both modes, with no Recent list (the Activity tab owns history).
Every former "go to Temp" entry point calls `AppState.openCodeStore(email:)`,
which selects the Verify tab and the mode; nothing is pushed (`VerifyRoute` /
`verifyPath` are gone). On this branch `HomeScreen`, `home_view` and
`home_card_tapped` (from Home) are retired, and so are the grid
`VerifyScreen` / `VerifyTile` that briefly replaced them with their
`service_selected{source: verify*}`, `verify_line_row_tapped` and
`service_search_empty{source: verify}` events. `verify_view {guest, has_line,
lines_loaded}` still fires on every visit, from the store root in
`ContentView` — but NOT when a flow cover (checkout, waiting, code…) that went
up over Verify closes back onto it (`coverOpenedOnTab`); a cover that closes
INTO Verify from another tab still counts (`AccountScreen`'s `invite` /
`vroam` arms of `home_card_tapped` still fire). **The announcement banner
renders under the Verify root's header (`TempScreen`) on this branch** — Home
is gone and that root is the first screen of every cold launch; main's "do not
re-add it to `TempScreen`" rule below describes main.
**The launch splash is ONE instance on this branch** (`LaunchCover`, hosted by
`AuthGate` above the session bootstrap and `ContentView`; owner-chosen "calm
wordmark", 2026-09-24): the mark is drawn in full on the first frame and
breathes, the progress line fades in at 1.5 s and the caption at 3.5 s, and on
`bootPhase == .ready` it hands off in 0.5 s (mark glides up, cover fades,
taps pass through at once) while the store's `riseIn` plays on the reveal. The
launch screen now really is `theme.bg` (see the `INFOPLIST_KEY_` gotcha).
Detail in `.claude/rules/ios-client.md`, "Cold launch". ⚠️ Verified from
fixture stills and a `splashHandoff` recording, and the breath stopping in
the failure state from pixel-identical `splashFailed` burst stills; a real
signed-in cold launch was not recorded, and the Reduce Motion paths and the
maintenance remount fade are code-verified only.
Fixtures on this branch: `verify`, `verifyLine`, `activity`, `waitingClosed`,
`account`, `splash` / `splashSlow` / `splashFailed` / `splashHandoff` (the
launch cover pinned calm / with the line and caption / on the failure footer /
lifted by a real `bootPhase` flip 2.5 s in, for a screen recording), `announcement` (the root with a synthetic
warning banner), `emailLoading` / `emailReady` / `emailFailed` (the E-mail segment
with its domain quote pending / answered — same geometry — / failed with
nothing to show; see "The temp-e-mail product",
which also covers the cold-start e-mail prefetch); `home` is an alias of
`verify` (`homeRouter` / `homeLine` below are main's names). My number: `lineIntro`, `lineStore`, `lineStoreError`,
`linePaywall` / `linePaywallYearly` (a Canadian number, Toronto),
`linePaywallUS`, `lineInbox`, `lineInboxEmpty`, `lineInboxMulti`,
`lineCalls`, `lineNumber`, `lineBanner`, `lineSwapConfirm`, `lineDialer`,
`thread`, `threadResume` / `composeResume` (a pushed thread / compose page
with a temp-SMS order in flight: ResumeBar must be hidden), `lineInCall`,
`linePushThread`, and `lineSwitchGlow` (its Switch lands through a
DEBUG-only hook, so the frame catches the card's glow mid-fade). Detail in
`.claude/rules/ios-client.md`, "The My number tab".
The text below describes `main`.

`AppTab` order is `home · line · temp · account` and the app opens on
**Home** on EVERY cold launch, new or returning (owner decision 2026-09-10) —
`.home` is element 0 of every `launchOrder` variant BY CONSTRUCTION, so
`AppTab.currentOrder.first` is `.home` whatever `/tabs` says. Home is
`Screens/HomeScreen.swift`: a **router** for a user with no live line —
"What do you need?" and three equal cards named by NEED (a code for an app →
Temp SMS; a throwaway email → Temp e-mail; a number that's yours → the Number
store, priced only from StoreKit) — and a **light dashboard** once a live line
exists (the number, unread and missed counts, Messages / Call), plus the
sections listed below. Every card jumps to the EXISTING screen; nothing is
rebuilt inside Home. No waiting-order
card either: `ResumeBar` already floats above the bar on every tab. The Temp
tab is `Screens/TempScreen.swift` (enum case `.temp`, label "Temp", hosts temp
SMS + temp e-mail via `emailMode`). ⚠️ `TempScreen`'s analytics still fire
`source: "home"` (`support_whatsapp_open`, `MailPaywallScreen`) — kept for
series continuity; there, "home" means the TEMP tab, never the Home tab.

**What Home holds, top to bottom (CUT DOWN 2026-09-21 — owner decision).** A
greeting by daypart and name; the headline ("What do you need?" / "Your
number"); then ONE stack in `AppTab.productOrder` holding the **static
seven-service logo grid** plus a More tile under "Get a code for" (the
`.temp` slot) and the **Number card** (the `.line` slot, absent for a
subscriber, carrying a Calls · Texts · App codes chip row and a price only
StoreKit ever supplies), with the **e-mail card** following the grid; then
**How it works**, COLLAPSED, until the user has any order, then **Recent**.
The whole screen now fits one iPhone 17 Pro viewport without scrolling.

🔴 **Four things were REMOVED and none of them should come back without the
owner.** Measured over the 301 users who had ever seen Home:

- **The "A code for an app" need-card, folded INTO the grid.** Home asked the
  same question twice in two vocabularies — an outcome card immediately above
  a brand grid — and the card was the worse of the two, landing on Temp with
  nothing selected so the user still owed a `ServiceSheet` trip, while a tile
  pre-fills the service. The fold removed a decision AND a step. "My app isn't
  here" is the More tile (50 taps / 39 users).
- **The outer section header** ("Pick one" / "Need something else?"). It sat
  directly above the grid's own "Get a code for" — two headers in a row, in
  BOTH states. ⚠️ Caught in the simulator, never by reading the code: capture
  `-screenshot homeRouter` and `homeLine` after any change to Home's section
  order.
- **The invite card → `AccountScreen`** (3 taps from 3 users, ever — 1%).
  Account already owned the canonical copy, so nothing was lost; its Share
  button gained the `invite` event it never had, or the arm would have read as
  the invite loop dying rather than moving.
- **The vRoam card → `AccountScreen`** (17 taps / 8 users against 5 dismissals
  / 5 users). `PrefKey.vroamCardDismissed` is deliberately unchanged by the
  move, so anyone who already dismissed it is not shown it again.

⚠️ **Analytics consequence, and do not misread it.** `home_card_tapped`'s
`sms` arm STOPS at this release — that intent now arrives as
`service_selected{source:"home"}` or `more_services`. `invite`, `vroam` and
`vroam_dismissed` keep firing under the same event name from the ACCOUNT tab,
so the series continues rather than restarting at zero; from here those three
arms mean Account, not Home. Same documented compromise as `TempScreen`'s
`source: "home"`. A step change in any of the four is THIS, not behaviour
moving.

⚠️ **Card order still follows `/tabs`, so at `launch_tab = line` the Number
card renders ABOVE the grid.** `AppTab.productOrder` is the one definition and
Home may never hardcode an order; `/tabs temp` puts codes first. That is a
config flip landing on the user's second cold launch, not a code change.

Three properties that reading the screen does not give you:

- 🔴 **A grid tap is the USER'S pick, not a pre-selection.** It goes through
  `AppState.commitServicePick` — the same path `ServiceSheet.onPick` uses — so
  `needsServiceChoice` clears and the order is not `from_default`. ⚠️ It DOES
  write `lastCountry` when `pickDestination` resolves one (that is the steer the
  tapped row printed), but it **never clears `needsCountryChoice`** — and that
  flag is what `TempScreen` renders "Not selected" from and what
  `confirmGetNumber` refuses on. So the tap lands on Temp with the Country row
  still unanswered, which is what keeps "Nothing is pre-selected on first run"
  true with seven logos on the opening screen. The More tile opens the real
  picker.
- **Recent is a signpost, not a second Orders screen.** At most three rows,
  both products merged newest-first, each opening through `AppState.openOrder`
  / `openEmailOrder` — the same openers the Orders tab uses, never a second
  copy of that routing.
- **How it works is a COLLAPSED disclosure, and deliberately not persisted.**
  Three numbered steps explaining a flow the user has not started is the same
  "teaching before being asked" mistake `DeliveryInfoSheet` makes; it stays on
  the screen because a first-run user may genuinely not know what the app is
  for, but it stays SHUT. Re-collapsing next launch is correct — by then the
  user has read it or stopped needing it — and a `PrefKey` here would be a
  device-global flag maintained forever for a row that costs one tap.

🔴 **The greeting name is NOT the `display_name` column.** `handle_new_user()`
seeds it `coalesce(raw_user_meta_data->>'full_name', split_part(email,'@',1))`,
so on 2026-09-10 **1,641 of 1,643** profiles carried a handle-SHAPED value —
lowercase letters, digits, `. _ -` and nothing else — against 2 blank. Read that
as shape, not as proof of equality: the same regex also matches an Apple sign-in
whose `full_name` is a real lowercase first name, which is a value we SHOULD
greet by. Either way, greeting from the column unfiltered means saying
"Good morning, adil.hamidii123" to almost everybody.
`AppState.greetingName(email:)` therefore refuses a value that is empty,
contains `@`, or equals the address's local part case-insensitively — equality
against *this* user's own address, which is the test a catalog-wide count cannot
stand in for — and nil means the NAMELESS greeting, never the handle. 🔴 **With
no e-mail to compare against it FAILS CLOSED** (nil, 2026-09-10): `Session.email`
is nil for a session restored from an install predating the Keychain e-mail key
and for a refresh payload carrying no user e-mail, and skipping the comparison
there greets almost the whole table by its handle — the exact outcome the
function exists to prevent.
`NameSheet` mirrors the same three rules on the string being typed, because
`greetingName` judges the STORED profile and the sheet has to judge one that
has not been written yet — keep them in step, or the sheet offers a save that
changes nothing on screen. Re-derive all three numbers rather than quoting them:
```sql
select count(*) total,
       count(*) filter (where display_name ~ '^[a-z0-9._-]+$') handle_shaped,
       count(*) filter (where coalesce(trim(display_name),'') = '') blank
from profiles;
```

**Apple hands over a given name exactly ONCE.** `AuthWelcomeScreen` parks it in
`pref.pendingDisplayName` at the FIRST authorization for an Apple ID and never
sees it again, and `applyPendingDisplayName` flushes it onto `profiles` BEHIND
the reveal in `coldStart` — a greeting is a label, and no round-trip that only
improves a label may hold the first screen. The key survives a FAILED write so
the next cold launch retries it; a write that lands ON THE PARKING ACCOUNT
clears it, so a name the user typed in `NameSheet` is never overwritten by
Apple's on a later boot.

🔴 **The park is bound to the account it came from, in `pref.pendingDisplayNameUserId`
(2026-09-10), and that binding is the only thing making the flush safe.**
`UserDefaults.standard` is DEVICE-global and survives sign-out — `Session.signOut`
clears the Keychain, not this — so an unflushed name parked by user A was
otherwise PATCHed onto user B's `profiles` row the first time B cold-launched on
the same device, and B was greeted by A's name. `display_name` is the only column
the client can write, so that is the whole blast radius, but it is still one
user's data on another user's row. Both keys are written together, read as a
pair and dropped as a pair. A parked name whose owner is a DIFFERENT signed-in
user is kept and skipped (that account can sign back in; holding it costs a
UserDefaults read, never a PATCH); one with NO owner — parked by a build before
the key existed — is dropped, because it can never be matched to anybody and
retrying it would re-ask an unanswerable question on every launch forever.

**Two things joined the bottom of Home on 2026-09-15** (owner decisions), both
below the invite card so neither competes with the router:

- **The announcement banner MOVED here from the Temp tab**, and sits directly
  UNDER the greeting — above every card, since an outage notice outranks them,
  but after the greeting rather than in front of it. It is
  a reach win, not a lateral move: `.home` is element 0 of every `launchOrder`
  BY CONSTRUCTION, so every cold launch sees it, where Temp was seen only by
  people who went looking. 🔴 **Do not re-add it to `TempScreen`** — two copies
  would both be dismissible and the second would read as a bug. It is also
  bigger now (16pt text, tinted fill instead of a hairline) and **has no
  megaphone icon**: a decorative "loud" glyph on every notice makes routine
  news look like an alarm and then a real alarm look routine. The
  `exclamationmark.triangle.fill` survives for `isWarning` ONLY, where it
  carries meaning — do not "restore consistency" by giving the normal case an
  icon back.
- **A vRoam cross-promotion card**, linking out to the owner's separate
  travel-eSIM app (`id6806653317`, `com.adyl.vRoam`). 🔴 **It is a link OUT and
  must stay one** — it touches none of the parked `esim_*` infrastructure, and
  if it ever needs to know anything about vRoam's catalogue that is the signal
  it has become the thing the eSIM park exists to prevent. Dismissible via
  `PrefKey.vroamCardDismissed` (device-global, survives Delete Account,
  deliberately not versioned — bumping it would re-show an advert to someone
  who already declined).
  🔴 **Its `$0.99` is vRoam's PUBLISHED floor, copied from that app's own
  listing on 2026-09-15, and vSMS cannot keep it honest** — vRoam can reprice
  without a vSMS release. Same class as `inviteJoinerCredits` and the
  onboarding credit amount. It is ONE literal in ONE place; re-check it
  whenever either app ships. ⚠️ The owner asked for *"up to 70% cheaper"* and
  that was declined in favour of a concrete price: vRoam's own listing makes
  no percentage claim, so it would have been a new unsubstantiated one, and
  the app's only organic review is already someone angry that a promise did
  not hold.

Home's own events are `home_view` (`has_line`, `has_orders`) and
`home_card_tapped` (`card` ∈ email · line · line_messages · line_call ·
credits · more_services · recent_sms · recent_email — plus invite · vroam ·
vroam_dismissed, which fire from **`AccountScreen`** since 2026-09-21 under
this same event name so their series survives the move). 🔴 **`sms` is
retired**: that card was folded into the grid, so the intent is
`service_selected{source:"home"}` or `more_services`. ⚠️ `vroam_dismissed` is a
REJECTION riding the same event so
the two can be read against each other — read the RATIO, since a card tapped
20 times and dismissed 400 costs more attention than it earns. A grid tap fires
`service_selected` with `source: "home"` instead — the picker sends `sheet` or
`search` — and `display_name_set` carries `source` `home` (the user typed it)
or `apple` (the parked name, flushed at launch).

⚠️ **`home_view` under-reports `has_orders` for an e-mail-only user.** It fires
in `onAppear`; `loadOrders` runs BEFORE the reveal and `loadEmailOrders` after
it, so a user whose only history is e-mail is logged `has_orders: false` and
then watches the section swap How-it-works → Recent a beat later. Read the prop
as "had SMS history at the first frame", not as "had no history". Deliberate —
history does not earn a place on the boot critical path.

🔴 **`home_view.has_line` has the same first-frame flaw, and it nearly caused a
wrong conclusion.** `hasLine` is `linesLoaded && isLive`, so a subscriber whose
`my_line` read is still in flight logs `false` — on 2026-09-16 one who swapped
three times logged 0 true / 8 false. **From 2.16, `home_view` carries
`lines_loaded`; trust `has_line` only where it is `true`.** Events from 2.15 and
older have no such prop, so their `has_line` proves nothing on its own — read
`home_card_tapped` (`line_messages`/`line_call` only render for a live line)
instead.

**Why a router.** Measured on the first session of the 241 users who signed
up 2026-09-04 → 09-10 (live build 2.11 landed on Temp): 70 stayed on Temp
(2 opened support), **68 bounced Temp → Number (11 opened support)**, 61
stayed on Number (7 did nothing), 27 touched neither (20 did nothing), 15
went Number → Temp. A quarter of new users bounced, and that cohort produced
11 of 15 support taps. Onboarding already described three products over four
pages and did not prevent it. Re-derive with the first-session path query in
`docs/decisions-archive.md` (Home tab, 2026-09-10) rather than quoting this.

**The history still binds.** Leading with the line in 2.0 (Aug 15–19) took
`create-order` from ~30 calls/day to 1, and the two audiences have never
overlapped. Home is the first landing that does not pick a product FOR the
user. Read `home_card_tapped` by `card` and the first-session bounce table
after 2.13 is adopted; if Temp-first users stop reaching Temp, that is the
2.0 shape again and the card order is the first lever.

✅ **`/tabs number|temp` survives and means "what sits BEHIND Home".** It
writes `app_config.launch_tab` (RLS whitelist) and the client's ONE
definition, `AppTab.currentOrder`, yields `[.home, .line, .temp, .account]`
or `[.home, .temp, .line, .account]`; `AppTab.productOrder` is that list
filtered to the two product tabs and is what Home's cards render in (the
e-mail card always follows the SMS card, both live on Temp). Three properties
that are not derivable from the code:

- 🔴 **It is read from UserDefaults at LAUNCH, never live.** `refreshAppStatus`
  runs AFTER `bootPhase = .ready` in `coldStart` (a banner is additive and must
  not hold the reveal), so there is no server value when the bar first draws. A
  live read would reorder the tabs under the user's thumb a beat after launch.
  The fetch STORES it; the next launch READS it.
- **So a flip lands on the user's SECOND cold launch**, and `/tabs` says so in
  its own reply. Do not "fix" this by moving the fetch before the reveal
  without measuring what it costs the boot chain.
- **Fails to the compiled default.** An absent or unrecognised value clears the
  stored copy and the build uses `AppTab.defaultOrder` (Home · Number · Temp
  · Account). Client-side: 2.12 and older ignore the Home tab entirely (2.12
  reads the key for a Number/Temp bar; 2.11 and older keep their compiled
  order).

🔴 **`AppTab.home` WAS the Temp tab until 2026-09-10** (label "Temp", house
icon). It was renamed to `.temp` in its own commit BEFORE the new `.home`
existed, so the compiler listed every `state.tab = .home` site; a single
commit doing both would have let a missed site compile and route to the wrong
tab. Any doc or comment that still says ".home hosts Temp" is stale — fix it.

### 🔴 The two product lines have never once overlapped

Measured 2026-09-09, and it reframes every conversion argument about this
product:

| | |
|---|---|
| line subscribers, all time | **19** |
| …who ever placed a temp-SMS order | **1** |
| …who ever received a code | **0** |
| users who received a code in the prior 30d | **69** |
| …who ever opened the number store | 21 |
| …who ever subscribed | **0** |

**Every subscriber this product has ever had arrived cold and bought without
touching the free product, and nobody who has seen the product work has ever
bought.** The mechanical reason was that `OtpScreen` — the SMS line's success
moment — sold nothing at all, while `EmailCodeScreen` has sold the mail plan at
the identical moment since 2.3. `OtpScreen.keepNumberCard` (2.12) is the
missing offer: one quiet card below Done, no price, gated on `linesLoaded` and
no live line. Events `line_upsell_shown` / `line_upsell_tapped`.

⚠️ **0 of 69 is NOT evidence these users won't pay — 48 of them never saw the
offer.** Read it at ~100 `line_upsell_shown`: near-zero taps means the audiences
really are disjoint and the answer is to STOP cross-selling, not to shout louder.

⚠️ **The funnel bottleneck is the payment moment, not traffic** (14d to
09-09): 266 users saw the store → 133 saw numbers → 72 reached checkout → **19
opened Apple's sheet → 3 paid**. **Adding traffic to this funnel does nothing.**
A monthly free trial was the obvious lever and the owner declined it on
2026-09-09 (numbers cost $1 each upfront, and 17 of 20 cancel at the sheet).

🔴 **NOTHING RENEWS. There are THREE `DID_RENEW` notifications in the entire
history of the product, the last on 2026-09-08** (measured 2026-09-21 over
`line_notifications`; that week produced 25 `SUBSCRIBED` and **zero**
renewals). 19 of 30 active line subscriptions have auto-renew off, and the
cancellations are not churn — they are immediate: of 29 `AUTO_RENEW_DISABLED`
events, **11 land within ONE HOUR of subscribing and 21 within a day.**

**So the line is not a subscription business; it is a one-month number
rental, and every calculation that assumed a second month is wrong.** The
concrete casualty is the intro offer's own justification, recorded below as
*"the $3.39 net covers the $1 number"* — **the number costs $2.00**, measured
from Telnyx's own refusal, so the real arithmetic is $3.99 gross → $3.39 net
→ **$1.39 once, forever.** Over the 7 days to 2026-09-21 that was 14 line
subscriptions (~$57 gross, ~$48 net) against **$28.00 of Telnyx numbers** —
a 58% cost ratio, where credit packs ran 9%. ⚠️ Do NOT read this as "raise
the price" on its own: it is the owner's call, and $3.99 was set as a floor
(2026-09-10). It IS the reason to re-open the question, because the premise
has been measured false. Re-derive before acting:
```sql
select notification_type, count(*), max(created_at)::date from line_notifications
 where notification_type in ('DID_RENEW','SUBSCRIBED') group by 1;
```

✅ **`line.monthly` carries a $3.99 FIRST-MONTH intro offer since 2026-09-10**
(owner: "genuinely the best I can do" — treat $3.99 as the floor). It is a
PAY_AS_YOU_GO offer, `ONE_MONTH × 1`, then the regular $5.99, in all **175**
territories — same numeral where the tier exists AND is worth at least the
euro offer (USD, EUR, GBP and ~110 more), Apple's equalization elsewhere (¥600,
₹399, R$24.9, A$5.99). Created and READ BACK by
`scripts/asc-line-monthly-intro-offer.py` (dry-run by default, idempotent).
🔴 **No territory's intro may net less than the €3.99 offer (owner, 2026-09-17).**
The same-numeral rule put Canada at CA$3.99 — ~US$2.45 after Apple's 15%,
against a $2.00 Telnyx number. `scripts/asc-line-intro-eur-floor.py` raised
every bare-3.99 territory below Apple's equalization of FRA's €3.99 to that
equalization: **CAN → CA$4.99 and 22 VAT-carrying USD territories → $4.99**
(ALB ARM AZE BEN BLR BRB CIV CMR COG GEO GHA ISL KEN MAR MDA MUS NPL SEN UGA
UKR ZMB ZWE). Apple's own equalization puts USA at $3.99, so the US was not
below the euro value and is unchanged. Re-run the script (dry-run) after ANY
change to the offer; it must print `to raise: 0`. ⚠️ ASC answers a DELETE with
204 and an EMPTY body — the first run crashed on it after deleting Albania's
offer, leaving that territory with none until the re-run restored it.
A paid intro answers the free-trial objection: the $3.39 net covers the $1
number. It applies at Apple's sheet with no client change; the client renders
it on `LineCheckoutScreen` (plan row, price block, CTA, 3.1.2 sentence) from
2.13 via `SubscriptionStore.monthlyIntroPriceDisplay`. **2.12 and older do
not display it; 2.13 does.** Read it on `line_checkout_view`
/ `line_purchase_result` `props.intro` (true = the first-month price was on
screen) against the pre-09-10 sheet→paid of 3 of 30.
⚠️ **`line_checkout_view` usually fires TWICE per visit** (14 days to
2026-09-23: 208 (user, second) pairs carry 2 rows, 75 carry 1) — count USERS
or dedupe per (user, `client_ts`), never raw rows. Cause not traced; the
likeliest is the cover's content being built twice (INFERRED, not verified).
`line_checkout_exit` (2.18+, unread) fires once per visit when the user leaves
WITHOUT tapping Subscribe: `how` ∈ `back` · `background` · `restore` (Restore
found a live line — not an abandonment), `seconds`, `plan`, `intro`,
`country`, `capability_note` (the uncollapsed US/PR sending warning was on
screen) and `good_to_know_expanded`. The visit lives in a file-private static
(`CheckoutVisit`), not `@State`, so a second instance cannot double-fire or
restart the clock; an `onDisappear` while `flow` is still `.lineCheckout` is
ignored for the same reason.

🔴 **`Product.SubscriptionInfo.introductoryOffer` is the offer AS CONFIGURED,
not eligibility.** StoreKit returns it to every user; eligibility is the
separate async `isEligibleForIntroOffer`, and Apple grants ONE intro per
subscription GROUP per Apple ID — so every current and lapsed line subscriber
(including the 2026-08 yearly-trial takers) is ineligible and pays $5.99 at
the sheet. `monthlyIntroOffer` is therefore set in `loadProduct()` only after
the eligibility read returns true, and cleared on a successful purchase.
✅ **`trialLabel` and `MailSubscriptionStore.yearlyTrialLabel` carry the same
eligibility gate since 2026-09-11** (2.13 build 63). Both used to read the
offer's mere presence — inert for the line, since no yearly line trial exists in
ASC, but LIVE for mail: `mail.yearly` carried a 3-day trial in every territory
(REMOVED 2026-09-16, below), so every repeat mail subscriber was shown "3 days
free" and then charged for the whole year. Both are now stored properties written in the load path behind the
async `isEligibleForIntroOffer` read and cleared on a successful purchase.
🔴 **Never reintroduce a computed `…IntroOffer` that reads
`subscription?.introductoryOffer` directly.** StoreKit hands the offer AS
CONFIGURED to every Apple ID; only the async call knows who qualifies. The old
`trialLabel` doc comment *claimed* the gate it did not have, which is how it
survived review twice.

**The yearly line plan carried a 3-day free trial from 2026-08-15 to at least
08-24, and it is GONE from ASC** (`GET /v1/subscriptions/6798759539/
introductoryOffers` → empty, 2026-09-10). Its record: 9 takers, 1 call between
them, 0 conversions, a $1 number each — decoded from
`latest_signed_transaction.offerDiscountType = FREE_TRIAL` on
`line_subscriptions`. `trialLabel` (yearly ONLY) therefore renders nothing.
🔴 **`mail.yearly`'s 3-day trial is ALSO GONE, removed 2026-09-16** (owner
decision; 175 territory offers deleted via
`/v1/subscriptionIntroductoryOffers/<id>`, read back 0, and `line.monthly`'s
175 $3.99 first-month offers verified untouched in the same run). **Neither
subscription carries a free trial any more; `line.monthly`'s PAID intro is the
only introductory offer left in the app.** Three independent reasons, each
sufficient:

- **It converted 1 of 13 settled trials.** 14 started, 1 paid $29.99, 2
  cancelled inside the trial, and **10 of the 11 who let it auto-renew were
  DECLINED at the first charge** — that is the entire `billing_retry` pile, not
  card trouble.
- **It manufactured the angriest possible user**: a 3-day trial ending in a
  surprise $29.99 attempt, in an app whose only organic review is already a
  price complaint.
- **It was the free-farm vector.** See the TikTok-farming note under "The
  temp-e-mail product".

⚠️ Users already inside a trial keep it — Apple honours a granted offer — so
the last of them lapse 2026-09-18. No client change was needed: with no offer
configured StoreKit returns none, `yearlyTrialLabel` goes nil, and the "3 days
free" copy disappears by itself. Do not re-add a trial on EITHER product
without the owner.

⚠️ **`isFreeTrial` in `_shared/iap.ts` no longer treats `offerType === 1` as
"free"**: since the paid intro, an introductory period can carry a price, so
a legacy payload with no `offerDiscountType` is a trial only at `price 0`.
`linePlanLabel` renders "· intro price" for the $3.99 period so ops never
reads it as a $5.99 renewal. `telegram-notify`'s trial test is `price_milli
= 0` and stays correct on its own.

### 🔴 The master funnel — 69% of signups never place a single order

Measured 2026-09-11. This is the largest number in the product by an order of
magnitude, and every other conversion problem is smaller than it:

| stage | users | |
|---|---|---|
| signed up | 1,678 | |
| placed ANY order (SMS or e-mail) | 521 | 31% |
| …placed temp SMS | 303 | got a code: **100** |
| …placed temp e-mail | 274 | got a code: **123** |
| ever paid (Production, credits > 0) | 48 | **2.9%** |

**1,157 people signed up and ordered nothing at all.** It is NOT the signup
grant going to 0 — that was 2026-09-10 and this cohort long predates it. Sign in
with Apple is mandatory *before* any product is usable, so a "signup" here is
closer to "opened the app" than to intent; treat the 31% as an ACTIVATION rate,
not a conversion one. 2.13's `home_view` / `home_card_tapped` are the first
instrumentation that can say where those users stop — **read them before
designing a fix**, because this file records two earlier attempts at the same
leak that both missed.

🔴 **The FREE product delivers more than twice as well as the PAID one.** Per
order, 30 days to 2026-09-11:

| | orders | delivered | |
|---|---|---|---|
| temp SMS (costs credits) | 411 | 89 | **21.7%** |
| temp e-mail (92% free) | 367 | 181 | **49.3%** |

SMS: 211 expired, 111 cancelled, 89 received. This is the root of the 1★, the
absent reorders and the 8 ratings — and it is why the checkout steer exists.

⚠️ **"E-mail acquires users" is UNPROVEN and currently reads negative**, and
the 2026-09-16 TikTok-farming cohort reads negative HARDER — four
subscribers, 37 orders, **zero** SMS orders between them (see the
temp-e-mail product section). Of 274
mail users, 56 ever placed an SMS order and **5 ever paid — 1.8%, BELOW the
2.9% all-user baseline**. Mail also ran **−$3.65** in those 30 days (367 orders,
336 free, 31 credits charged ≈ $12.40 against $16.05 wholesale). That is noise
financially; the cost is attention — half the order volume, a second provider
protocol, its own subscription, cron and watchdog. **Do not cut it yet:** the
e-mail-heavy keyword field only reached ASC on 2026-09-11 and has never been
live, so the actual bet is untested. Judge it after 2.13 is approved and adopted
— if temp-mail keywords drive installs converting at ≤2%, e-mail is a free
service being run, not a funnel. Re-derive all of the above rather than quoting
it; the queries are one `count(*) filter` over `profiles`, `orders`,
`email_orders` and `iap_receipts`.

### What the line can and cannot do

Every ✅ below is proven by a real transaction, not inferred. The ❌ is what the
app must never sell.

| capability | state |
|---|---|
| **outbound calling** | ✅ proven at volume |
| **inbound calling** | ✅ proven 2026-09-08 on a device, app open AND closed |
| **inbound SMS** | ✅ works |
| **outbound SMS to a CANADIAN recipient** | ✅ mostly works — CA→CA 7 of 10 delivered (3 spam-flagged `40002`) |
| **outbound SMS to a US recipient, from ANY of our numbers** | 🔴 **mostly BLOCKED** — our numbers are not 10DLC-registered; CA→US 0 of 8, US→US 3 of 28 (all-time, 2026-09-24) |
| **outbound SMS outside NANP** | ❌ **genuinely blocked** — settled by experiment |

🔴 **US-number texting fails `40010: The sending number is not 10DLC-registered
but is required to be by the carrier`** (found 2026-09-17). Over the 30 days
to then, 16 of 24 outbound sends failed on 9 lines, every one from a US number
to a US number, and the 3 US sends that did land reached carriers that still
accept unregistered senders.
🔴 **It is the RECIPIENT's network that enforces 10DLC, not the sender's
country (corrected 2026-09-24).** This file said "the Canadian numbers
delivered every send" — true only because every Canadian send in that window
went to a Canadian number. All-time, **CA→US is 0 of 8, every failure
`40010`** (2 lines, 2026-08-17 → 09-24), while CA→CA is 7 of 10. So
`LineStoreScreen`'s green "Texts you send from a Canadian number arrive
normally" is FALSE for the commonest case — texting a US number — and a
Canadian number is NOT a workaround. (Fixed on branch `design-overhaul`,
2026-09-24: no screen claims Canadian sending works.) Re-derive by grouping `line_messages`
outbound on sender AND recipient area code, never sender alone.
Nothing in this repo registers a 10DLC brand or campaign. The 2026-09-08
"proven" row was ONE successful send — the same best-case generalisation the
note below warns about. It costs subscribers: `4c132957` had three test texts
fail inside three minutes and turned auto-renew off six minutes later. Fixing
it is an owner decision (register a 10DLC campaign — a consumer "second
number" is a hard campaign to get approved — or stop promising texting to US
numbers; leading with Canadian numbers does NOT help, see below).
⚠️ **The only registration-free route is Telnyx's P2P traffic type, and it is
closed to our account (2026-09-24).** US numbers list P2P as eligible; switching
all 28 live ones was accepted and read back `A2P` on every one. It needs Telnyx's
P2P EXEMPTION, which requires a **$1,000+/month Telnyx contract** and months of
review — out of reach at our ~$105 spend in the 30 days to 2026-09-24
(50 numbers × $2 + $3.91 calls/SMS). The
code is ready and ONE key gates all of it: once
`app_config.line_p2p_enabled` is set `true` (absent = off), `switchToP2P`
(`_shared/lineProvision.ts`) runs at purchase and swap and the hourly sweep in
`sync-line-voice` switches every live line. While it is off none of the three
touches Telnyx. Detail in
`.claude/rules/providers.md`.

✅ **DECIDED 2026-09-17: KEEP SELLING US/PR AND DISCLOSE IT.** US and PR were
`force_block`ed for about an hour (migration `20260917090000`) and unblocked
the same day (`20260917100000`); all three of US, CA and PR sell again. The
owner's call is that the buyer is TOLD instead: `LineStoreScreen.sendingNotice`
(amber on a US/PR country, green "texts arrive normally" on CA — the country
picker is where the choice is still free) and `LineCheckoutScreen`'s
`capabilityNote`, which is **uncollapsed** on a US/PR purchase. The country
list is ONE constant, `LineStoreScreen.unreliableSendingCountries` = {US, PR},
so the two screens cannot disagree about who is warned.
**On branch `design-overhaul` (2026-09-24):** `LineStoreScreen.sendingNotice`
and its green Canada line are GONE. The store shows a ✓/✗ ledger
(`Components/LineLedger.swift`) whose ✗ row, 'Texts you send to US numbers
usually don't arrive.', renders for EVERY country, because the recipient's
network enforces 10DLC (CA→US 0 of 8). Checkout's `capabilityNote` stays
UNCOLLAPSED on US/PR with its Canada sentence removed; the thread's
failed-send copy likewise; the swap sheet's confirm page gains the ✗ row when
the target country is US/PR. `LineStoreScreen.unreliableSendingCountries` is
still the one list (checkout, thread, swap). The force_block rule below covers
the ledger ✗ row and the checkout note on this branch. The rest of this
paragraph describes `main`.
🔴 **That warning is the only thing standing between a US buyer and a refund
request. If it is ever removed, `force_block` US and PR in the same commit** —
the migration carries the exact SQL. Conversely, if the US ever gets a 10DLC
campaign, BOTH halves of the notice go and this paragraph goes with them.
⚠️ The existing "Some networks block texts sent from virtual numbers" row
stays inside checkout's collapsed `goodToKnow`; it opens CLOSED, which is why
the new note is not in it. ⚠️ Ships with the next release — the server change
alone does nothing. ⚠️ Build-verified only, never walked on a device.
⚠️ The App Store subtitle (`USA Phone Line & Verification`) and promotional
text ("a real US number") still promise a US number, and promotional text is
the ONE field that changes without review. Re-derive:
```sql
select left(e164_from,5) prefix, status, error_code, count(*) from line_messages
 where direction='outbound' and created_at > now()-interval '30 days' group by 1,2,3;
```

🔴 **Texting outside NANP is blocked, and the cause is NEITHER of the two flags
this file blamed for weeks.** Two real sends from a US number we own to the
owner's own French mobile, before and after adding FR to the messaging
profile's `whitelisted_destinations`, both returned `40306 Alpha sender not
configured` — **byte-identical**, so the whitelist was never the blocker (it
was reverted, leaving the account as found). `features.sms.
international_outbound` is not what fires either; the refusal happens at the
profile, before the number's own capability is consulted. France, like most of
Europe, will not accept a foreign long code as an A2P sender and wants an
**alphanumeric sender ID** — which is ONE-WAY, so the recipient would see a
brand name and could not reply. That is a different product, not this one.
**NANP → NANP is the honest boundary**, and `_shared/nanp.ts`'s up-front
refusal is correct — not as a guess, but because the alternative spends a
hard-stop allowance segment to buy a certain failure.

⚠️ **The correction is the point: a plausible mechanism that explains the
symptom is not the mechanism.** This file asserted "our own setting is the
limit" on the strength of GB appearing in that whitelist. It was wrong.

**Why the earlier "outbound SMS is entirely broken" verdict held for three
weeks, because the shape recurs:** it rested on four sends in ONE evening,
every one from a **Canadian** number to **US** numbers, every one `40010`.
Canada was then the only country we sold, so "cross-border fails" and "sends
from a Canadian longcode fail" were the SAME observation wearing the more
general name — and the general name is what got recorded. No US number had ever
attempted a send. **Generalising from the single worst case in the matrix is
the error.**

Re-derive rather than quoting any figure here:
```sql
select direction, status, count(*) from line_calls group by 1,2;
select status, count(*) from line_messages where direction='outbound' group by 1;
```

### Provider split

**5sim is the PRIMARY SMS provider. HeroSMS serves the countries 5sim does not,
and the whole temp-EMAIL line. eSIM Access is the eSIM provider (parked).
SMSPVA is RETIRED from routing (2026-08-17). SMSPool survives ONLY as the
usage/QR path for the 12 eSIMs sold before the switch** — `check-esim-usage`
routes on `esim_orders.provider`.

⚠️ **"5sim for SMS, HeroSMS for e-mail" is the SHORTHAND and it is wrong as a
description of the catalog.** HeroSMS still fills real SMS orders — do not
"clean up" its SMS surface on the assumption that it is dormant. Re-query:
```sql
select provider, count(*) from routes where status='active' group by 1;
```

**The split is COUNTRY-driven, not service-driven.** Every non-5sim active
route is in a country 5sim does not serve. There is no service 5sim carries
that we merely failed to re-home — `sync-5sim` re-homes those automatically
every hour. Owner decision 2026-08-04: **keep them**; Switzerland is the best
delivery record in the app's history, and dropping the set would remove nine
countries from a 100%-search-driven catalog.

**Ownership is per (service, country) — per ROUTE, not per service.** That is
safe for ROUTING, because `routes.provider` is a column on each row and
`providerOrder()` resolves it first, so every route deterministically goes to
exactly one provider. It was NOT safe for service-level EVIDENCE, which assumed
disjointness and silently overwrote itself — see "Evidence must describe the
provider that serves the NEXT order".

**There is no fallback between providers**: `providerOrder()` returns exactly
one, so a stockout fails as a stockout rather than silently re-reserving
elsewhere under a different price and delivery profile.

`providerOrder()` in `_shared/providers.ts` is the single source of truth for
SMS routing; order/poll functions call the router, never a provider. It
resolves **`routes.provider` (ownership) FIRST**, falling back to
code-presence only when no owner is recorded — a route can carry codes for two
providers at once, and the one that PRICED it must be the one that BUYS it.

**The provider has changed four times, and every switch broke something that
threw no error**, because `routes` is ONE row per (service_id, country_id) with
`provider` as a column — re-homing rows strands any combo the new provider
cannot serve. If you switch again, walk the provider-switch checklist below.

**Why 5sim.** Every provider before it kept per-(service, country) delivery
rates behind a dashboard session. 5sim publishes them free and unauthenticated:
`GET /v1/guest/prices` returns, per (country, product, operator),
`{cost, count, rate720}` — a 30-day delivery rate per pool. That turns "buy from
the best pool" from guesswork into arithmetic, and it is the first time we can
steer on delivery *before* placing an order rather than after failing one.

🔴 **OWNER DECISION 2026-09-21: 5sim STAYS PRIMARY until HeroSMS exposes a
delivery-stats endpoint to API keys — "we will stick with 5sim till they
provide an endpoint".** This closes a question that will otherwise keep
re-opening, because HeroSMS's website *displays* per-country and per-operator
success rates and so looks like it must have an API for them. It does not, for
key holders: `/api/v1/stats/*` answers **401** to the same
`Authorization: ApiKey` header that `/activations/offers` answers **200** to,
in the same request — it is a Laravel Sanctum browser session sharing the
`/api/v1` prefix. Full contract, and the 12–24h window that would make it a
`rate24` trap even if it opened, in `.claude/rules/providers.md`.

**So the unauthenticated `rate720` above is not merely a convenience — it is
the reason the primary provider is the primary provider.** Do not propose
switching to a provider that cannot answer "which pool delivers?" before the
order. ⚠️ Nobody has asked HeroSMS to enable it; that ask is unmade, not
refused. **Re-probe with `probe-herosms` before assuming the answer is still
no — and never re-derive this by asking anyone for another API key**, which is
what the probe exists to make unnecessary.

## Common commands

```bash
# ⛔ `swiftc -typecheck` IS RETIRED — do NOT use it, and do not "fix" it. The
# TelnyxRTC SwiftPM package retired it: swiftc cannot resolve a package graph,
# so it fails with `no such module 'TelnyxRTC'` and reports NOTHING about the
# other 135 sources. **`xcodebuild` is the ONLY check**, and it was always the
# better one — a missing `import StoreKit` type-checks fine and fails the build.
xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 \
  | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"
```

⚠️ **A green build does NOT cover the two things calling can get wrong.** Both
are runtime-only and silent: the `UIBackgroundModes` Info.plist key (see the
gotcha below) and whether a real call carries audio. Assert the first with
`plutil`, the second only on a physical device.

Verify backend changes by re-deploying and then **checking the resulting DB
state** — not by assuming the deploy worked. Several bugs looked identical to
success until a row was queried.

⚠️ If the CLI errors with `too many authentication failures … (ECIRCUITBREAKER)`,
`supabase db query --linked` mints a temp login role per call and parallel
agents exhaust it. Use the Supabase MCP `execute_sql`/`apply_migration` tools
instead — different auth path, unaffected.

### Deploying edge functions

There are **53** function directories besides `_shared` (re-count with
`ls supabase/functions | grep -v _shared | wc -l`). Two groups:

```bash
# JWT-verified (26)
supabase functions deploy create-order check-order cancel-order register-push iap-verify delete-account \
  create-esim-order check-esim-usage redeem-referral \
  create-email-order check-email-order email-domains support-send \
  search-line-numbers reserve-line-number verify-line-subscription rent-line-credits \
  send-line-message line-thread-action mint-line-token begin-line-call report-line-call \
  record-attribution verify-email-subscription swap-line-number record-events

# Cron-gated / webhooks (25) — MUST ship --no-verify-jwt: their pg_cron relays
# send only x-cron-secret, no Authorization header. `winback` lived in the JWT
# group until 2026-07-21 and silently 401'd on every run — zero nudges ever
# sent, invisible because pg_net purges response history within hours.
supabase functions deploy poll-active-orders sync-prices sync-5sim sync-herosms \
  rescue-unprovisioned-lines \
  sync-esim-plans sync-smspva-operators sync-smspva-conversions winback \
  telegram-notify telegram-webhook daily-credit telegram-setup goodwill-credit \
  broadcast-push telnyx-webhook apple-notifications release-lines sync-telnyx-cdr \
  sync-line-voice probe-telnyx-connection sync-line-countries rc-sync reddit-scan \
  insta-draft \
  --no-verify-jwt
```

✅ **Verified 2026-09-22**: 26 + 25 = 51 against **53** on disk. The two
omissions are **`probe-5sim`** and **`probe-herosms`**, deliberately outside
both lists — they are diagnostics, not on a normal cadence, but both DO carry
a `config.toml` `verify_jwt = false` entry and must be deployed
`--no-verify-jwt` by hand when `_shared/cors.ts` changes. **Re-run the count
rather than trusting this line: a function in neither list is a function
nobody redeploys, which is exactly how a stale bundle survives a fix.**

`supabase/config.toml` carries a `verify_jwt = false` entry for all 25 plus
both probes (27 total).

**`probe-herosms`** (added 2026-09-21) answers one question and is worth
keeping for it: whether HeroSMS's per-country and per-operator deliverability
statistics — the ones its website shows — are reachable with an API key. They
are **not**; `/api/v1/stats/*` refuses key auth while `/activations/offers`
accepts it in the same request. Detail, and the contract if it ever opens up,
in `.claude/rules/providers.md`. **Re-probe rather than asking anyone for
another API key.**

🔴 **`_shared/*` is bundled PER FUNCTION at deploy time.** After touching
`_shared/fivesim.ts`, redeploy `sync-5sim` AND `poll-active-orders` AND every
consumer of `providers.ts` — a stale bundle keeps the OLD copy with no signal
anywhere. When in doubt, redeploy everything (idempotent, ~1 min), then assert:

```
telegram-webhook  unauthenticated POST -> 200   (its own silent rejection; 401 = bot dead)
sync-herosms      no x-cron-secret     -> 403   (secret check, not the JWT gate)
create-order      no auth              -> 401   (auth still enforced)
```

⚠️ `telegram-setup` fails closed, and rotating `TELEGRAM_WEBHOOK_SECRET`
requires re-running it.

### Cron schedule (26 active jobs — the 25 re-verified 2026-09-15 plus `relay-insta-draft`, scheduled 2026-09-22)

```
relay-poll-active-orders  * * * * *     relay-telegram-notify   * * * * *
watchdog                  */10 * * * *  relay-sync-prices       17 * * * *
relay-sync-5sim           7 * * * *     (PRIMARY pricing sync, ~71s/run)
relay-sync-herosms        37 * * * *    (offset from sync-prices on purpose)
relay-sync-esim-plans     0 2 * * *     relay-winback           0 15 * * *  (4 nudge cohorts, below)
expire-esim-orders        */15 * * * *  expire-email-orders     */5 * * * *
purge-job-run-details     7 3 * * *     telegram-events-prune   30 4 * * *
app-events-prune          50 3 * * *
relay-rc-sync             * * * * *     (RevenueCat mirror, read-only; sleeps 5s past :00 — see the herd gotcha)
relay-reddit-scan         26 * * * *    (Reddit radar; READ-only, drafts never post — see below)
relay-insta-draft         0 8 * * *     (ONE Instagram draft to Telegram; publishes only on the owner's Post tap — see below)
── rented lines ──
reclaim-lapsed-lines      */15 * * * *  (PURE SQL, no HTTP hop — the claim must
                                         survive the edge layer dying)
relay-release-lines       3,18,33,48 * * * *   (the provider DELETE)
relay-sync-telnyx-cdr     */10 * * * *  (settles call minutes)
relay-sync-line-voice     11 * * * *    relay-sync-line-countries 40 3 * * *
settle-stale-line-calls   23 * * * *    (PURE SQL; the 6h no-CDR backstop)
relay-rescue-unprovisioned-lines 8,23,38,53 * * * *
── credits-billed lines (the non-Apple path) ──
debit-credit-lines        19 5 * * *    (monthly rent in credits)
refund-stuck-credit-lines 11,41 * * * * (reconciles a failed debit)
roll-line-allowances      9 * * * *     (rolls the SMS/voice period bucket)
```

⚠️ **The three credits-line jobs were undocumented until 2026-09-09** and are
the renewal mechanism this file previously called "unproven" for the
credits-billed line. **`relay-daily-credit` is unscheduled** (the grant is
disabled) and **every SMSPVA cron is GONE** — `select jobname from cron.job
where jobname like '%smspva%'` returns zero rows, contradicting this file's
long-standing "three retired-provider crons still run".

Trigger any cron-gated function without handling the secret yourself — pg_net
calls it server-side and `private_cron_secret()` never leaves the database:

```sql
select net.http_post(
  url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices',
  headers := jsonb_build_object('Content-Type','application/json',
                                'x-cron-secret', private_cron_secret()),
  body := '{}'::jsonb, timeout_milliseconds := 180000);
```

There is no test suite. The behavioural checks under `scripts/verify-*.sql` are
the closest thing — each runs inside a rolled-back transaction. Run the relevant
one after touching what it covers; a structural check proves a function exists,
and only a behavioural one catches an index that is present, correct and
unreachable from the code that needs it.

## Architecture

### Backend layout

- `supabase/migrations/` — chronological SQL, each phase ships its own file
- `supabase/functions/_shared/` — **34 files** (`ls supabase/functions/_shared |
  wc -l`; count, do not trust a list). The ones worth knowing:
  `providers.ts` (the unified router — order/poll functions call this, never a
  provider), `pricing.ts` (the ONE definition of SMS retail), `fivesim.ts`,
  `herosms.ts`, `heromail.ts` (the temp-EMAIL line), `emailPricing.ts`
  (`EMAIL_PAID_CREDITS`, the one price of a paid e-mail address), `smspva.ts`, `smspool.ts`
  (eSIM + balance ONLY), `esimaccess.ts`, `iap.ts` (Apple receipt chain
  verification), `apns.ts`, `telnyx.ts` (the rented-line adapter),
  `lineCatalog.ts` (the fail-closed sellability gate every line seller calls),
  `lineProvision.ts` (the ONE order→poll→messaging→voice→activate sequence —
  it was written out three times, which is how voice provisioning ended up in
  one path and not another), `pgRetry.ts` (retry a PostgREST READ through the
  top-of-minute herd; never a write), `nanp.ts`, `phone.ts`, `emailStatus.ts`,
  `cors.ts`, `telegram.ts`, `tgCommands.ts`, `tgHandlers.ts`, `tgFormat.ts`,
  `tgAlert.ts`, `opsFormat.ts`, `supabaseAdmin.ts`, `lines.ts`, `lineVoice.ts`,
  `reddit.ts` (read-only Reddit search), `kimi.ts` (the lead classifier),
  `openrouter.ts` / `instaCopy.ts` / `instaImage.ts` / `instagram.ts` (the
  Instagram drafts — caption+image generation, guardrails, composition, publish)
- `supabase/functions/<name>/index.ts` — one per endpoint, all `Deno.serve`
- `supabase/README.md` — deployment + secret setup walkthrough

**Key SQL functions** (all `SECURITY DEFINER`, all revoked from
`anon`/`authenticated` — clients reach them only through edge functions on the
service role):

- `begin_order(user, service, country, credits)` — dedupe + insert order +
  charge, in ONE transaction under `pg_advisory_xact_lock(user)`.
- `wallet_spend` / `wallet_credit` — atomic single-statement balance moves.
  Always pass `p_order` so the ledger reconciles.
- `credit_iap_purchase(...)` — **the only way to credit an Apple purchase.**
  Tombstones `transaction_id` in `iap_grants` and credits in ONE transaction
  under an advisory lock. Idempotent, so a caller unsure whether a previous
  attempt landed simply calls again — that is both the duplicate check and the
  recovery. **Never call `wallet_credit` directly for an IAP**; it has no
  replay guard.
- `refresh_evidence_all_providers()` — **the only evidence entry point
  `sync-prices` calls.**
- `ops_snapshot(interval)` — one JSONB blob powering both the Telegram digest
  and `/stats`.

🔴 **`active_sms_provider()` returns whichever provider owns the most active
routes, and that is the wrong metric.** It lands right today by luck. It landed
*wrong* for the whole of the HeroSMS era, silently pointing every evidence
refresh at a retired provider. **Do not wire anything new to it**, and grep
before assuming a consumer is safe: `select proname from pg_proc where prosrc
like '%active_sms_provider%'`. `recent_sms_delivery_rate()` still uses it and
is still wrong; it is only harmless because nothing gates on it now.

### Where the iOS client is documented

Source layout, the palette and Liquid Glass rules, cold launch, the map's
per-frame camera trap, the `Text("literal")` localization rule, the service
picker and the order-state reconcile invariant live in
`.claude/rules/ios-client.md`, which loads under `VirtualSIM/`.

**iOS minimum is 18.0.** Anything guarded by `if #available(iOS 26, *)` must
keep a working 18.0 path. The project has **3** SwiftPM dependencies (TelnyxRTC
4.1.2, WebRTC 139.0.0, Starscream 4.0.8) and **143** Swift sources on branch
`design-overhaul` (counted 2026-09-24) — re-count with
`find VirtualSIM -name '*.swift' | wc -l`; this said 116 for a month.

## Money and safety invariants

The rules in this section are the ones that have cost real cash when broken.
They are stated once here rather than repeated per product line.

### Never write a status transition without an atomic claim

Every `orders` status write is `.eq("status","waiting")` + a row-count check.
`check-order`'s `received` branch was the one exception and could overwrite a
terminal state the expiry cron had already set — handing a user a working code
they had *already been refunded for*.

### A status claim and its refund must be ONE transaction

Where they are split across two round-trips, a worker killed in between leaves a
TERMINAL row with the charge never returned — and the expiry sweeps select only
`status='waiting'`, so nothing ever revisits it. **No timeout value fixes this,
and a TypeScript rollback cannot either, because the process is gone.** Seven
paths had it wrong and were fixed one at a time.

⚠️ **The lesson is about the rule, not the bug.** This file once stated the
invariant while TWO existing paths still violated it — including the busiest
close path in the product. **A written invariant is not an enforced one: grep
for violators when you write one down.**

### `supabase-js` RETURNS errors, it does not throw

Every `await sb.rpc("wallet_credit", …)` that discards `{ error }` is a silent
money bug: the status claim commits, the balance never moves, and the user gets
a push saying "N credits refunded". **Destructure the error at every money
call.** Four sites had this.

### EVERY grant is farmable through account deletion unless tombstoned OUTSIDE the `auth.users` cascade

This is the single most repeated money bug in this codebase — found **four**
times, once per grant. Everything user-scoped cascades, so delete → sign in
again erases our only record and mints the grant afresh. Apple *mandates* the
Delete Account button, so this is not an edge case.

| grant | tombstone |
|---|---|
| signup credits | `signup_grants` (hash of the email) |
| referral +2 | `signup_grants.referral_redeemed_at` |
| IAP purchases | `iap_grants` (keyed on Apple's `transaction_id`) |
| the lifetime free e-mail address | `email_free_grants` + `free_email_device_grants` |

Each tombstone table must have **no foreign key to `auth.users`** — a reference
there is precisely what deletes the row with the account. All fail **open** on a
null email, because a missed grant on a real signup costs more than a rare
duplicate. **If you add a fifth grant, it needs a tombstone in the same commit.**

⚠️ **The fourth is the proof the rule needs restating rather than trusting: it
is not denominated in credits, so nobody read it as a "grant", and it shipped
counting `email_orders` rows that cascade — farmed 55 times from one identity.**
🔴 **And the mailbox key alone was then farmed 75 times from two phones**, via a
catch-all disposable domain that confirms every address. The free e-mail path is
now additionally keyed on the DEVICE (push token) and rate-limited per IP, and
disposable domains are refused at signup. Residual, stated plainly: a user with
ten real mailboxes still gets ten grants — a cost floor, not a wall.

### 🔴 The client is never authoritative about money

`report-line-call` takes `status` from the REQUEST BODY. Until 2026-08-17 a
terminal-unconnected status immediately refunded the whole credit block and set
`allowance_settled = true` — and `sync-telnyx-cdr` sweeps only
`allowance_settled = false`, so **the real detail record could never correct
it**. Exploit: dial anywhere, POST `{status:"canceled"}` ten seconds in, get
every credit back, talk as long as you like, repeat.

The migration that introduced it argued *"canceled/failed/busy/missed mean no
leg was ever answered BY DEFINITION"*. **True of a PROVIDER-reported status;
false of a client-reported one**, and this function only ever receives the
latter. The client's report is now **advisory**: it records status and duration
for the UI and settles nothing.

🔴 **`provider_call_session_id` AND `provider_call_leg_id` ARE ALSO
CLIENT-SUPPLIED, DESPITE THE NAMES.** They are written only by
`attach_line_call_session`, whose argument is `report-line-call`'s request body
verbatim. Nothing in this product writes a call identifier from a source the
device does not control. This is not hypothetical: a 2026-08-20 change gated
billing on those ids specifically to avoid gating on `status`, which made
**silence the winning move** — never report, and the backstop refunded
everything. Reverted the next day.

**Generalise it: if a value decides money and the device can set it, the device
must not be the one that settles.** Any future gate must key on data the device
CANNOT set — today no such field exists on `line_calls`.

### `create-order` refuses BEFORE charging when the provider is broke

It reads `app_config.<provider>_health`, and if that reading is under 5 minutes
old and `balance_usd` is below this order's own `maxCostUsd`, it refuses up
front rather than charging and refunding. It fails **OPEN** on stale or missing
data. ⚠️ **This is why a missing `<provider>_health` row is dangerous: the guard
silently stops guarding.** The e-mail path still charges-then-refunds.

### Balance alerts: ONE level per provider

🔴 **Page at 5sim < $5.00, HeroSMS < $5.00, Telnyx < $10.00. Nothing else.**
The old four-rung ladder is deleted — at the owner's fund-on-demand cadence it
meant three warnings before the one that matters, on the single channel that has
to stay readable.

**Telnyx is $10, DOUBLE the SMS providers, and that is deliberate**: a dry
Telnyx balance does not merely block a new sale, it means an EXISTING
subscriber's $1/month number cannot be renewed.

🔴 **THE SAME NUMBER LIVES IN THREE PLACES AND WILL DRIFT. Change them in one
commit:**

| copy | where | what it does |
|---|---|---|
| `BALANCE_ALERT_USD` | `poll-active-orders/index.ts` | the instant Telegram PAGE |
| `LOW_BALANCE_USD` / `TELNYX_LOW_USD` | `_shared/opsFormat.ts` | the "top up" DISPLAY |
| `v_floor` | `watchdog_money_checks()` | the standing watchdog verdict |

- **`alert_tier` is now 0 or 1**, and the read is **clamped at 1**: rows stamped
  by the old ladder carry tiers up to 4, and without the clamp a provider at
  tier 4 could never satisfy `tier > prevTier` again — its page permanently
  disarmed, silently.
- 🔴 **The RUNWAY check (`balance ÷ 7-day burn < 5 days`) is OFF for 5sim and
  HeroSMS** (owner, 2026-09-13: *"don't mention 5sim or herosms balance in the
  watchdog unless they're under 5 usd"*; migration `20260913070630`). For
  those two the $5 floor is the ONLY balance page. It was a standing page at
  the owner's fund-on-demand cadence — 5sim sat at ~4 days of "runway" for
  most of a week while well above the floor, re-paging every 6 hours. The
  dead-route branch under the same check name ("no spend in 7 days against N
  orders the week before") is NOT a balance page and stays. Do not re-enable
  the runway line without the owner.
- 🔴 **And the runway number was WRONG, not merely noisy (2026-09-13).** It
  summed `orders.actual_cost_cents`, which is stamped once at RESERVATION and
  never reversed — but a cancel and an expiry both reach `five.cancel`, which
  refunds the wholesale, so that column is what was RESERVED, not what was
  SPENT. Over 30 days to 2026-09-13 it read $69.78 against a true provider
  cost of **$15.52**, the 99 delivered orders only: a ~4.5× overstatement.
  Confirmed against the live balance — 5sim fell $18.86 → $16.94 overnight,
  exactly the $1.92 of codes that actually delivered in that window.
  ⚠️ **The concept is wrong too, not just the magnitude.** What the float has
  to cover is PEAK CONCURRENT reservations, since 5sim debits at reservation
  and credits back on cancel — never cumulative daily spend. Any future
  float check must measure concurrency, and `sum(actual_cost_cents)` is not
  a spend figure anywhere it appears (`ops_snapshot`'s `spend_cents` and
  `/profit` inherit the same overstatement).
- An order refused for insufficient float pages separately
  (`create-order`'s `alertLowBalanceBlock`) and carries the **shortfall** — a
  route may need $60 of float while the balance page does not fire until $5.

### `app_config` is RLS-restricted to an explicit key WHITELIST

**NINE keys** once migration `20260923100000_support_url.sql` is applied:
`maintenance`, `announcement`, `esim_paused`, `lines_paused`,
`line_swap_credits`, `delivery_metrics_hidden`, `email_sub_daily_cap`,
`launch_tab`, `support_url` (the first eight verified live 2026-09-23;
`support_url` is added by that migration — confirm it applied).

🔴 **Never replace that with `using (true)`** — the same table holds provider
balances, the watchdog verdict, and every sync cursor, and `routes` has a
public read policy so anyone holding the publishable key could read them.
Widening it by one named key is the ONLY safe way to publish a value. Re-read
the live policy rather than quoting this list:
`select qual from pg_policies where tablename='app_config';`

### The cost book is COLUMN-GRANTED, never table-granted

🔴 **`routes` and `esim_plans` grant SELECT on EXACTLY the columns the iOS
client decodes. Never `grant select on public.routes to anon` — that one
statement re-publishes the entire wholesale cost book.**

Both tables have a `public read` RLS policy, and RLS filters ROWS, not COLUMNS,
so every wholesale figure was readable by anyone who unpacked the IPA. Verified
refused after the fix:

```
GET /rest/v1/routes?select=service_id,smoothed_cost_cents
  before: 200 + data      after: 401 42501 permission denied for table routes
```

- 🔴 **To let the client read a NEW column you must edit TWO places in one
  commit:** the column grant AND the explicit list in `CatalogAPI` /
  `EsimPlansAPI`. A column that PostgREST *filters* or *orders* on also needs
  the grant, not just one that is returned.
- 🔴 **A column REVOKE cannot subtract from a table GRANT.** It only edits
  `pg_attribute.attacl`; the `anon=rxtm` in `pg_class.relacl` still answers.
  The working shape is REVOKE-then-GRANT. Assert with
  `has_column_privilege('anon','public.routes','<col>','select')` — a passing
  `revoke` statement proves nothing. Same class as the PUBLIC-EXECUTE trap.
- **`services` and `countries` are deliberately NOT touched** — one build-42
  device still sends `select=*` to both, and neither holds a wholesale column.

### `revoke execute … from anon, authenticated` IS A NO-OP while PUBLIC holds the grant

`CREATE FUNCTION` grants EXECUTE to PUBLIC by default, and anon/authenticated
are members of PUBLIC — so the revoke line present on ~35 migrations changes
nothing on its own, and the function stays callable at `/rest/v1/rpc/<name>`.
**Read the ACL, not the migration**: a secured function is
`postgres=X/postgres | service_role=X/postgres`; a leaking one has a **leading
`=X/postgres`** (empty grantee = PUBLIC). This shipped `revenue_snapshot`
world-callable *with* its revoke line, exposing gross revenue and profit to
anyone holding the publishable key. Assert with
`has_function_privilege('anon', p.oid, 'execute')` — must be **0 rows** across
`pg_proc` in `public`.

⚠️ **The `supabase_admin` half of the default-privileges fix is NOT applied** —
it needs membership in that role. A dashboard-created table therefore still
arrives world-**writable** unless RLS is explicitly enabled on it.

### The Apple receipt verifier must chain to Apple's PINNED root

`_shared/iap.ts` once took the certificate out of the attacker-supplied JWS
header and verified the signature against that same certificate — circular, so
anyone with a free Sign-in-with-Apple account could mint credits forever. It now
walks every hop of `x5c` and requires termination at **Apple Root CA - G3,
matched by SHA-256 thumbprint** (pinning by subject name is defeated by a
self-signed cert with the same name), plus Apple's receipt-signing OID on the
leaf, and validity checked at `signedDate` not `now()`.

🔴 **Pin the ROOT ONLY** — the leaf expires 2027-10-13 and Apple rotates
intermediates routinely, so pinning anything lower turns a normal rotation into
a total purchase outage.

**Credits are granted only when `tx.environment === "Production"`.** Sandbox
receipts are genuinely Apple-signed and cost **$0** — any Apple ID can switch to
a Sandbox account and "buy" packs free (this already happened). Non-production
receipts are still persisted and still return `ok:true` so StoreKit stops
redelivering; they just move no balance. **This gate is worthless without the
chain verification above**, because `environment` is just another field a forger
sets.

⚠️ **`PRODUCT_TO_CREDITS` must NEVER gain a subscription id** — one entry pays
credits on every renewal forever.

### 🔴 `subscriptionFamily(productId)` must resolve to `"line"` or `"mail"`

Never treat it as a single yes/no. `iap-verify` asks "is this NOT a credit
pack?" so a renewal does not 400 — mail products MUST be included there.
`apple-notifications` asks the same shape of question and means the opposite:
every branch after its guard drives the phone-number lapse machine, so a mail
product MUST be excluded — **or a cancelled $2.99 mail plan would suspend and
release somebody's rented phone number.** Add a new product to
`LINE_SUBSCRIPTION_PRODUCT_IDS` or `MAIL_SUBSCRIPTION_PRODUCT_IDS` in
`_shared/iap.ts`; never treat `isSubscriptionProduct` as sufficient on its own.

## Pricing model

`AppState.cost(for:country:) -> Int?` uses an O(1) `routeIndex` dict built in
`loadCatalog`. `nil` means **unavailable to book**; the UI shows "Unavailable"
and disables the button. It deliberately does **NOT** fall back to the seed
`service.cost`. **Do not** linear-scan `routes` — that froze the country picker
before the index was added.

### 🔴 SMS retail is ONE TAPERED CURVE, defined in `_shared/pricing.ts` and NOWHERE else

```
retailUsd(cost)   = cost ≤ $0.15 ? 10 × cost
                  : cost ≤ $0.30 ? $1.50            // plateau — the join
                  :                5 × cost         // the tail
retail_credits    = clamp(1, 999, ceil(retailUsd / NET_USD_PER_CREDIT))  // NET = 0.40
expectedCostUsd(credits)  — the exact inverse, used by create-order
```

**The plateau is what keeps the curve monotone** — a blanket 5× above 15¢ would
sell a 16¢ route ($0.80) cheaper than a 15¢ one ($1.50), a price inversion.
**Never rewrite it as a flat multiple picked by a threshold.**

🔴 **The lockstep rule:** `expectedCostUsd` must remain the exact inverse of
`retailUsd`. Change one without the other and honestly-priced routes are
refused `margin_too_low`, charged-and-refunded, silently. Both live in the same
file so the same commit can hold both.

⚠️ **The tail 5× was a two-week experiment started 2026-09-01** and has not been
formally read out. Read it at ~30 `paywall_shown` events with `needed ≥ 4`:
`purchase_result` success vs cancelled, NOT raw revenue. Revert = the 08-28
formula, one file, redeploy the five consumers.

**`NET_USD_PER_CREDIT = 0.40` is MEASURED, not chosen.** It was 0.30, and over
37 Production purchases a credit actually nets $0.397 — so every provider ran
~32% above its stated multiple while the arithmetic stayed perfectly
self-consistent against the wrong input. **Re-derive it from receipts if the
pack mix shifts; never guess it, and never reason about a margin from anything
else.**

### The order-time ceiling

```ts
maxCostUsd = min( expectedCostUsd(credits) * 3.0 + 0.10,
                  credits * NET_USD_PER_CREDIT * 0.5 )
```

`MAX_REVENUE_FRACTION = 0.5` is the INVARIANT (no order can ever be sold at a
loss, whatever a future curve change does); `CEILING_SLACK_MULTIPLE = 3.0` is
the POLICY.

**Why 3×, and it is not about price rises.** We do not choose a pool: we pass
`maxPrice` and the provider fills from the cheapest thing under it, so the
ceiling decides how much inventory we can reach at all. Share of a route's total
stock reachable, over 1,554 pairs: cheapest tier only **6.2%** median, 1.1×
13.6%, 2.0× 65.8%, **3.0× 83.6%**. 23% of routes hold fewer than 100 numbers in
the cheapest tier, so capping just above it meant competing for the thinnest
slice — a direct cause of "no numbers available" on routes holding hundreds of
thousands.

**The $0.10 headroom is load-bearing — do not "simplify" it away.** Without it a
route whose wholesale lands on an exact boundary has an order-time cap equal to
its cost *to the cent*: 76.7% of routes once sat at exactly zero headroom, and a
one-cent rise made every order fail `margin_too_low` — charged and instantly
refunded — until the next hourly sync. Exposure is bounded at $0.10/order.

### 🔴 Price DOES predict delivery

Re-measured on the SETTLED cohort (`status in ('received','expired')`, numbered,
excluding app-default routes):

| wholesale paid | n | delivered |
|---|---|---|
| ≤5¢ | 33 | **12.1%** |
| 6–15¢ | 51 | 47.1% |
| 16–40¢ | 20 | 50.0% |
| >40¢ | 14 | **78.6%** |

The old claim ("drift inside the noise") was computed over ALL orders — where
~60% are cancelled by the user at a median 57s against codes arriving at a
median 58s. Impatience swamped the signal and the conclusion inverted.
🔴 **Never compute a delivery rate over unsettled orders.**

Consequences: the 5sim "collapse" (75% July → 22% August) is largely NOT the
provider — median wholesale per settled order fell 17¢ → 6¢ at the cutover, and
at constant price the providers are indistinguishable. HeroSMS fell the same
way, which is the tell.

⚠️ **Confounded, honestly:** 31 of 32 default-landed ≤5¢ orders came from users
who had never paid. Cheap inventory and non-serious users cannot be separated at
this n. Settling it needs a two-arm test the owner declined.

**`AppState.minDefaultCredits = 3`** demotes every route under 3 credits in the
picks the app still makes FOR the user (auto-landed country, post-failure
retry) — a demotion, never a filter, so the hero can never go "Unavailable";
the user's own country list is untouched.

🔴 **The floor and the signup grant were coupled, and they are NOT any more.**
The rule was "never let the floor exceed the grant, change the two together",
because a first pick priced above a new user's balance stranded them. Since
2026-09-10 the **grant is 0** and the floor is still **3**, deliberately: the
bug that rule prevented needs the app to pre-select a pair, and since 2.12
build 60 it pre-selects nothing (below). At a grant of 0 every route is
unaffordable until the user buys a pack, so the floor is no longer an
affordability gate at all — it is purely a QUALITY demotion, keeping the
picks the app still makes (auto-landed country, post-failure retry) off
inventory that delivers 12.1% at ≤5¢. **Do not "resync" it to 0**; that would
point failed-order retries at the worst inventory in the catalog.

⚠️ **The STARTER is no longer one of those picks (2.12 build 60).** There is no
first-run service/country pair at all — see "Nothing is pre-selected" below —
so a demotion cannot rescue it and does not have to.

### 🔴 The signup grant does not create pack buyers — do not raise it "so they can try it"

✅ **The grant is 0 as of 2026-09-10** (owner decision, acting on the
measurement below). `grant_signup_bonus` reads
`app_config.signup_bonus_credits`, and at 0 it returns BEFORE writing a
tombstone or a ledger row — so nothing is burned and raising it later still
pays a first-time address. Re-read it with
`select value from app_config where key='signup_bonus_credits';`, never from
this line. Two consequences that are not derivable from the code: a new user
now reaches the paywall on their FIRST order rather than after spending the
grant, and `wallet_transactions` gets no `signup_bonus` row at all, so
"did this user get a bonus?" is answered by `signup_grants` alone. The ops
signup alert already handles it, printing "no signup credit (grant is 0)"
rather than asserting a grant that never happened — the absence-of-evidence
bug is fixed, not merely documented.

Measured 2026-09-10 over every Production pack buyer (46). **Of the 34 who
ever placed a numbered order, 31 bought BEFORE their first order**, and for 28
of those the route they then ordered cost more than their grant (mean first
order 10 credits: whatsapp, instagram, tiktok, google, tinder, steam…). The
paywall that fires when *balance < price* is where pack revenue comes from.
Users who spent the grant first — with or without a code arriving — bought
packs at **3 of 267 (1.1%)**; the 76 who got a free code bought 5 credits
between them and placed 2.8 free orders each. The one 5-credit window (Aug
20–22, 98 signups) produced 1 pack buyer against 10 from the 2-credit cohort
of the prior eleven days.

**So a larger grant removes the only moment that converts and creates a
~1% buyer instead.** Wholesale cost of free orders is not the issue (~$4/month
delivered); displacement is. The owner made this call from instinct and the
data agreed. Re-derive (`kind = bought_first` is the number that matters):

```sql
-- first purchase vs first numbered order, per Production pack buyer
with paid as (select user_id, min(created_at) fp from iap_receipts
              where environment='Production' and granted_credits>0 group by 1),
fo as (select user_id, min(created_at) fo from orders where smspva_number is not null group by 1)
select case when fo is null then 'never_ordered' when fo < fp then 'tried_free_first'
       else 'bought_first' end kind, count(*) from paid left join fo using(user_id) group by 1;
```

⚠️ "First-order-delivered users buy at 26%" (cited 2026-09-09) was the same
confound: it counted users who bought first and then ordered on paid routes.
**Condition on orders placed BEFORE the first purchase** or the grant looks like
a conversion tool.

### 🔴 Nothing is pre-selected on first run (2.12 build 60)

`applyStartupSelection` computes no starter pair. A brand-new user sees **"Not
selected"** on both the Service and Country rows, price "—", no evidence strip,
and a CTA that walks them: *Choose a service* → *Choose a country* → *Get
number*. `AppState.needsServiceChoice` and `needsCountryChoice` clear only when
the user picks in `ServiceSheet`/`CountrySheet`, and **`confirmGetNumber`
refuses outright while either is set** — that guard is the backstop, not the UI.

⚠️ **Home's seven-logo grid is not an exception to this.** A tile tap goes
through `AppState.commitServicePick`, the same path `ServiceSheet.onPick` uses,
so it is the user's own pick: it clears `needsServiceChoice` and leaves
`needsCountryChoice` SET, which is why the Country row still reads "Not
selected" and `confirmGetNumber` still refuses. See "Home leads the app" above.

**Why, measured over the 45 days to 2026-09-09:**

| route chosen by | settled | delivered |
|---|---|---|
| the user | 302 | **35.1%** |
| the app (`from_default`) | 79 | **2.5%** |

Of 71 users whose FIRST order was app-picked, **1 got a code and 8 ever came
back**; the user-picked cohort delivered 26.8%. The pair was always
**deliveroo/us (62 orders, 43 users, 1 code)**, **uber/uk (27, 19, 1)** or
**olx/us (16, 11, 0)** — services nobody had come for, so the SMS was never
requested at all. `deliveroo/us` publishes a **77.3%** pool rate; that number is
probably honest and measures a pool nobody was texting.

🔴 **Two earlier fixes aimed at this and both missed, which is the lesson.**
The 2026-08-08 change hid the buy button behind `needsServiceChoice` but still
COMPUTED the pair — `from_default` orders fell from 46/week to 3 and then
returned (16 in the week of 08-24, 19 in 08-31, zero codes between them),
because paths reach checkout without passing through the service sheet. Earlier
still, the curated starter list was swapped away from telegram/instagram/google/
whatsapp/facebook because they measured ~9% delivered — **that swap traded 9%
for 1.9%**, because the measurement conflated "the provider did not deliver a
requested SMS" with "the user never requested one". **As long as a pair exists,
some path prices it and some path sells it.** The fix had to be deleting the
pair.

`affordableStarter`, `bestStarter`, `bestAffordableCountry` and
`affordableFallbackCountry` were deleted with it (141 lines).

### Changing the curve silently devalues every FIXED credit grant

Nothing recomputes them. The 3× → 6× change in 2026-07 cut what the 1-credit
signup bonus could reach from 971 routes to **24**, and those 24 were the worst
inventory — producing a 0%-conversion funnel. **The cliff is between 1 and 2
credits**: delivery roughly quadruples from 1 → 2 and is then flat through 3.
After ANY curve change, re-check `handle_new_user()` (signup),
`claim_daily_credit()` and `redeem_referral`.

**Changing the curve also breaks the PREMIUM tier until `premium_credits` is
recomputed.** `retail_credits` is rewritten hourly; `premium_credits` is not.
Assert `premium_credits >= retail_credits` is violated by zero rows after any
change.

### The cost smoothing is a RATCHET, not a symmetric EWMA

```ts
const smoothed = prev == null || cents > prev ? cents : Math.round(A*cents + (1-A)*prev);
```

A cost RISE applies immediately; only falls are smoothed. A plain
`0.5*new + 0.5*prev` averages a rise against yesterday's cheaper price and sets
retail BELOW what you are about to pay — that shipped once and put **4,384
routes under wholesale** in a single run. `sync-herosms` deliberately has none:
it records the raw observed cost and never derives retail.

### eSIM pricing (parked line)

Priced separately at 4× wholesale — `retail_credits = ceil(usd * 4 / 0.48)`, NOT
via the SMS curve, so the two product lines never collide.

### The pack ladder

**5/$2.99 · 8/$3.99 · 12/$5.49 · 20/$8.99 · 30/$12.99 · 60/$24.99**, asserted
by `assertLadderImproves()` (0.598 > 0.49875 > 0.4575 > 0.4495 > 0.433 >
0.4165 per credit).

✅ **`credits.20` added 2026-09-21** (`scripts/asc-create-credits-20.py`,
dry-run by default and idempotent; ASC id `6814392381`, submitted
`WAITING_FOR_REVIEW`). It was motivated by the 7 days to 2026-09-21, when the
largest paywall shortfall after 4 credits was **24** (76 `paywall_shown`
events across 40 distinct users) and nothing sat between $5.49 and $12.99.
⚠️ **But it does NOT serve that 24-credit arm.** `CreditsSheet` preselects the
smallest pack that COVERS the shortfall (`recommendedId` / `snapToAvailable`),
so a user short 24 (WhatsApp/US at 24 credits on a 0 balance) is still
pointed at the 30-pack; `credits.20` is the recommendation only for
shortfalls of **13–20**. The owner reviewed this on 2026-09-23 and chose to
keep it as is. (The comment on `credits.20` in `Models/CreditPack.swift`
still says it serves the 24 arm — it does not.) Packs are the only
high-margin line in the product (that week: 91% contribution, against 42%
for the line and 50% for mail). ⚠️ **Unread.** Judge it on `pack_selected` /
`purchase_result` for `credits.20` against paywalls with `needed` in 13–20,
not against the `needed: 24` arm and not on revenue in aggregate.

🔴 **`credits.150` is RETIRED FROM SALE — zero units sold, ever.** It is gone
from `CreditPack.all` and from `Products.storekit`, and BEST VALUE moved to
`credits.60`. It existed to lift the eSIM ceiling and that line has been
parked since 2026-08-29. ⚠️ **It is deliberately still ON SALE in ASC and
still in `PRODUCT_TO_CREDITS`.** Removing it at ASC would make shipped builds
that still list it render an "Unavailable" row, and pruning the backend map
would take a real payment from such a build and grant nothing —
`creditsForProduct` would return null. **That map is a decoder for receipts,
not a catalogue of what is on sale; never prune it when retiring a product.**
It dies out as builds adopt.

🔴 **A new IAP cannot be submitted without an App Store review screenshot.**
The submit fails 409 `STATE_ERROR.INVALID_REQUEST_ENTITY_STATE_INVALID` whose
top-level detail says only *"please check associated errors"* — the cause is
in `meta.associatedErrors`. Two blockers appear there together:
`IAP_SUBMISSION_NOT_ALLOWED_AVAILABILITY_NEVER_SET` (POST
`/v1/inAppPurchaseAvailabilities`; copy the 175-territory list off an existing
pack) and `ENTITY_ERROR.RELATIONSHIP.REQUIRED` on
`/data/relationships/appStoreReviewScreenshot`
(`scripts/asc-upload-iap-screenshot.py` — reserve, PUT, then **PATCH
`uploaded: true`**, or the asset is reserved and empty).
⚠️ **Read the screenshot relationship on `/v2`, never `/v1`** — the v1 path
404s `PATH_ERROR`, and a tool that prints that 404 as "none" makes it look
like no pack has a screenshot and the field is optional. Every pack has one.
⚠️ `availableInAllTerritories` is **not** an attribute on `inAppPurchases`
(409 `ATTRIBUTE.UNKNOWN`); territory availability follows the price schedule
and the availability resource.
⚠️ `-screenshot credits` is the fixture that produces the review frame, and
on `main` it needed `PrefKey.deliveryInfoAcked` set: `DeliveryInfoSheet` raises
on every Temp-tab appearance there and covered the pack ladder completely,
which read as the launch argument being ignored. (On branch `design-overhaul`
the sheet raises only at a Get-number tap, so the fixture no longer sets it.)

🔴 **ASC consumable price equalization is a ladder-inverting trap.** Every pack
carries MANUAL prices in both USD and EUR (same numeral); never set only the
base and trust equalization. This was not true for credits.60/150 until
2026-08-22, so every euro storefront showed Apple's equalized prices — and in
euros the 30-pack beat both larger packs. The client's `assertLadderImproves()`
cannot see it, because it runs against one storefront.

### `MAX_WHOLESALE_CENTS` and `blocked_routes`

Both price-based hides were removed on 2026-08-04. `MAX_WHOLESALE_CENTS` is
**100_000 in all FOUR syncs** (`sync-prices`, `sync-5sim`, `sync-herosms`,
`sync-smspva-operators`) and therefore non-binding. ⚠️ This file claimed for
weeks that it lived in three files and that HeroSMS's was 375 — both wrong,
corrected 2026-09-09 by grep.

🔴 **`blocked_routes` is NOT empty.** It holds **6,393 `"service|country"`
entries** as of 2026-08-21 — 6,392 of them SMSPVA-owned. It is the
**retired-provider kill list**, stopping `sync-prices` and the evidence un-hide
branches from re-activating routes belonging to a provider we no longer buy
from. ⚠️ This file said `[]` (its 2026-08-04 state) for three weeks after the
SMSPVA retirement repopulated it.

- **Nothing writes it from code** — it was set by hand, and `sync-5sim`,
  `sync-herosms`, `sync-prices`, `opsFormat.ts` and
  `refresh_route_observed_success()` only READ it.
- **Clearing it today would unblock 0 active routes.** It is a standing guard
  against a future re-activation, not live inventory management.

So when checking why something reads "Unavailable", look in this order:
`blocked_routes`, then cost vs `MAX_WHOLESALE_CENTS` (non-binding), then **no
stock** — which is the reason for essentially every hidden route.

## Steering and evidence

### Never tie-break on price, and never "fix" it by hiding inventory

Route-level evidence covers a tiny fraction of routes, so essentially every
route falls through to the tie-break — and that tie-break used to be **price**.
Cheapest-first is the one ranking rule guaranteed to select the least-vetted
inventory in the catalog: a sort literally labelled *"Best success"* was leading
with the bargain bin.

**Hiding the bad country does not work.** The price floor regenerates: delete
the cheapest country and the next one inherits the traffic, having thrown away
the only measurement you had. **Fix the rule, not the catalog.**

### The pool rate is the tie-break

`routes.pool_rate_pct` is 5sim's published **7-day** rate for the exact pool the
route buys from, written hourly by `sync-5sim`.

🔴 **It was `rate24` until 2026-08-05, and that misled users in both
directions** — the shortest, noisiest window 5sim publishes. Median
|`rate24` − `rate720`| is 9.6 points and 16.6% differ by 30+ points. Orders
before 2026-08-05 stamp `rate24`, after stamp `rate168`: **split any
correlation study on that date** or the halves are not comparable.

**`AppState.rankedUntestedKey` orders untested routes by *(pool tier, pool rate,
country tier, country record, price)*.** Two bugs got it here, both the same
shape — a ranker reading a different table from the row in front of the user:
it read a table covering 1,043 routes while the row rendered one covering 2,715,
and the country tier (a cross-service roll-up over a handful of orders) came
first, sorting the UK and US below countries we know nothing about.

🔴 **A published 0% sorts LAST, below unrated — and this deliberately differs
from the display sort.** The display lists 0% *above* unrated (measured values
descending, as the owner asked). The default *pick* does the opposite. The
distinction is between a list the user scrolls and a choice we make FOR them:
defaulting someone onto inventory the vendor itself reports as dead is the same
error as cheapest-first. **"No information" beats "reported dead".**

✅ **The rate DOES predict our delivery — settled 2026-09-13, and the number
stays on the row.** This was the test that justified the whole feature and it
had been open since the feature shipped. Run with both mandatory filters (only
`status in ('received','expired')`, only `created_at >= '2026-08-05'`, and
`from_default` excluded), over 295 settled orders:

| band shown | avg rate shown | OUR delivery per try | n |
|---|---|---|---|
| High (>60) | 73.5 | **46.9%** | 98 |
| Medium (30–60) | 44.5 | **39.6%** | 111 |
| Low (<30) | 12.0 | **17.4%** | 86 |

Monotone, and a 2.7× spread from Low to High. The earlier negative reading
(r = −0.51) was **n = 16 HeroSMS orders** — too small, wrong provider, and
taken before the `rate24` → `rate720` switch. ⚠️ **The LEVEL still overstates
in the High band** (73 shown vs 47 realised) while Medium and Low track
closely, which is why the row renders a colour-banded WORD and never the
number. Re-derive rather than quoting; the query is one `count(*) filter` over
`orders` grouped by the band.

🔴 **What this licenses, and what it does not.** It licenses steering ON the
band and telling a user that a green route is worth retrying. It does NOT
license "try N times" as a promise: per-try probability is 47% at best, so
three tries on High is ~85% only if attempts are independent, and a genuinely
dead route makes them correlated. The honest, defensible statement is
descriptive — **of the 82 users who ever got a code, 62% had it on try 1, 82%
by try 2, 89% by try 3, 100% by try 7** — and it describes people who
succeeded, so it must never be worded as a forecast for someone who has just
failed three times. On a Low route the right advice is a DIFFERENT COUNTRY,
not more attempts (17% per try, ~8 attempts to reach where High gets in 3).

### The grant size decides which ONE route new users land on

Not "how much they can buy" — **which single route the app picks for them**, and
that is where the whole cohort goes. Setting the grant to 1 once sent **16 of 16
subsequent orders to olx — from 9 different users, with zero olx orders before
that minute**.

⚠️ **This looked exactly like sabotage and was not.** Ruled out on six
independent checks: every order from a 1-credit balance, 0 identities with
`grant_count > 1`, 29 devices : 29 users, organic signup gaps, total cost $0.24
all refunded. **Before suspecting users, check what the app pre-selected** — and
note the cluster was on the CHEAPEST route in the catalog, the opposite of what
someone burning your money would pick.

✅ Fixed: candidates are ranked by pool rate, not array position. `preferred`
survives only as the FINAL tie-break, so brand recognition decides where the
evidence is silent and nowhere else.

**Corollary for any delivery analysis: an order on a route the user did not
choose is not evidence about that route.** Those orders were cited as proof a
pool was dead; that was wrong.

### Evidence must describe the provider that serves the NEXT order

Three silent bugs, all the same family.

🔴 **The general rule: a per-provider refresh may only write to a table that has
a provider column.** `routes` does. `services` and `countries` do not, so both
must be refreshed exactly once with per-order ownership filtering. The
per-provider loop previously OVERWROTE service evidence instead of adding to it,
and since it ran `order by 1`, **`smspva` sorted last and silently won every
service it co-owned** — including the highest-volume ones.

⚠️ **The wrapper's own comment asserted the invariant that made this safe. A
comment claiming an invariant is not the same as enforcing it.**

**Expect evidence to look emptier after a provider switch, and that is
correct.** "Not tested" beats a retired provider's number.

### Four evidence rules, all learned the hard way

1. **`is_code` is `otp is not null`, NOT `status = 'received'`** — a rescued
   code lives on a `canceled` row. Five SQL functions and one Swift property
   keyed on the old predicate and scored a delivered code as a failure.
2. **Only orders that actually got a number are evidence.** Orders that die
   inside `create-order` close in under a second with a null number and used to
   count as delivery failures. That was self-reinforcing: one user tapped
   TikTok/Netherlands 8 times in 90s and **deleted the route from the catalog**.
3. **The lookback is 30 days and the wipe is CONDITIONAL.** At 3 days with an
   unconditional wipe it left exactly one measured route in a catalog of 17,807.
4. **Auto-hide for poor delivery is GONE — label, don't hide.** Hiding for
   PRICE and for `blocked_routes` is untouched: those mean "you cannot buy
   this", not "this performed badly". The un-hide statement **must** exclude
   `blocked_routes`.
   ⚠️ **ONE hand-made exception exists: `google/us`, hidden 2026-09-21 by
   owner decision** (migration `20260921100100`). It delivered **0 of 25
   settled orders** in the 14 days to then — the app's highest-volume route
   that week and the only one with an empty column — while 5sim published
   `pool_rate_pct = 41` for it, so the vendor figure and our outcome disagree
   completely. **This does not reintroduce auto-hide**: no threshold was
   added and nothing hides itself; 0-of-25 is "has never once worked", not
   "performs badly". It cost no cash (5sim refunds cancels and expiries) —
   the cost was a 7-credit charge refunded 25 times to users who then left.
   🔴 **The `routes.status` write alone does NOT hold — `sync-5sim` runs
   hourly and re-activates anything that prices and stocks fine.** The route
   was also appended to `blocked_routes`, which is the only guard that
   survives the sync. Hide anything by hand and you must do both halves.

🔴 **Our own record is no longer rendered anywhere (owner decision 2026-08-22).**
"Worked X of Y times", "Not tested" and the odds sentences are gone from every
screen. The vendor's NETWORK rate is the only delivery figure a user sees.
`DeliveryRecord`, `routes.success_codes`, `routeKey`, `bestCountry`, `retryKey`
and `Country.deliversPoorly` are unchanged and still decide where the app points
a user — they just say nothing on screen. **Do not reintroduce a record label
without the owner.**

Two rules that still govern the DATA: **a seeded vendor rate is `.notTested`**,
and **"2 of 7", never "29%"** — a percentage off a 7-order sample wears the
confidence of a 700-order one.

### Never present seed data as measured fact

`Service.successRate` is seed data (86–99% across all services). Show only
values gated on real observed samples, and show **nothing** when there is no
measurement. `WaitingScreen` was the last violator — it promised ~91% right
after payment on clusters that actually measure ~9%.

**Same rule for the app's ONE user-visible delivery figure.** The vendor's
network rate renders as a colour-banded WORD (High >60 / Medium 30–60 / Low
<30) rather than a percentage: a third-party aggregate with no published
denominator should not wear two significant figures. Sorting, stamping and ops
surfaces stay numeric.

**Never name or allude to a supplier in user-facing copy** (owner decision). The
app must not advertise that it resells someone else's inventory. The row itself
still carries the word **"network"** beside the band, which is what keeps the
figure from reading as a measurement of our own fulfilment.

⚠️ **The longer disclaimer — "not our own delivery record" — is GONE from
`DeliveryInfoSheet` (owner, 2026-09-13), and this paragraph used to forbid
that.** It was written when the published figure had never been checked against
our outcomes and ran ~2× them, so restating it unattributed really would have
been borrowing a claim. That changed the same day: the band is now MEASURED to
predict our delivery (47% / 40% / 17% per try, n = 295 — see "The pool rate is
the tie-break"), and the sheet shows a band WORD and advice rather than a
figure. **The naming ban is untouched and absolute.** Do not read this as
licence to drop attribution wherever a raw third-party number is printed.
("Carrier" is fine and is not the
same thing — the Real SIM tier's "named mobile carrier" means Verizon/T-Mobile,
which is the product, not our wholesaler.)

### Retry steering

A retry after a failure must not hand back the same dead pool. Two mechanisms in
`create-order`: a **fresh-number guarantee** (numbers this user already burned on
this service are excluded) and **operator rotation** (pick the cheapest untried,
non-`Donor*` real carrier that still fits `maxCostUsd`). Fallbacks are
asymmetric on purpose — **standard** drops to unpinned; **premium** keeps the
route pin, because the buyer paid for *that* real-SIM pool and must never be
silently downgraded. Rotation is wrapped in try/catch: it is an optimization,
never a reason to fail an order.

**The recovery card's country offer (client, 2.12 build 61) resolves in this order:**
our own measured record ≥ 40% → the best **High-band pool** by the vendor's
hourly `pool_rate_pct` (> 60, `bestPoolRatedCountry`, never the failed
country, never a route our record says delivers nothing, affordable on the
refunded balance) → the weekly vendor top-10 (`bestRankedCountry`) → "Try
again" on the same route with a fresh number. The pool step was added because
paying users' orders delivered 34% (Sept 23%) and, with our own record
covering a handful of routes and the top-10 scrape going stale between
manual runs, the card's realistic fallback was the pool that had just failed.
It renders the band WORD via `NetworkRateMeter`, hides the meter under
`delivery_metrics_hidden`, and says in one sentence that it is not our record.
Events (2.18+, unread): `recovery_shown` once per presentation and
`recovery_action` (`action` ∈ `retry` · `not_now` · `close`), both carrying
`offer` ∈ `own_record` · `pool_band` · `top10` · `retry_same` (the branch
above), `service`, `failed_country`, `reason`, `to` (the named country) and
`refunded`. Before 2.18 the card emitted nothing.

### Measured arrival timing

`services.eta_seconds` is seed data (22–35s) and the app used to render it as
fact in four places. Measured median arrival is **~53s** with p90 ~139s, so the
app promised a wait it could not keep and users cancelled believing the code was
overdue — while 86% of codes ever delivered arrived inside that window.
`arrival_p50_seconds`/`p90`/`sample`/`scope` are filled by
`refresh_arrival_timing()`. The client returns **nil rather than a guess**.
`arrival_scope` matters: a **global** band must never be worded as this
service's own record.

## The temp-SMS product

### The delivery explainer (2.14, owner design 2026-09-13)

**On branch `design-overhaul` (2026-09-24) it opens at the user's first SMS
Get-number TAP, not on tab appearance** (spec §6.4, pulled forward because the
store is now the app's first screen). `TempScreen.startNumberOrder` raises the
GATED sheet instead of starting checkout while `PrefKey.deliveryInfoAcked` is
unset; the sheet's `onDismiss` re-reads the key and, only if it is now
written, continues with the same `onStart` (`startCheckout()`) a normal tap
uses. 🔴 **That tap is the PRIMARY showing, not the only one: `CheckoutScreen`
carries a BACKSTOP.** The key is per DEVICE while orders live on the server, so
a reinstalled or new-device user can reach checkout without the tap (Activity
→ `buyAgain`, the recovery card's retry, `OtpScreen`'s "another code"). Every
paid SMS order is confirmed in `CheckoutScreen`, so with the key unset its Get
number raises the same gated sheet inside the cover and calls
`confirmGetNumber` only after acknowledgement. It never shows twice — the
primary showing writes the same key. Both gated showings send
`delivery_info_shown{source: "auto"}` (one series) plus `at` ∈ `get_number` ·
`checkout` (also on `delivery_info_acknowledged`); the ⓘ sends `source:
"button"` and no `at`. The gate (10 s dwell + reaching the end), the V2 key and
the ⓘ (ungated) are unchanged. ⚠️ Build- and screenshot-verified only; neither
tap-then-continue path has been walked (no tap automation). The `credits`
fixture no longer writes the key. **The text below describes `main`.**

`DeliveryInfoSheet` opens on EVERY appearance of the Temp tab in SMS mode
until the user acknowledges it — *"wether they ordered before or not"* (owner,
2026-09-13) — and from an always-available ⓘ in that tab's header. It targets
the largest measured leak in the app: of 303 users who ordered at all in the
60 days to 2026-09-13, **166 placed exactly one order**, three quarters of them
leaving without a code. Success by persistence runs 25% / 34% / 52% / 64% /
83% across the 1 / 2–3 / 4–6 / 7–12 / 13+ bands, so the people who behave the
way the product works do fine and the majority quit at the first failure.

🔴 **The automatic showing is GATED: the CTA is grey and inert until the
reader has BOTH reached the last section AND spent 10 seconds on screen**
(`DeliveryInfoSheet.dwellSeconds`), and the sheet cannot be swiped away while
it is. Owner's design, and the reasoning is that the friction is the message —
a screen you must work through reads as important. Both conditions are needed:
a timer alone rewards waiting without reading, a scroll alone is satisfied by
one flick. **The ⓘ path is deliberately UNGATED** — that user chose to open
it, and making them re-earn it is punishment, not instruction.

🔴 **Three copy rules, and breaking any of them makes the screen worse than
nothing:**

1. **It leads with the REFUND, not with a try count.** A failed attempt costs
   the user nothing (all 311 non-delivering orders in 30 days carry a refund
   row) and costs us nothing (`five.cancel` reclaims the wholesale on both the
   cancel and the expiry path). That fact removes the actual reason people
   stop; a recommended number does not.
   ⚠️ **On branch `design-overhaul` the refund card is GONE (owner decision
   2026-09-25, from a device screenshot: "remove completely").** The sheet
   now opens on the headline, then the band legend and the try count; the
   refund is no longer stated on this screen (it still shows on the recovery
   card after a failure). This rule describes `main`; do not re-add the card
   on the branch without the owner.
2. **The advice BRANCHES BY BAND.** High 47% per try, Medium 40%, Low 17%
   (n = 295, see "The pool rate is the tie-break"). "Try again" is correct on
   High and WRONG on Low, where the copy says *pick another country* — about
   eight attempts to reach where High gets in three. Never flatten this into
   one instruction.
3. **The count is DESCRIPTIVE, past tense, about people who already
   succeeded** ("nine in ten people who get a code have it within three
   tries" — 89% of the 82 who ever received one). It is NOT a forecast: per-try
   probability tops out at 47%, and the app's only organic review is already
   someone angry about a promise that did not hold.

⚠️ No supplier is named — that ban is absolute — and the band legend hides
under `delivery_metrics_hidden`, since a legend for an invisible control is
worse than none. The "not our own delivery record" disclaimer was REMOVED from
this sheet on 2026-09-13; see the note under "Never present seed data as
measured fact" for why that is now defensible and where it still is not.

🔴 **There are FOUR bands, and the fourth covers most of the catalogue.**
6,443 of 9,336 active routes publish no figure at all (2026-09-13: every route
on the second network, plus 64% of the first's), so a route with NO delivery
label is the commonest thing a user sees. The legend says those are just as
worth trying, from a network that does not publish figures. ⚠️ That claim is
"not distinguishable", not "proven equal": rated routes deliver 35.6% per try
(n = 295), unrated ones 33.3% on the other network (n = 18) and 28.6% overall
(n = 28). Twenty-eight orders cannot separate those. **It is the only row
making a positive claim about inventory we hold no vendor figure for — soften
it if a real sample opens that gap.**

**Mechanics that reading the code does not give you:**
- 🔴 **`onAppear` CANNOT detect "scrolled to the end", and using it made the
  gate decorative.** A `VStack` inside a `ScrollView` realises every child
  eagerly, so a bottom sentinel's `onAppear` fires at presentation while it is
  far below the fold — the CTA rendered green on the first frame. The working
  mechanism is **`onScrollVisibilityChange`** (iOS 18+, the project floor),
  hung off the support CARD rather than a hairline spacer: a 1pt view's
  visibility fraction is a coin-flip against any threshold, and reaching the
  last section is what "reaching the end" means to a reader. **Caught in the
  simulator, never by reading the code — which is the argument for walking any
  gate you add.**
- 🔴 **`PrefKey.deliveryInfoAcked` (`temp.deliveryInfoAckedV2`) is written on
  the ACKNOWLEDGEMENT, not on
  presentation.** Writing it when the sheet appears would let a force-quit
  mid-read skip the screen forever, which is the one outcome the gate exists
  to prevent.
- ⚠️ **It is stored in `UserDefaults.standard`, which is DEVICE-global and
  survives Delete Account — so the explainer CANNOT be re-tested by deleting
  your account and signing up again** (owner hit exactly this on 2026-09-13:
  a brand-new account on an already-acknowledged device saw no sheet). Only
  deleting the APP clears it. Nothing in the client removes this key, and
  nothing should: the same human on the same phone has already read it, and
  keying the gate to the user id would re-wall someone who acknowledged it
  five minutes earlier. The cost is a second-hand or shared device, which is
  the rarer case. **A device walk of this screen therefore needs a fresh
  install, not a fresh account.**
- 🔴 **The key is VERSIONED and the suffix is the point.** Bump it when the
  ADVICE materially changes; that is the only way an existing user is shown
  the screen again, and this advice is branched on delivery bands that move.
  ⚠️ It is at **V2** because the dwell went 5s → 10s, which is a TIMING change
  and not strictly an advice one — that bump was free only because the screen
  has never shipped and the sole device carrying V1 was the owner's. Once it
  is in the App Store, apply the rule as written: bump for what the screen
  SAYS, never for how long it holds. The pre-gate `temp.deliveryInfoSeen` is
  dead and deliberately NOT read — anyone carrying it saw an ungated screen,
  so honouring it would exempt exactly the users this exists for.
- **It does not raise over a live `state.flow`.** A checkout, waiting screen or
  code is an order in progress; a sheet there interrupts one rather than
  informing one. It re-checks when the flow ends and when e-mail mode is
  switched off, because the tab is not re-created in either case.
- **`PrefKey.deliveryInfoAcked` gates the AUTOMATIC showing only.** The ⓘ
  ignores it: most people meet this screen after a failure, by which time the
  copy they acknowledged on day one has been forgotten.
- ⚠️ **The ⓘ costs ~36pt in a header row that was already full**, and both
  obvious fixes break something: without help the eyebrow truncates mid-word,
  and with `layoutPriority` on the eyebrow the CREDIT PILL clips instead. The
  fix is the eyebrow's **three**-line limit. Do not "tidy" it back to two.
- **`-screenshot deliveryInfo`** exists because the sheet is otherwise
  reachable only by a tap and tap automation is unavailable on this machine.
- Six of its 17 strings are RUNTIME lookups through `SectionHeader` /
  `PrimaryButton` that Xcode's extractor cannot see, and were written into
  `Localizable.xcstrings` by hand. **Adding a string to either component means
  adding the catalog entry yourself** — this is how six translations once
  shipped and reached no button.

Events: `delivery_info_shown` (`source` = `auto` | `button`),
`delivery_info_acknowledged` (`seconds` actually spent) and
`delivery_info_support_tapped`. **Read the `auto` arm against the one-try quit
rate**, which is the thing it exists to move; the `button` arm answers a
different question. ⚠️ **Watch `shown` minus `acknowledged` on the auto arm** —
a large gap means people are abandoning the Temp tab at the wall rather than
reading it, which is the cost side of this design and the number that would
justify shortening the dwell. Re-derive the baseline before judging it:
```sql
select case when n=1 then '1 try' when n<=3 then '2-3' when n<=6 then '4-6'
            when n<=12 then '7-12' else '13+' end band,
       count(*) users, count(*) filter (where codes>0) got_a_code
from (select user_id, count(*) n, count(*) filter (where otp is not null) codes
      from orders where smspva_number is not null
        and created_at > now()-interval '60 days' group by 1) u
group by 1 order by min(n);
```

### The minimum hold (90s) and the late-code rescue

⚠️ **The hold is PER-PROVIDER — `MIN_HOLD_BY_PROVIDER` in `cancel-order`, all at
90 today.** Measured over every code ever delivered, HeroSMS has NEVER arrived
after 86s while 5sim's p90 is 155s; one number cannot be right for both.

🔴 **5sim is deliberately held at 90, not its p90 of 155.** Raising the server
first unlocks a Cancel the server then refuses. **The client may only ever be
RAISED ahead of the server**, never behind it — that invariant was broken once
and reverted the same day.

Cancels landed at a **median of 57s**; codes arrive at a **median of 58s**.
Users were destroying orders one second before the typical code.

1. **`cancel-order` refuses to destroy an order held under the minimum**,
   returning **429 `cancel_too_early`** with `retry_after_seconds`. It covers
   **reroll too** — a reroll releases the number identically. 429, not 409, is
   deliberate: shipped builds without a case for the code fall back on HTTP
   status, where 429 reads *"You're going a bit fast"*.
2. 🔴 **`cancel-order` NO LONGER CALLS `release()`.** It refunds, stamps
   `late_watch_until`, and leaves the number alive. If a code lands, we write it
   and push it — **the code is given away free and the refund stands**.

⚠️ Do NOT justify a longer hold with "otherwise the code is lost": since the
rescue landed, a cancel does not release the number. **The hold protects the
code from a REROLL, not a cancel.**

Three constraints in that path:
- **Status stays `canceled`.** `order_status` cannot grow a value without
  shipping the app first, so a rescue is an `otp` on a canceled row.
- **The push carries no `orderId`** — `PushManager` routes on it and would
  deep-link into the refund screen instead of the code.
- **The sweep runs BEFORE the polling loop.** It was last, so it was the first
  thing dropped under load — exactly when held numbers cost most.

**`markDead` cancels FIRST, then bans.** `cancelorder` reclaims the wholesale;
`blocknumber` is hygiene.

**`resumeInFlightOrder()` runs on COLD LAUNCH ONLY.** Never call it from a
`scenePhase` change: a backgrounded app still holds `flow` in memory, so it
would yank the user out of whatever they had navigated to.

### 🔴 The second-code resend window

**`markSuccess` IS DEFERRED for eligible 5sim orders — DO NOT MOVE IT BACK TO
CODE ARRIVAL.** For 5sim it is `five.finish()`, and finishing an order
permanently forecloses a second SMS on that number. Calling it on arrival is
what left a user who needed a re-sent code with no way to get it on the number
their account is registered on.

Since 2026-09-08 the claim in `poll-active-orders` **and in `check-order`**
writes `resend_watch_until = now() + 5 min` on a pool `fivesim.supportsResend()`
accepts, and SKIPS the finish. **Both call sites must stay in step** — the
manual "Check now" path silently lost the window when only the cron path had it.
The failure mode is safe by construction: if the sweep never runs, 5sim closes
the activation itself after five minutes.

⚠️ **It has never delivered a second code.** The pool list is 5SIM'S CLAIM, not
our measurement. **The first `resend_promoted` line in the `poll-active-orders`
logs is the proof.** Cost of the list being wrong is bounded: we hold an
already-paid-for number open for five minutes and show a countdown for a code
that cannot come.

🔴 **Reuse does NOT work — disproved twice.** `user/reuse/{product}/{number}`
returns 400 `"reuse not possible"` after a CANCEL *and* after a FINISH, balance
untouched. **There is no way to give a user a second code on a number we already
sold them**, and `create-order`'s fresh-number guarantee deliberately redraws
away from it for an hour anyway. Not-hanging-up is the mechanism that works.

⚠️ **HeroSMS has an equivalent (`STATUS_RETRY = 3`, "request another code on the
SAME number, free") and NOTHING CALLS IT** — a wrapper with no caller anywhere,
the same shape as the six `line_subscriptions` updaters that shipped with no
INSERT. Left out deliberately: it is an explicit *request another* verb rather
than a hold-open, so it needs its own semantics.

**5sim behaviours settled by PAID PROBE — do not re-run the experiment modes,
the answers are arithmetic:**
- **Cancel REFUNDS, fully.** With ~60% of numbered orders cancelled, this is the
  one that would bleed float on every order if it were ever false.
  🔴 **EXPIRY reclaims too, by the same call** — `poll-active-orders` sends an
  expired order to `markDead`, which for 5sim is `five.cancel` then
  `five.ban`. So **a failed delivery costs NOTHING at the provider**: the user
  is refunded in credits (all 311 non-delivering orders in the 30 days to
  2026-09-13 carry a `refund` ledger row) and 5sim refunds the wholesale. We
  pay only for codes that arrive — $15.52 over those 30 days against $234 of
  pack revenue. ⚠️ Do NOT read `sum(actual_cost_cents)` as money spent; see
  the runway correction under "Balance alerts".
- Both fresh buys read `status: RECEIVED` with `sms: null` at t=0. **RECEIVED
  means "number received", never "code received"** — live proof that
  `sms[].code` must stay the only authority.
- **`maxPrice` EXISTS but only when `operator=any`.**

### The Real SIM tier and VoIP-only routes

`app_config.voip_strict_services` (`["facebook","instagram","whatsapp"]`) is a
hand-maintained list. Meta rejects VoIP ranges, so routes for those services
with zero real-SIM stock are hidden. This is "we cannot deliver this" — the same
category as `blocked_routes`, **not** a judgement on measured performance, so it
does not contradict the "label, don't hide" rule.

⚠️ **STILL UNTESTED, and beware a tempting false refutation.** `facebook/dk` has
`physicalCount = 0` and delivered 4 of 5 — but `physicalCount` is a **HeroSMS**
stock metric and those codes were delivered by **SMSPVA**. Comparing one
provider's inventory figure against another's outcomes is meaningless. The
hypothesis is **untested, not falsified**.

🔴 **`physic` is a POOL, not a synonym for "physical".** HeroSMS lists an
operator literally named `physic`; it is one narrow pool, frequently empty for
services that have thousands of real numbers elsewhere. For badoo/us: `physic`
**0**, at_t 131, tmobile 4,179, **verizon 14,224**, **textnow (VoIP) 458,985**.
Pinning `physic` alone hid 71 perfectly serviceable US routes. Note also that
one VoIP operator is ~96% of the US pool.

**We pin every real carrier, not one** (`routes.herosms_real_operators`, a
comma-separated list). Keeping only the maximum meant that when one carrier ran
dry we fell back to the UNPINNED pool — which is overwhelmingly VoIP, i.e.
exactly the stock strict services reject.

**`herosms_real_count is NULL` means "never probed"; 0 means "probed, none
there".** That distinction is load-bearing: hiding on "not probed yet" briefly
took the three strict services from 62 hidden routes to 185 — punishing the
highest-volume services for our own backlog.

## The temp-e-mail product

Temp mailboxes on **mail.com, gmx.com, email.com, outlook.com and hotmail.com**
(the first three added 2026-09-24, owner decision: ~$0.003 each with 570k–740k in
stock, while outlook.com was down to 20). **mail.com is the default**, because
`email-domains`' `ORDER` puts it first and the client picks the first domain in
stock, so the order is the default for every shipped build. ⚠️ The three new
domains' delivery was unproven when they were added; the per-domain watchdog
covers them. Read their first days with the query under "Per-domain delivery IS
monitored" before trusting them. ⚠️ Builds ≤ 2.18 still say "On outlook.com and
hotmail.com" on the Mail paywall. An address is
**INCLUDED** (0 credits) while the user still has their one free lifetime
address or holds the Mail subscription under its caps. **Anyone NOT covered
may instead pay `EMAIL_PAID_CREDITS` (1 credit) for that one address, refunded
automatically if no code arrives** (owner decision 2026-09-22) — see "The
1-credit fallback" under the subscription section below.

**Services that register by PHONE get a warning in e-mail mode, not a block**
(owner decision 2026-09-23, "option B" — the pre-selected service, WhatsApp
for a first-run user, stays). `Service.phoneOnlySignupIds` is the ONE list
(`whatsapp`, `google`, `signal`, `viber`, keyed on `Service.id`);
e-mail codes delivered over 60 days to 2026-09-23 were whatsapp 2/48, google
0/8, signal 0/7, viber 0/1. ⚠️ telegram is deliberately EXCLUDED: it
registers by phone but measured **4/14** delivered, so the warning would be
false there. When one is selected in e-mail
mode, `TempScreen.phoneOnlyNote` sits in the hero directly above the e-mail
CTA: "*{service}* signs you up with a phone number, not an e-mail." plus
"Get a number for *{service}* instead", which calls `commitServicePick` (so
it is the user's pick) and switches to SMS mode — `needsCountryChoice` is
untouched, so the Country row still reads "Not selected". The e-mail CTA
stays live. Events `email_phone_only_note_shown` / `email_phone_only_switch`
(`service` = id); read switch/shown, and whether those users then order SMS.
⚠️ Build-verified only, never walked on a device.

**gmail.com was REMOVED 2026-08-26** — its pool stopped delivering (1 code in
its last 36 orders, 0 of the last 23, while the free pair delivered normally in
the same window, so it was the pool, not the users). It was the only paid tier
and every failure charge-and-refunded. ⚠️ **It is also EXCLUDED from the
per-domain watchdog check**, so there is no longer any automatic recovery signal
for that pool. Re-adding it requires TWO edits in one commit: put gmail back in
`PRICING` (both copies) AND delete the exclusion in
`watchdog_delivery_checks()`, then verify delivery by hand before selling.

**icloud.com was removed 2026-07-31** — handing out throwaway addresses on
Apple's own consumer domain, from an app on Apple's store, is an avoidable
review risk. Both removals are enforced the same way: deleting the key from
`PRICING`, which `create-email-order` rejects with `domain_unavailable`. ⚠️
**`PRICING` is duplicated in `create-email-order` and `email-domains` — change
both together.**

**E-mail exists to acquire users, not to earn.** The subscription is its
monetization; the 1-credit fallback exists so a user who is not covered is
never dead-ended, not as a revenue line.

**It is a SECOND protocol on the same HeroSMS account**, sharing only the key and
the balance:

| | SMS (`herosms.ts`) | EMAIL (`heromail.ts`) |
|---|---|---|
| base | `/stubs/handler_api.php` | `/api/v1` |
| shape | query params + actions | REST resources |
| auth | `?api_key=` | **`Authorization: ApiKey <key>`** |
| errors | bare text (`BAD_KEY`) | `{"title","details"}` |

⚠️ **The auth scheme costs an hour if you guess.** Every wrong scheme returns
`{"title":"Unauthenticated."}` — the SAME body an unknown route returns *after*
auth — so a wrong header reads exactly like "this API does not exist".

**Three provider behaviours you cannot guess:**
1. **A hard 2-minute cancel floor.** `DELETE` inside 120s returns
   `EARLY_CANCEL_DENIED`. Provider-enforced, so a cancel affordance live before
   then is a guaranteed failure.
2. **The window is ~20–21 minutes and it AUTO-REFUNDS.** Our
   `EMAIL_WINDOW_SECONDS` is 22 min, deliberately LONGER, so their terminal
   state is what we normally observe. Shorter would race a provider still
   holding a live mailbox.
3. **`CANCEL` is OVERLOADED** — it means both a user DELETE and their own
   timeout, with nothing separating them. Only the caller knows which, so
   merely observing `CANCEL` means **expired**.

🔴 **`email_orders.status` is OUR enum, never the vendor's.** Their vocabulary
is undocumented and probing only ever produced `WAIT` and `CANCEL`; the value
meaning "a code arrived" has never been seen. Encoding a guess is exactly what
broke eSIM refunds. **`code is not null` is the authority**, never
`status = 'received'` — the same rule as the SMS side's `otp is not null`.

**There is no catalog to sync.** `site` is required and stock is per (site,
domain) and genuinely runs dry — one sweep measured 1,028 available for
google.com and **TWO** for discord.com. Never cache it.

**Branch `design-overhaul` (2026-09-24): the domain quote is PREFETCHED and
has an explicit pending state.** Owner report: the E-mail segment "glitched"
— for the whole `email-domains` round-trip (p50 1.4 s, p90 2.4 s, edge logs)
it rendered live placeholder UI ("Choose one", a 22pt "—", a live "Choose a
domain" button, the 20-minute refund line even for a free domain) and then
snapped to the answer, growing the card twice. What is true now:
- **Prefetched at cold start, UNAWAITED.** `loadAccount` calls
  `AppState.prefetchEmail` straight after `loadOrders`: the quote for
  `startupService` (the rule `applyStartupSelection` applies — the last
  order's service, else `lastService`, which is what a first-run user's
  E-mail mode shows) plus `loadEmailOrders`, which no longer waits behind the
  eSIM loads, so `hasUsedFreeEmail` is LIKELY (not guaranteed — nothing waits
  on it) right by the first e-mail frame; a late answer changes the label.
  Nothing on the reveal path awaits either; a failed prefetch is SILENT (no
  banner) unless a user's entry joined it and nothing can be shown — then
  the banner shows, as for any user-asked failure.
  `mailStore.load(reportingFailure: false)` warms the mail plan's StoreKit
  price on `bootPhase == .ready`.
- 🔴 **A held quote under 10 minutes old is shown AND sold from (owner
  intent, 2026-09-24: tapping E-mail must not show loading).** Entering or
  re-entering e-mail mode, or closing a flow, with such a quote for the
  service on screen renders it at once with the CTA LIVE and refreshes it
  silently — no spinner, no disabled CTA; the refresh crossfades only what
  changed and re-picks the selection if its domain went out of stock.
  `AppState.emailQuoteDisplayWindow` = 10 min. **What makes this compatible
  with "Never cache it": the ORDER is the authority.** `create-email-order`
  re-quotes the provider for the exact (site, domain) and refuses
  `email_out_of_stock` / `domain_unavailable` / `margin_too_low`, all mapped
  in `APIError`, so a stale "in stock" costs one refused tap and no money;
  every entry still refetches.
- **"Pending" now means ONLY: no quote for this service is held, or the held
  one is older than 10 min.** `AppState.emailQuote` (`idle`, or `loading` /
  `loaded` / `failed` naming their service) is set SYNCHRONOUSLY by
  `requestEmailQuote` before any await, so in that case the first frame is
  the pending layout: the answered geometry with redacted content (domain,
  cost, the refund line's fixed two-line slot, a subscriber's meter line) and
  a disabled "Get email address" with a spinner; the answer crossfades in
  (`RMotion.content`, nil under Reduce Motion, scoped to the hero rows).
- **Failure:** a failed refresh under a held, in-window quote keeps showing
  it — logged (`print`), no banner. Only with nothing to show does the card
  switch to a "Couldn't load domains · Try again" row in place of the Domain
  row (plus the error banner when the user asked, including a user entry
  that joined the prefetch).
- **Staleness guard:** an answer applies only if it is still the latest
  request asked (a generation counter), the user is in e-mail mode or it is
  the prefetch, and its service is the one on screen; otherwise it is
  dropped and the status goes `.idle`. A second request for a service
  already in flight joins it. **A pending card with nothing in flight is
  re-asked** (`emailQuoteStalled`, observed in ContentView) — that state
  arose when an answer was dropped while another product's flow covered
  e-mail mode (Activity's buy-again mid-fetch) and nothing re-asked on close.
- **A background refresh never writes over newer data or under an order.**
  `emailUsage` / `emailCreditPrice` sit on a write clock (`writeEmailUsage`):
  every write carries the tick its request was ASKED at, so a quote asked
  before an order cannot overwrite `refreshEmailUsage`'s post-order meter or
  a refusal's `credit_price`. And while an e-mail order is in progress or a
  paid-retry offer is pending (`flow != nil`, `isBuyingEmail`,
  `emailPaidOffer`) no refresh moves `emailDomain`
  (`emailSelectionFrozen`) — the `pay_credits` retry buys what the user
  agreed to.
- **The credits context names the ORDER's domain inside an e-mail flow.**
  `emailIntentDomainName` / `emailIntentDomainCredits` (read by
  `creditsShortfall` and `CreditsSheet`'s title and cost) use the active
  e-mail order's domain on the waiting / code screen — which can be opened
  from Number mode, where `emailDomain` is the prefetch's pick for an
  unrelated service — and the selection only when buying from e-mail mode.
- **The domain SELECTION now survives leaving e-mail mode**; `applyEmailQuote`
  re-validates it against the fresh list. The exit branch still clears
  `intent`, `emailCreditsNeeded`, `emailPaidOffer` and `showMailPaywall`.
  `flow`'s didSet still clears `emailDomain` on every `flow = nil`, so
  ContentView re-quotes when the selection is cleared under a settled,
  in-stock quote in e-mail mode — by the same rule: an in-window quote
  re-picks the selection at once and refreshes silently.
- Fixtures: `emailLoading` (pending; screenshot mode skips the fetch),
  `emailReady` (= `emailStore`, seeded through `applyEmailQuote`, which the
  fetch no longer wipes) and `emailFailed` (the retry row). ⚠️ `emailReady`
  and `emailFailed` wait on a live catalog fetch, so a capture taken too
  early still shows the pending card (seen at 7 s and, once, at 12 s);
  capture at ~20 s. ⚠️ Build- and screenshot-verified only; the prefetch
  timing, the silent refresh, the crossfade, the stall recovery, the write
  clock and the frozen selection have never been walked on a device.

**`expire_email_orders()` has two traps** that would make a copied
`expire_esim_orders()` look like a working deploy while matching nothing:
`email_orders.expires_at` is a **DEAD COLUMN** (nothing has ever written it), and
the terminal status must be **cast** (`::email_status`) or the UPDATE raises
42804.

### Per-domain delivery IS monitored

`email-domain-<domain>` pages when a domain has **≥ 8 orders in 14 days with
ZERO codes while at least one other domain delivered in the same window, AND its
most recent order is within 72 hours**.

- **The cross-domain condition is the whole design.** Without it a total HeroSMS
  failure would page here three more times on top of the checks that already
  cover it, and **alert fatigue on the one channel is how the next real outage
  gets missed.**
- The 72-hour condition makes the check go quiet on its own within three days of
  a domain being pulled, instead of paging 6-hourly about a decision already
  taken.
- Orders younger than 1 hour are excluded: the provider window is ~21 minutes,
  so a fresh order has not failed, it is waiting.

### The subscription (enforced since 2026-08-22)

Two Apple products in a **SECOND, SEPARATE subscription group from the line**.
🔴 **A second group is mandatory, not a preference** — Apple allows one active
subscription per group with no quantity on iOS, so a mail product in the LINE
group would make a $2.99 mail purchase REPLACE a subscriber's phone number.
A user may legitimately hold both, and nothing may assume otherwise.

`has_email_subscription(uuid)` is the entitlement check: `state in
('active','grace') and greatest(expires_at, grace_expires_at) > now()`.
🔴 **`greatest`, NEVER `coalesce`** — a subscriber who went through grace and
then renewed carries a STALE `grace_expires_at` in the past alongside a fresh,
later `expires_at`, and coalesce takes the first non-null regardless of which is
later, reporting a fully-paid subscriber as inactive. **That bug shipped once
already.** Any copy of this predicate must be re-diffed against this function,
not against the brief that specified it.

**The free rule is lifetime-and-retroactive**, not per-day:
`email_free_lifetime_grants` (1) counted over ALL history. A subscriber instead
gets unlimited free-domain addresses under `email_sub_daily_cap` — a stated
hard stop, not a throttle, because the free pool is scarce and shared and one
looping subscriber could drain it for everyone.

✅ **CAPS RAISED 2026-09-24 (owner): daily 8 → 10, rolling 30-day 60 → 100**, written
live to `app_config` and read back through `email_usage` (10 / 100). The history
below explains how 8 and 60 were derived and stays as the record.

🔴 **The wholesale price of an address fell ~15× on 2026-09-23: $0.051 → $0.0034**
(read from the provider dashboard by the owner, and matched by our rows: `actual_cost_cents`
is 5 through 2026-09-22 and 0 from 2026-09-23). So the "~4.2c/address" figure and the
60-a-month break-even below describe the OLD price. At $0.0034, 100 addresses cost
≈ $0.34 against $2.54 net at $2.99. ⚠️ **The price moves without notice.** It has
changed once already, and at the old $0.051 a full 100-address month costs ≈ $5.10,
more than even $4.99 nets ($4.24). Re-read the real cost before judging the caps:
```sql
select date_trunc('day',created_at)::date d, count(*) filter (where actual_cost_cents=0) sub_cent,
       count(*) filter (where actual_cost_cents>=5) five_plus
from email_orders where created_at > now()-interval '14 days' group by 1 order by 1;
```
⚠️ **`email_orders.actual_cost_cents` is an INTEGER, so a sub-cent price records as 0.**
Every cost and profit figure built on it (`/profit`, `ops_snapshot`) shows mail as
free from 2026-09-23. That is a rounding artefact, not a zero cost. Fixing it needs a
fractional column, a backend change that has not been made.

Owner decisions of 2026-09-24, pending a release that updates the wording:
- **remove the free lifetime address** (`email_free_lifetime_grants` 1 → 0)
- **mail.monthly $2.99 → $4.99 for NEW subscribers only** (current subscribers keep $2.99,
  so Apple sends no price-increase consent requests)
- **mail.yearly → $39.99**

Do all three together with the release, because shipped builds say "your 1 free address".

🔴 **There are TWO caps since 2026-09-21: a DAILY one (8) and a ROLLING
30-DAY one (60, `app_config.email_sub_monthly_cap`, migration
`20260921100000`).** Both are read from `app_config` inside
`begin_email_order`, so either moves with no deploy and no release. The
monthly one refuses with `monthly_cap_reached` (429) and its copy must never
say "resets at midnight" — it clears an address at a time as old orders age
out, not all at once.

🔴 **BOTH caps count DELIVERED addresses only, since 2026-09-21** (migration
`20260921130000`, owner decision). The predicate is
`(code is not null or status = 'waiting')`, not the `status <> 'failed'` it
replaced — `failed` means only "never reached the provider", so an order that
DID get a mailbox and then never received a code was `expired` and **ate a
slot**. A paying `mail.monthly` subscriber who had ordered 8 a day for three
days straight wrote in on 2026-09-21: he is sold 8 addresses a day and was
receiving 8 *attempts*. Verified in a rolled-back transaction against live
Postgres: his day counted 8 under the old rule and 7 under the new one, and
`begin_email_order` still answers `daily_cap_reached` once all 8 genuinely
deliver.

- 🔴 **`status = 'waiting'` is LOAD-BEARING in that predicate — never drop it
  as redundant.** In-flight orders must count, or a caller fires fifty
  concurrent activations that each read the cap as zero-consumed. Counting
  them is what holds concurrency at the cap and keeps the residual below
  bounded.
- ⚠️ **The residual, accepted knowingly by the owner:** someone who lets every
  address expire now draws on the shared free outlook/hotmail pool with no
  daily or monthly ceiling. That pool genuinely runs dry (one sweep measured
  TWO addresses for discord.com). The bound is concurrency × window — at most
  `email_sub_daily_cap` in flight against a ~22-minute window, so ~500/day
  worst case for one account — and it yields the abuser nothing, since an
  expired mailbox carries no code. **If the pool starts running dry the lever
  is a separate ATTEMPT ceiling; do not quietly re-add failures to these
  counts.**
- ⚠️ **The non-subscriber LIFETIME grant is deliberately unchanged.**
  Exempting failures there would be inert and misleading: `v_used` is
  `greatest(v_free_ever, v_tombstoned, v_dev_used)` and both tombstones
  increment on every ATTEMPT, so the tombstone would still say 1. Making them
  conditional on delivery means writing them only after a code arrives, which
  reopens the exact farm vector they close (one mailbox key farmed 75 times
  from two phones). A first-time user whose single free address fails still
  gets nothing — a separate owner decision with real farm risk attached.

**Why the daily cap alone is the wrong SHAPE, not merely the wrong size.** It
does not bound a month at all: at 8/day it permits 240 addresses, while a
$2.99 subscriber nets $2.54 and blended wholesale is ~4.2c/address, so
break-even is **~60 a month — under 2/day against a cap of 8**. And it bites
the wrong user: legitimate use is BURSTY (someone registering a few accounts
in one sitting) while farming is SUSTAINED, so a per-day limit throttles the
burst and never touches the farm. 60 is chosen so the worst case is
break-even (60 × 4.2c = $2.52 against $2.54) and it clears every legitimate
month ever observed — the heaviest non-farm month was 36.
🔴 **The evidence that the daily cut did not work: tiktok.com ran 76.9% of
mail volume when the cap went 25 → 8 on 2026-09-16, and 205 of 237 orders
(86.5%) from 13 accounts in the 7 days to 2026-09-21** — single accounts at
53, 43, 33 and 30. Verified behaviourally in a rolled-back transaction: 59
allowed, 60 refused, and rolling one order past 30 days re-opened it, with
never more than 3 on any one day so the daily cap could not be what fired.
⚠️ `email_sub_monthly_cap` is deliberately NOT in the `app_config` RLS
whitelist — no client reads it, and the refusal already carries `cap`.

🔴 **The daily cap is 8, cut from 25 on 2026-09-16, and the number is MEASURED.**
Re-read it (`select value from app_config where key='email_sub_daily_cap'`),
never quote this. Over the product's whole history **373 of 376 user-days are
≤5 orders**; only three days ever exceeded five, and those ran 92–100%
`tiktok.com`. So 8 clears every legitimate day observed with 60% headroom and
cuts only the farm. It is enforced in SQL from `app_config`, so the write takes
effect with no deploy and no release.

🔴 **WHY, 2026-09-16 — the temp-mail line was being used to farm TikTok
accounts.** Four accounts created within 8.5 hours on 2026-09-15, each
subscribing **14–73 minutes after signup**, placing **37 of 37 orders against
`tiktok.com`** and **zero** SMS orders between them. TikTok's share of all mail
orders went 3.6% → 22.4% → **76.9%** across three weeks while distinct sites
collapsed 17 → 6 and orders-per-user rose 1.4 → 2.9. ⚠️ **They are not bots**
— gaps are irregular and human (79s to 8.5h), four separate devices, no shared
push tokens, all Production Apple IDs. Read it as a coordinated playbook, not a
script, and do not go looking for an API abuser.
⚠️ **The direct cost was trivial — $1.85 of wholesale against two paid monthly
subs** — so this is NOT a money leak. What it actually costs is the shared free
outlook/hotmail pool (which genuinely runs dry: one sweep measured TWO addresses
available for discord.com), and it quietly falsifies "e-mail acquires users":
this cohort placed no SMS orders, will never rate the app and will never buy a
line. **Judge the mail line on what its users do NEXT, never on order volume.**

🔴 **Four mail-subscription state bugs fixed 2026-09-16 — read these before
trusting any mail `state` from before that date:**

- **`GRACE_PERIOD_EXPIRED` was unhandled on the mail path.** It fell into
  `default`, which returns before any write, so a lapsed subscriber stayed
  `grace` forever. It now maps to `billing_retry` (grace ending does not end
  Apple's retries; `EXPIRED` follows separately). Three stranded rows were
  corrected by hand (`230003619439163`, `200003561300725`, `390002488584011`
  → `billing_retry`); none was date-entitled, so nobody lost access.
- **Mail notifications could not be joined to their subscription.** The
  `line_notifications.original_transaction_id` stamp ran below the family
  dispatch, so every mail event — and every credit-pack refund notification —
  was logged with a NULL id. It now runs straight after the inner JWS is
  verified, for every product. Rows before 2026-09-16 stay NULL.
- **A client re-post could resurrect a lapsed row, move expiry BACKWARDS, and
  reset auto-renew** (migration `20260916190000`). `record_email_subscription`'s
  ON CONFLICT branch is reached almost only by the app re-posting a receipt it
  still holds, with `active`/`auto_renew=true` hard-coded. The expiry half was
  the serious one: an original-purchase JWS re-posted after a renewal could
  lower `expires_at` and deny a PAYING subscriber. Now a lapsed row keeps its
  state against a receipt whose period has ended, `expires_at` only moves
  forward (`greatest`), and `auto_renew` on conflict keeps what Apple last
  said. Returns `ok: true` + `state_kept` — deliberately no new refusal, so no
  client change. Verified in a rolled-back transaction against live Postgres:
  stale receipt kept `billing_retry`; renewed receipt → `active`; old receipt
  after renewal left expiry in the future; `revoked` still refused.
- **The refund-request page said "Respond in App Store Connect".** Apple
  documents the response only as the App Store Server API, and only with the
  customer's PRIOR consent (`customerConsented: true`, else 400) — which vSMS
  does not collect. The alert now says no reply is sent and Apple decides.

`verify-email-subscription` deliberately **accepts Sandbox**, unlike
`iap-verify`. There is no equivalent exposure: the entitlement grants addresses
on domains that cost nothing and is still bounded by the daily cap. Refusing
Sandbox would mean the App Store reviewer subscribes, gets nothing, and rejects
the build.

**Subscribers see a usage meter** under the Temp tab's e-mail CTA ("X of Y
today · X of Y in 30 days", plus when a full limit frees: the daily one
relative to UTC midnight, the 30-day one as a date from `monthly_next_slot_at`,
never "midnight"). It comes from `email_usage(p_user)` via `email-domains`'
`usage` key (omitted on a failed read — the meter must never fail the domain
list), which counts with the same `email_included_used` helper
`begin_email_order` refuses on, so the meter and the refusal cannot disagree.
Both honour `profiles.email_cap_reset_at` (service-role only): the owner clears
ONE subscriber's usage with `update profiles set email_cap_reset_at = now()
where user_id = '…';` — orders and refunds are untouched. ⚠️ Build-verified
only, never walked on a device.

**Both caps are DISCLOSED live wherever the plan is sold** (2026-09-23):
`MailPaywallScreen`'s headline ("Up to N addresses a day and M every 30
days"), and `EmailCodeScreen`'s plan card and subscriber line, read
`dailyCap`/`monthlyCap` from `state.emailUsage` — `email_usage` returns the
caps to NON-subscribers too, so the pitch can quote them. Never a literal.
With no `usage` (a failed read, or the domain list not yet fetched) they fall
back to the daily figure from `app_config.email_sub_daily_cap`, then to no
figure. 🔴 Only the DAILY limit is ever described as resetting at midnight
UTC; the 30-day one "counts back from today". ⚠️ Build-verified only.

⚠️ **A subscriber's addresses still depend on free-domain stock that runs dry,
and the 1-credit fallback does NOT help there** — it buys from the same
outlook/hotmail inventory. A dry domain refuses `email_out_of_stock` for
everyone, paying or not.

### The 1-credit fallback (owner decision 2026-09-22)

Whenever `create-email-order` refuses an INCLUDED address with one of the four
"not covered" codes — `subscription_required` (free address spent, no
subscription), `daily_cap_reached` / `monthly_cap_reached` (subscriber over a
cap), or `free_limit_reached` (the per-IP free cap; the function returns that
code for both `free_limit_reached` and `ip_limit_reached`) — the refusal body
carries **`credit_price`**, status codes unchanged. The client offers that one
address for those credits; accepting re-sends the SAME order with
**`pay_credits: true`**.

- **`EMAIL_PAID_CREDITS` lives ONCE, in `_shared/emailPricing.ts`**, read by
  `create-email-order` (charges it, quotes it on the four refusals) and
  `email-domains` (quotes it up front as `credit_price`, because the Temp tab
  sells the plan BEFORE any order is refused and would otherwise never learn
  the price). The client renders only the number it is sent — never a literal.
  Change the constant → redeploy BOTH functions (`_shared` bundles per function).
- **Only the literal `pay_credits === true` opts in.** Without it the request is
  byte-for-byte the old one, so every build before this change behaves exactly
  as before (it also ignores the extra `credit_price` field).
- **`begin_email_order` with `p_credits > 0` skips EVERY free / subscription /
  cap check** (they all sit inside `if p_credits = 0`), inserts and charges via
  `wallet_spend` in one transaction, and answers `insufficient` → 402
  `insufficient_credits` when the balance is short. The margin ceiling for a
  paid address is the credit formula at 1 credit (~$0.167), not the free tier's
  $1.00 glitch guard, so a quote above it refuses `margin_too_low`.
- **Paid addresses never consume the included allowance** — both subscriber
  caps and the free-lifetime/`hasUsedFreeEmail` predicates count
  `cost_credits = 0` only.
- **Refund on no code is the existing path**: `close_email_order_claim` (via
  `failEmail` on a provider buy/persist failure, and from `check-email-order`) and
  `expire_email_orders` refund `cost_credits` when `code is null`, atomically
  and idempotently (partial unique refund index).
- **Client UI:** `subscription_required` keeps the Mail paywall as the primary
  CTA and gains a secondary "Get this one for N cr" (`MailPaywallScreen
  .paidOffer`, passed only by the refused-order sheet and the Temp tab's CTA —
  not by the domain sheet or the code screen). The three caps raise a system
  confirmation dialog in `ContentView` titled with `APIError.userMessage` for
  that code (the monthly copy never says "midnight"). A paid retry refused 402
  declares `intent = .email` + `AppState.emailCreditsNeeded` and opens
  `CreditsSheet`; the user retries by hand after buying. Events
  `email_paid_offer_shown` / `email_paid_offer_taken` (`reason` = refusal code,
  `source`), and `email_order_submitted` gained `paid`.
- ⚠️ **Build- and `deno check`-verified only — never walked on a device, never
  exercised against the deployed functions.** Ships only when BOTH functions are
  deployed and a client build carries it.

## The rented line — invariants that stay loaded

Full detail (calling, inbound routing, swaps, the country catalog,
international rates) is in `.claude/rules/telephony.md`. These four properties
differ from every other product line and must be in context even with no line
file open.

**1. It NEVER touches the credit wallet.** Hard-stop billing means no
per-message charge and no refund path — so no `wallet_*` calls, no ledger FK,
and no new `wallet_reason`. That deletes the surface this repo has got wrong
more than any other. **Keep it that way.** If overage credits are ever added
they need a ledger FK plus a partial unique index on `reason='refund'`.
(The credits-billed line is a separate, owner-only path with its own three cron
jobs; the Apple path is the product.)

**2. ONE live line per user**, enforced by a partial unique index, not by
convention. **The subscription IS the line.** More lines later means TIERS
inside the same group, never a second group.

**3. `line_subscriptions` has NO foreign key to `auth.users`.** Same class as
the credit-grant tombstones but worse: without it, delete-account → re-signin
re-provisions a **second** Telnyx number while the first bills us forever with
no row pointing at it.

**4. Clients read the `my_line` VIEW, never `phone_lines`.** RLS is row-level
and cannot restrict columns, and the table holds `monthly_cost_cents` plus every
Telnyx id. ⚠️ The view is deliberately **not** `security_invoker` — that would
need the caller to hold SELECT on the base table, which is exactly what was
revoked. Its `where user_id = (select auth.uid())` IS the security boundary.
**Do not "fix" it.**

🔴 **`ON CONFLICT` CANNOT USE A PARTIAL UNIQUE INDEX unless the clause repeats
the index predicate.** Both idempotency guards raised `42P10` until `where
provider_message_id is not null` was added. The indexes existed; they were
simply not reachable from the code depending on them, and every inbound webhook
would have 500'd. **A structural check cannot catch this** — only a behavioural
test found it.

🔴 **`verify-line-subscription` is called TWICE per purchase, and a
same-transaction `line_exists` is a REPLAY that answers 200 (2026-09-16).**
`SubscriptionStore` verifies one transaction from both the `product.purchase()`
result and the shared `Transaction.updates` listener, so the second call
routinely finds the line the first just created. `begin_line_rental` answers
`line_exists` without asking which transaction bought the line, and the
function used to return 409 `line_paid_but_exists` — which the app renders as
*"we couldn't set the number up"* for a purchase that SUCCEEDED. On 2026-09-16
alone two buyers hit it; one (`37cd2b0b`) reached the 409 100 minutes after
his number went live, never used it, turned auto-renew off and asked Apple for
a refund. It now returns `{ok, line_id, e164, replay: true}` when the existing
line's `original_transaction_id` matches AND its status is usable
(`provisioning`/`active`/`grace`/`past_due`), logging `line_verify_replay`.
**A line bought by a DIFFERENT transaction still 409s and still pages** — that
is the genuine paid-twice case the guard exists for. Server-side on purpose, so
every shipped build is fixed without a release. ✅ Seen live: `line_verify_replay`
for `e04f5e5c` on 2026-09-20 18:37:05Z, 200, no `line_paid_but_exists` beside it.

🔴 **The server fix was NOT the whole bug — a paying buyer can still be told
"failed" when the verify RESPONSE never arrives (read 2026-09-23 from edge
logs + `app_events.client_ts`).** 6 of 26 new Production line subscriptions in
the 14 days to 09-23 logged `line_purchase_result = failed` and never
`success`, and all 6 lines went live within ~15s. Four (09-10 → 09-15) are the
409 race above. The other two are transport failures on a request the server
completed anyway: `e04f5e5c` (09-20, after the fix) — the provisioning call's
execution created and activated the line but the gateway logged NO response
for it, and the client wrote `failed` ~6s in; `37cd2b0b` — his `failed` carries
a client clock of 06:39:45, 100 min after the charge and BEFORE the 06:41 409,
so the app was suspended mid-verify (the 409 was a later retry, not what he
saw first). **Client fix (2.18+, unshipped, build-verified only):**
`SubscriptionStore.purchase` re-reads `my_line` (3 reads, 2s apart) whenever a
StoreKit-VERIFIED `.success` comes back not-accepted; a line carrying the
exact digits just reserved in `provisioning`/`active`/`grace`/`past_due` turns
it into a success, logged `line_purchase_result{outcome: success, recovered:
true, failure_code?}`. It changes only what is SHOWN — no `finish()`, no money
— and a line with other digits still fails (the genuine paid-twice case).
Read `recovered = true` as "verify failed, number fine"; a rise there is a
transport/timeout problem to chase, not a win.

**Every Swift enum mirroring a PG enum needs an `unknown` fallback in
`init(from:)`, in the first client commit.** iOS `OrderStatus` has no unknown
case, which is why `begin_order` had to write a semantically wrong `'waiting'`.

### The lapse machine

There is **NO HOLD** (owner decision 2026-09-05): a lapsed line goes `suspended`
AND `releasing` in the SAME `reclaim_lapsed_lines` run, and `release-lines`
deletes it at Telnyx within ~30 min. Every lapsed subscriber in the product's
history had auto-renew OFF at expiry, so the 7-day "fix your card" window
protected a recovery that never once happened.

✅ **Subscribers with auto-renew OFF are warned before the number is deleted
(2026-09-10).** `winback` cohort 4 pushes `line_expiry` 3 days and 1 day
before `expires_at` for `state='active', auto_renew=false` lines
(`line_expiry_nudge_candidates()`, daily at 15:00 UTC, so the 3d push lands
3–4 days out and the 1d push 12–36 h out). Dedupe is
`line_subscriptions.expiry_nudged_{3d,1d}_for` = the `expires_at` it was sent
FOR, so a renewal re-arms both without a flag reset. Why it exists: 6 of the 8
active monthly lines had auto-renew off while averaging 27 calls in 8 days,
and the only line push in the product was the post-renewal "your new number".
The copy says where to turn auto-renew back on and that the number cannot be
recovered; it never states a time, because we do not know the user's zone.

🔴 **`reclaim_lapsed_lines()` sweeps `active`, `grace` AND `past_due`.** It swept
only `active` until 2026-08-30 and the other two leaked $1/month per number
forever — the ONLY exit from them was an Apple `EXPIRED` notification, and **the
invoice was the only place a missed one would ever show up.** `past_due` is the
half that matters going forward: app-level grace was disabled 2026-08-28, so
every future failed renewal lands there.

✅ **A renewal that lands on a released line buys the subscriber a new number**
(`line_reprovision_target` + `reprovisionAfterRenewal`), and a paid subscriber
with no number at all is rescued on a timer by `rescue-unprovisioned-lines`.
🔴 **Idempotence is the ROW, not a flag, and deliberately not keyed on the
notification uuid** — Apple delivers up to five times, `begin_line_rental` is the
mutex, and a `failed` attempt sits OUTSIDE the partial index so a retry can still
succeed. A uuid tombstone would have locked out the recovery this exists for.

🔴 **"Renewal landed on a released line" pages ONLY from
`reprovisionAfterRenewal`, i.e. only on `DID_RENEW`. Never page for a missing
line on the SUBSCRIBED path** (fixed 2026-09-20). A second copy of that alert
used to sit on the `else` of the `DID_RENEW` branch, which made it reachable
only for `INITIAL_BUY` / `RESUBSCRIBE` — the one path where the CLIENT creates
the line, while the user is picking their number. Apple's webhook routinely
beats `verify-line-subscription` by a few seconds, so the handler looked for a
line that did not exist YET and paged that the subscriber "has paid and holds
no line" when they did. On tx `300003376054774` the notification landed
18:36:54, the number 18:36:57, the page 18:36:57. It fired 12+ times between
09-11 and 09-20 and was wrong every time, because the renewal it described can
never reach that branch. It is now a `subscribed_no_line_yet` log line.
⚠️ **Nothing was lost by removing it**: a purchase that genuinely never
provisions is caught by `rescue-unprovisioned-lines` (cron, 4×/hour, 30-minute
minimum age) and by the watchdog's `line-paid-no-number` check. **Both WAIT,
which is the property a webhook cannot have — that is the general rule: never
alert on the absence of a row another in-flight request is about to write.**

🔴 **A Telnyx number costs $2.00 AT THE MOMENT OF ORDER — the $1.00 upfront
fee and the first month TOGETHER.** Measured 2026-09-11 from Telnyx's own
refusal, not inferred: `app_config.telnyx_test_number_probe` holds
*"Insufficient Funds … Credit available: 0.51 Total cost of Order: 2.0"* for a
single US local number. Re-read it rather than quoting this.

⚠️ **This REPLACES the previous claim that "Telnyx bills number rent on the 1st
of the month".** That was explicitly marked *inferred from a balance step, not
read from their ledger*, and it was wrong — a balance step on the 1st is not
evidence that rent is the thing stepping. Two decisions were reasoned from it
and both came out wrong: that a number sitting unassigned for a day "costs
nothing", and that recycling a number could only ever recover $1. **The month
is prepaid at order, so an unassigned number is money already spent.**
⚠️ The RENEWAL date is still not measured — the anniversary is the assumption,
and it is only an assumption. Do not build anything that must be right about
it without reading Telnyx's ledger first.

🔴 **Owner rule (2026-09-11): never pay rent on a number no subscriber is
assigned to** — *"I'll only pay the next month $1 if that user is still
subscribed."* Two mechanisms enforce it, and both have to stay:
- **`reclaim_lapsed_lines` branch (d) gives `auto_renew = false` NO 6-hour
  lag** (migration `20260911090000`). The 6h exists so a late `DID_RENEW`
  cannot kill a paying subscriber's number; when Apple has already said the
  subscription will not renew there is no such notification coming, and those
  six hours straddle exactly when the number's own renewal falls due. On
  2026-09-11 that was 6 of 11 active Apple lines. Branches (d2) `grace` and
  (d3) `past_due` KEEP the 6h deliberately — both mean Apple is still trying
  to bill. ⚠️ **Never release EARLIER than `current_period_end`**: the
  subscriber paid through that instant.
- **`ORPHAN_MIN_AGE_MS` is 1 HOUR**, not the 24 it was. See the orphan sweep
  below.

### 🔴 Delete Account RELEASES the user's number at Telnyx, irreversibly

`delete-account` calls `releaseNumber()` INLINE for every `phone_lines` row
whose status is not `released`, before deleting the auth user — deliberately,
because the row holds the only pointers to the Telnyx resources and cascades
away a moment later. A released DID goes straight back to Telnyx's pool and
**cannot be bought back**, so testing the signup flow on an account that owns
a number you care about destroys that number.

The user is told so before the tap (2026-09-23, Apple's account-deletion
guidance): `AccountScreen`'s danger zone and its confirmation dialog add
"Your number will be released and can't be recovered." for a live line, and
"Your subscription keeps billing through Apple until you cancel it." plus a
Manage subscriptions button for a paid line or `mailStore.isEntitled` —
deleting the account cancels no Apple subscription. Nothing extra for anyone
holding neither. ⚠️ Build-verified only.

🔴 **The owner's own line `+14375243093` is hardcoded as the support WhatsApp
contact in every build from 2.9 to 2.17.** WhatsApp banned that support account
on 2026-09-23 and support moved to a server-controlled link (see "Support is a
server-controlled chat link"), so it is no longer the support channel — but it
is still the owner's own line, and a released DID would repoint those old
builds' Support button at a number someone else may then buy. Treat any
delete-account test on the owner's account as a number-losing operation until
the line is protected.

**The safe procedure (walked 2026-09-13, number verified still held after):**

1. Snapshot the `phone_lines` row — the Telnyx number / connection / messaging
   profile / voice profile / credential ids are unrecoverable once it cascades.
2. `app_config.line_orphan_release_enabled` → `false`. Without this the sweep
   below hands the number back within 15 minutes of the row cascading away.
3. Set the line `status = 'released'` — the ONE status `delete-account`'s loop
   skips, so `releaseNumber` never fires and the DID stays ours.
4. Delete, test, re-sign-up.
5. Re-INSERT the `phone_lines` row against the NEW uuid with the snapshotted
   ids, restore the wallet with `wallet_credit(user, n, 'adjustment', null,
   null)`, and set the flag back to `true`.
6. **Verify at the provider, not in our table**:
   `probe-telnyx-connection {"probe":"numbers"}` must report the e164 with
   verdict `held_by_active_line`. Our own row saying `active` proves nothing
   about whether Telnyx still has the number.

⚠️ Everything else about the account is cheap to restore and needs no
ceremony: credits are one `wallet_credit` call, and the grant tombstones
(`signup_grants`, `email_free_grants`, `free_email_device_grants`) survive the
cascade BY DESIGN, so a re-signup correctly mints nothing. `wallet_transactions
.line_id` is SET NULL so the ledger survives; `line_calls`, `line_messages`,
`line_threads`, `line_rent_charges` and `line_number_swaps` all CASCADE and are
gone for good.

### 🔴 The orphan sweep releases any number no live line holds

By **e164, not by reference**. The old guard — judge only numbers whose
`customer_reference` is a line-id UUID — let two probe numbers bill for a month
with `orphans: 0` in the heartbeat every 15 minutes, discovered only when the
Telnyx dashboard read 13 active numbers against 6 paying lines. Reconcile any
time with `probe-telnyx-connection {"probe":"numbers"}` (read-only). **Run it
whenever the dashboard count and the paying-line count disagree — the heartbeat
cannot tell you.**

🔴 **`ORPHAN_MIN_AGE_MS` is 1 HOUR (2026-09-11), down from 24.** The 24 rested
on "rent is monthly, so waiting a day costs nothing" — false once the month is
known to be prepaid at order. One hour is still 4× the widest in-flight window
that exists: `reclaim_lapsed_lines` fails a stuck `provisioning` row at 15
minutes and the edge runtime dies at ~150s, so no order can legitimately be
unwritten for longer. **Watch `young_unmatched` in `line_release_heartbeat`** —
it should normally read 0, and a persistent non-zero means an order path is
leaving numbers unwritten, NOT that this bound is too low.

⚠️ **A swap that times out deliberately does not release its number** — the
order "may still land after we stop looking", so `swap-line-number` refunds and
leaves it to this sweep. That is the path that produced the unassigned
`+16042390805` on 2026-09-11. It is the orphan sweep's job by design, which is
why the sweep's latency is the thing that had to change.

## Ops, monitoring and analytics

### The watchdog is plain SQL — keep it that way

`run_watchdog()` (pg_cron `*/10`) checks job freshness and **three or more**
non-2xx rows in 25 minutes (`relay-http`, threshold raised from one on
2026-09-13 because the top-of-minute PostgREST herd below made a single stray
500 flap the check several times an hour, each flip a page plus an all-clear;
a real outage fails every minutely relay, three per minute, and still trips it
inside a minute) in
`net._http_response`, and writes its verdict to `app_config.watchdog`. It
deliberately uses **no edge function, no CRON_SECRET, no HTTP**, so it still
evaluates when the whole edge/secret layer is broken. If you add a scheduled
job, give it a freshness signal and a check here.

🔴 **Check the STATE, not just the heartbeat.** `sync-telnyx-cdr` ran green for
twenty days while matching zero records, because only its heartbeat was tested.
`line-country-sellable-stale` and `line-paid-no-number` exist for the same
reason. **A freshness gate and the job that keeps it fresh must reference the
same number** — a 48h gate re-probed weekly took the line store dark in every
country for ~5 of its first 9 days, and nothing paged.

⚠️ **The watchdog's "last ran" is `value->>'checked_at'`, NEVER the row's
`updated_at`** — `telegram-notify` writes back to the same row on every page, so
a dead watchdog plus one re-page reads as "ran just now". A verdict older than
30 minutes is `watchdog_stale`.

🔴 **A one-line refactor that changes a watchdog threshold is a monitoring
outage.** Rebuilding `run_watchdog` for unrelated coverage once silently
narrowed the delivery check and **deleted its second branch**, making it
effectively unreachable — zero delivery-outcome coverage. When you re-create a
function from `pg_get_functiondef`, **diff it clause by clause**; the dump is
also truncated by most tooling, which is how a nonexistent column got invented
in the same rewrite.

🔴 **A GUARD READING A CONFIG KEY NOBODY WRITES FAILS OPEN AND SILENT.** A
migration retired SMSPVA and unscheduled its jobs but never inserted the
`smspva_retired` key its own guards read, so two checks kept measuring cursors
that could never move — pinning the watchdog red for three days, burying a
genuine float page, and structurally suppressing a winback cohort. **When you
retire a subsystem, write its flag in the SAME migration that unschedules its
jobs, and after writing any guard that reads a key, `select` the key.**

### Nudges (`winback`, daily 15:00 UTC)

Four cohorts, each with its own candidate function and dedupe column;
`winback/index.ts` is the only sender. Re-derive sends from the function's
own JSON response (`select content from net._http_response where …`) or the
`*_sent_at` / `*_nudged_*_for` columns — never from `wallet_transactions`,
which records only the retired `winback_bonus` grant.

| cohort | candidates | dedupe | gate |
|---|---|---|---|
| never-ordered | `winback_candidates()` | `profiles.winback_sent_at`, ≤3 sends 14d apart | none |
| stranded (last order failed, balance > 0) | `stranded_credit_candidates()` | `profiles.stranded_nudge_sent_at`, once | **primary provider float ≥ $7.50 + no failing watchdog check other than `*-float` + fresh verdict** |
| reorder (a code came through 3–90 days ago) | `reorder_candidates()` | `profiles.reorder_nudge_sent_at`, ≤3 | none |
| line expiry (auto-renew off, ≤ 4 days) | `line_expiry_nudge_candidates()` | `line_subscriptions.expiry_nudged_{3d,1d}_for` | none |

🔴 **The stranded gate must never again require `failing` to be EMPTY, and
must read the PRIMARY provider's `<provider>_health`.** Both were wrong on
2026-09-10 and had been for a month: `5sim-float` is a runway WARNING, not an
outage, yet it silenced every send from 2026-08-09; and the key read was
`herosms_health`, the provider that was primary when the line was written —
the same drift that once pointed it at SMSPVA. A `*-float` check is ignored
because the balance is gated directly; `telnyx-float` is not even this
product. First run after the fix: 100 stranded + 30 reorder sends. **After
any provider switch, re-point this read (checklist step 6).**

The stranded cohort is NOT "buyers only" — it is anyone with a balance whose
last order failed, so ~95% of it holds the free grant. The copy is honest for
both ("N credits in your wallet; a number that fails is refunded").

### Telegram ops bot

Detail is in `.claude/rules/ops-bot.md`. What matters from outside it:

- **Commands are a REGISTRY** (`_shared/tgCommands.ts`), not an if/else. Adding
  one = one registry entry + one handler, **then RE-RUN `telegram-setup`** or
  the `/` popup menu keeps the old list (it is bot-level state held on
  Telegram's side, like the webhook URL).
- **`telegram-webhook` MUST be deployed `--no-verify-jwt`.** Without it every
  update 401s and the bot dies silently. Assert with an unauthenticated POST: it
  must return **200**, never 401.
- **Exactly-once is a claim row in `telegram_events` written *before* sending.**
- **Every timestamp the bot prints is Europe/Paris.** Never format a time any
  other way in bot code.
- **`/revenue` and `/profit` do NOT use a hardcoded price table and must not be
  "simplified" into one.** The store charges by storefront — `credits.12` bills
  $4.99 in the USA but €5.99 in France — so a USD ladder would overstate US
  revenue ~17%. The signed `price`/`currency`/`storefront` are decoded from the
  JWS we already persist. Mixed currencies are never silently totalled.
- ✅ **`/revenue` and `/profit` count BOTH subscription families** (fixed
  2026-09-11). Line money was already in the headline via
  `lines_money_snapshot`; **mail money was in there too, mislabelled as line
  money** — `line_notifications` is a misnomer that holds EVERY product, and the
  snapshot filtered on none, so mail.monthly/mail.yearly payments were rendered
  under "Second numbers" while `active`/`renewing`/`mrr` read
  `line_subscriptions` and were line-only. The two halves described different
  populations. Top-level keys are line-only now; mail has its own object and its
  own 📧 block, and `allSubsCurrencies`/`allSubsPayments` are the ONLY way the
  headline and the digest may read across both.
  🔴 **MRR is `mrr_by_currency`, an ARRAY, and there is deliberately no scalar.**
  The old `mrr_milli` summed across currencies and `mrr_currency` was an
  unordered `limit 1`; the formatter then converted the whole sum at that one
  label's rate, which rendered ₦4,900 + $5.98 as "$4,903/mo". Convert each
  currency at its own rate, and never re-add a single-number MRR field.

### RevenueCat is a MIRROR, never an authority (2026-09-11)

`rc-sync` posts every Production Apple purchase to RevenueCat's
`POST /v1/receipts` so the owner can read the business from RevenueCat's phone
app. Cron `relay-rc-sync`, **every minute** (owner, 2026-09-11: "1 minute max").

⚠️ **It shipped at every 10 minutes and that was the wrong reasoning, not a
wrong number.** "~2 purchases a day, so latency is irrelevant" reasoned about
the PURCHASE rate and ignored the READ rate — the owner opens the phone app to
look. A purchase at 19:37:55 against a sweep at 19:36:00 was then invisible for
eight more minutes and read as "RevenueCat registers purchases late". **On a
glance surface, late and wrong are the same complaint.** Every minute is
affordable because an idle sweep is three tiny indexed reads and no write, and
`relay-poll-active-orders` has run at that cadence since launch.

⚠️ **"An idle run takes ~266ms" was written here and it was one lucky sample.**
Over 299 successful runs on 2026-09-12 the idle wall time was **p50 1.3s, p90
5.3s, max 24.6s** — and ~18% of runs answered 500 `*_read_failed: Gateway
Timeout`. The queries take under 1ms (`explain analyze`); the time is spent
queuing behind the top-of-minute burst described in the herd gotcha. The
function now sleeps `HERD_SETTLE_MS` (5s) before its first read and retries
each read `READ_ATTEMPTS` (3) times, because a mirror can afford to start late
and the alternative was the watchdog's generic `relay-http` check reading red
for a dashboard. Re-derive from `net._http_response` (`content->>'elapsed_ms'`
on the 200s, `content->>'error'` on the 500s) rather than quoting either number.

🔴 **It grants no entitlement, gates no product and settles no money, and it
must stay that way.** `has_email_subscription`, `reclaim_lapsed_lines`,
`credit_iap_purchase`, `iap-verify` and `apple-notifications` are all untouched
by it and never read from it. A RevenueCat outage may cost exactly one thing: a
stale chart. **Never make a product decision depend on a row there** — the
entitlement truth is Postgres, and `reclaim_lapsed_lines` is deliberately pure
SQL so the claim survives the edge layer dying.

Six facts that reading the code does not give you:

- 🔴 **It is a SWEEP, deliberately, not a forward from the money paths.**
  RevenueCat requires the receipts call to land — *"if you don't have this
  endpoint hit for that user, that subscription will most likely not be
  tracked"* — so an inline POST would need its own retry inside the two
  functions this repo most needs to keep boring, and a discarded error there is
  exactly the shape of the four silent `wallet_credit` bugs already fixed.
  A sweep cannot lose a row: unsynced stays unsynced and is retried. **Do not
  "improve" this by moving it into `iap-verify`.**
- **Subscriptions track `rc_synced_txn`, not a boolean.** A renewal REWRITES
  `latest_signed_transaction`, so a "synced" flag would mirror month one and go
  silent forever. The sweep re-sends whenever `last_transaction_id` moves.
- 🔴 **"Which rows still need mirroring" is answered in SQL by the generated
  column `rc_pending`, NEVER by skipping rows inside the loop** (migration
  `20260920200000`). It held the predicate in TypeScript until 2026-09-20, and
  because the query took the 40 oldest rows by `updated_at` and discarded the
  synced ones afterwards, **the line mirror died the moment
  `line_subscriptions` passed 40 rows**: the batch filled with rows the loop
  threw away, and the pending ones — always the NEWEST, since a purchase and a
  renewal both set `updated_at = now()` — sat behind the wall. At 42 rows,
  ranks 41 and 42 were stranded with `rc_sync_attempts = 0`, never once
  attempted, and no later run could ever reach them. `email_subscriptions` had
  24 rows and kept working, which is exactly how it presented: RevenueCat
  showed `mail.monthly` and no `line.monthly`. The packs branch was never
  affected — it filters `rc_synced_at is null` in SQL, which is the shape the
  subscription branch now copies. ⚠️ **A batch limit plus an in-loop skip is a
  silent stall, not a slow drain** — if you add another swept table, filter in
  SQL. `IS DISTINCT FROM` is load-bearing in that column: `rc_synced_txn` is
  NULL on a never-synced row and `NULL <> 'x'` is NULL, so `<>` would drop
  precisely the rows that matter.
- **Sandbox is excluded everywhere.** Those receipts are genuinely Apple-signed
  and cost $0; mirroring them would invent revenue on the one surface built to
  be trusted at a glance. Same gate as `credit_iap_purchase`, different
  consequence.
- **Price and currency are NOT sent.** RevenueCat derives them per storefront
  from the JWS via the In-App Purchase key. Restating a price we own is the
  mistake this repo has made in three other places.
- ⚠️ **RevenueCat's MRR excludes consumables, and packs are ~3/4 of the
  revenue.** On 2026-09-11: 46 pack purchases in 30 days (≈$275 gross) against
  MRR of USD 66.88 + INR 399 + NGN 4,900. The Revenue chart counts one-time
  purchases; the MRR/churn/cohort views do not. **The glanceable number is
  Revenue, not MRR** — reading MRR as "how am I doing" understates the business
  ~4×.
- 🔴 **"Active Users" reads 0 and ALWAYS WILL — that is not a sync failure, and
  there is no server-side fix.** RevenueCat defines it as App User IDs that
  "communicated with RevenueCat in the past 28 days", and it is fed by devices;
  we ship no RevenueCat SDK, so no app open, session or `getCustomerInfo` call
  ever reaches them. The same is true of **Installs** and of every retention /
  cohort view. Checked on 2026-09-13 with the mirror provably healthy: 96/96
  pack receipts and 28/28 production subscriptions synced, 0 `rc_sync_error`
  rows, **77 distinct App User IDs posted within the 28-day window** — and the
  card still read 0 while Active Subscriptions read **21**, Revenue €326 and
  MRR €88 on the same screen. ⚠️ The 0-against-77 gap is the evidence; Revenue-
  Cat's docs never state outright whether a server-side `/v1/receipts` POST
  counts as "communicating", so treat the mechanism as INFERRED. **Do not add
  the SDK to light this up** — it would put RevenueCat inside the app for the
  first time, against the read-only-mirror rule above, to fix a chart
  `app_events` already answers better.
- ✅ **Active Subscriptions IS trustworthy, and it spans BOTH families.** On
  2026-09-13 RevenueCat's 21 matched our own tables exactly — 17 active
  `line_subscriptions` + 4 active `email_subscriptions`, Production, unexpired.
  `rc-sync` picks the table from `subscriptionFamily` (`index.ts`: `fam ===
  "line" ? "line_subscriptions" : "email_subscriptions"`), so a count that is
  short by a few is a MAIL sync problem, not a line one. Re-derive both halves
  before believing a discrepancy.
- **A second In-App Purchase key (`HK4WN3S8ZF`) was generated for RevenueCat**
  rather than sharing `BTPZRH3GW3`, which is wired into four Supabase secrets —
  so revoking RevenueCat later cannot break our own App Store Server API calls.
  Apple allows 10 active keys and both live in `~/.appstoreconnect/private_keys/`.

`REVENUECAT_API_KEY` is the **public** app key (`appl_…`), not a secret one:
`/v1/receipts` is a client-shaped endpoint and RevenueCat designs that key to
ship inside an IPA. It needs no rotation if it appears in a transcript — unlike
the HeroSMS and Telnyx keys. A secret `sk_…` key would only be needed to delete
customers or grant entitlements, neither of which this product does.

⚠️ **`00000000-0000-0000-0000-000000000000` is a throwaway subscriber** created
while probing the key on 2026-09-11. It holds no purchases and affects no chart.
Deleting it needs a secret key we deliberately do not hold.

🔴 **`relay-rc-sync` has NO watchdog check OF ITS OWN, and that is a deliberate exception
to "every scheduled job gets one".** The watchdog's only output is a Telegram
page, and the whole failure mode here is *a chart is stale* — a mirror falling
behind costs nothing and fixes itself on the next run. Paging for it would spend
the one channel that has to stay readable, which this file already records as
how the next real outage gets missed. Check it by hand with the query above when
the numbers look wrong; `rc_sync_error` holds RevenueCat's own words, and a row
stuck at `rc_sync_attempts = 10` is the thing to look for.

⚠️ **But the GENERIC `relay-http` check does see it** — it counts every
non-2xx cron relay response, whatever the job. On 2026-09-12 the sweep's
`Gateway Timeout` 500s tripped it for most of the day, and that check is one of
the ones the stranded-nudge gate reads ("no failing check other than
`*-float`"), so a cosmetic mirror was silencing a real winback cohort. A
`* * * * *` job that answers 500 on a transient is a watchdog outage by another
name: it must retry, then sleep past the burst, and only then fail loudly.

Re-derive the mirror's health rather than trusting this line:
```sql
select count(*) filter (where rc_synced_at is not null)||'/'||count(*) from iap_receipts
  where environment='Production' and granted_credits>0 and raw_jws is not null;
select count(*) from iap_receipts where rc_sync_error is not null;
```

### Behavioural analytics

`app_events` is written ONLY by the `record-events` edge function. **RLS is on
with NO client policies — a client that can insert directly can poison every
funnel read; keep it that way.** 90-day retention. Analytics only, never
accounting: money stays in the money tables. The client fires-and-forgets, and
the server never surfaces analytics failures to the app — measuring the product
must never degrade it.

**Line events on branch `design-overhaul` (2026-09-24):**
`line_choose_number_tapped` is RETIRED (the store lists three numbers inline;
no button). `line_numbers_shown` now fires whenever the store renders a fresh
inline search — every visit that searches — with `source: "store_inline"`; on
`main` it meant 'opened the picker', so the two series are NOT comparable.
`line_swap_open` gains `from` ∈ `home` · `number_segment`. Every other line
event keeps its name and props.

🔴 **THE APP PRIVACY LABEL IS WEB-UI ONLY and cannot be verified from here.**
Eight candidate ASC API paths all return 404. The owner reports Product
Interaction and Search History were added on 2026-09-08; **record that as a
report, never as a checked fact.** ⚠️ ASC keeps the labels as a DRAFT behind a
separate Publish, and an unpublished draft looks complete on the page while
taking effect nowhere.

### ASA attribution

`record-attribution` resolves Apple's `AAAttribution` token and writes one row
per user to `install_attributions`; read it with `attribution_summary()`, which
also returns `line_subs`/`line_paid` so a keyword can be judged on the
SUBSCRIPTION it bought.

- It runs **AFTER** `bootPhase = .ready`. A measurement may never lengthen the
  boot critical path.
- **Apple's 404 is AMBIGUOUS** — organic, or not resolvable yet. An UNREACHABLE
  Apple writes **no row**, so an absent row means "not measured", never
  "organic".
- **The table cascades from `auth.users` on purpose.** It is user data, not a
  grant tombstone — do not "fix" it to match `signup_grants`.

🔴 **ASA IS OFF. Owner decision 2026-09-15: *"asa is good but i dont want it
anymore"*** — acquisition effort moved to organic
(`docs/superpowers/specs/2026-09-15-organic-acquisition-design.md`). Separately
and for the second time, **all 14 campaigns in the org (vSMS and vRoam alike)
read `ENABLED` but `NOT_RUNNING`, reason `CREDIT_CARD_DECLINED`**, dark since
~2026-09-13. Lifetime vSMS result: **€58.73 for 36 installs, blended CPI
€1.63** against the owner's €1.00 bar, and **42 attributed installs against
1,032 organic in the product's whole history**. Do not restart it without the
owner.

🔴 **A dead ASA campaign is probably BILLING, and the API cannot tell you.**
Delivery once went to exactly zero for two days with `endTime`, budgets, bids
and serving state all reading healthy. Apple exposes **no billing endpoint**, so
the campaign layer keeps reading fine forever. Check ads.apple.com → Settings →
Billing. Plan, keyword scores and kill rules: `docs/asa-second-number-plan.md` (US, and
the 09-05→07 run the owner paused); **`docs/asa-eu-campaigns.md` (Europe,
2026-09-10)**.

🔴 **EU delivery is a MATCH-TYPE problem, not a relevance problem, and
`asa-second-number-plan.md` §9 says otherwise.** That section blames the
09-06 zero-impression result on the listing carrying no `usa` token — true of
the US cluster, false as a general explanation: six EU keywords whose tokens
WERE in the live keyword field also drew zero at a €1.30 bid, while a sibling
campaign with BROAD ad groups took **1,263 impressions to vSMS's 15 on the
same day in the same storefronts**. Re-confirmed inside one campaign on
09-10 — broad keywords 49–85 impressions, exact 1–5. **Never build an
all-EXACT campaign for a European storefront without a broad group beside it.**

🔴 **There is NO lifetime budget any more — Apple removed them June 2026** and
paused every campaign that used one. `budgetAmount` reads None on all 22
campaigns in the org. `dailyBudgetAmount` is the only cap, so exposure is
daily × days-until-a-human-pauses-it; nothing on the platform stops a campaign
on a date. `asa.py`'s `cmd_create_us` still sends `budgetAmount` and
`cmd_campaigns` still prints a `total` column — both inert.

`scripts/asa.py searchterms <campaign> [days]` is the ONLY way to see the
queries Apple actually matched. Two traps, both hit while writing it: `/api/v4`
answers **HTTP 410 INVALID_API_VERSION** (BASE is already v5), and sending
`granularity` alongside `returnRowTotals` is **HTTP 400**. EXACT keywords DO
return rows.

⚠️ **`APPSTORE_SEARCH_RESULTS` campaigns take NO ad objects.** An empty
`/adgroups/{id}/ads` is normal, not the reason for zero impressions. Diagnose
from `servingStateReasons`, bids and age.

### The Reddit radar surfaces leads; it NEVER posts (2026-09-15)

`reddit-scan` (cron `relay-reddit-scan`, hourly at :26) searches Reddit for
people asking for what vSMS sells, scores each thread through Moonshot/Kimi,
and pushes the good ones to Telegram with a **drafted reply the owner edits
and posts by hand from their own account**. `/leads [open|all|skipped]` is the
working list; the two inline buttons on each push (`lead:done` / `lead:skip`,
handled in `telegram-webhook`) only RECORD what the owner did.

🔴 **There is no posting path, and the credential could not post if there
were.** The Reddit token is minted `grant_type=client_credentials` — the
app-only grant, no user context — so submit/comment/vote endpoints 403. That
is the safety property: an absent capability, not a flag someone can flip.
**Never "upgrade" it to a password or refresh-token grant.** Undisclosed
automated promotion is a Reddit Rule 2 (inauthentic engagement) violation, it
is detected, and the sanction that matters is a sitewide **DOMAIN** ban —
which costs the legitimate channel permanently, not just an account. Owner
asked for a comment bot on 2026-09-15 and this is the shape that was built
instead; do not quietly re-open the question.

Five things reading the code does not give you:

- **Three product truths are pinned into the classifier prompt**
  (`_shared/kimi.ts`), because an overselling draft is worse than no draft —
  this app's only organic review is already someone angry about a promise that
  did not hold. Temp SMS delivers ~a quarter of the time per attempt and the
  draft must say so; outbound texting is NANP→NANP only and the draft must
  never imply otherwise; **no supplier is ever named** (the standing owner rule
  applies to drafted copy exactly as it does to shipped copy). The disclosure
  line is mandatory, and a subreddit read as `restricted` gets a draft with no
  product mention at all.
- 🔴 **`moonshot-v1-*` sunset 2026-08-31.** Live ids are `kimi-k3`,
  `kimi-k2.6` (what this uses — it is classification, not writing) and
  `kimi-k2.7-code-highspeed`. Re-read `platform.kimi.ai/docs/overview` rather
  than trusting this line; the lineup moved twice in three months.
- ⚠️ **Reddit search indexes POSTS, not comments.** There is no supported
  comment-search endpoint and the Pushshift mirror that filled that gap closed
  in 2023, so the radar finds threads and the reply opportunity is usually a
  comment *on* one. Adding `type=comment` does nothing; it is silently ignored.
- **`sort=new&t=week` against an hourly cadence is deliberate** — a 168×
  window means a missed run cannot lose a thread. Sorting by relevance would
  reorder under us and make the UNIQUE index on `reddit_leads.reddit_id` do all
  the work. That index is the dedupe, not a pre-read: two queries matching the
  same thread in one batch both pass a "have I seen this" check and then
  collide on insert.
- ⚠️ **No watchdog check of its own — the same deliberate exception
  `relay-rc-sync` carries.** The whole failure mode is "a marketing lead
  arrived late", which costs nothing and fixes itself next run; paging for it
  spends the one channel that has to stay readable. Check by hand:
  ```sql
  select status, count(*) from reddit_leads group by 1;
  select classify_error, count(*) from reddit_leads
    where classify_error is not null group by 1 order by 2 desc;
  ```

Secrets: `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET`, `REDDIT_USER_AGENT`
(Reddit's documented shape `<platform>:<app id>:<version> (by /u/<user>)` — a
generic one is throttled far below the documented ceiling, which reads exactly
like a bad client id and is not), `MOONSHOT_API_KEY`. **All four missing is a
clean no-op**: phase A records `reddit_credentials_missing` and the run still
returns 200, so the cron does not flap while they are unset.

Search terms live in `reddit_queries` (7 seeded) and are tunable without a
deploy. `NOTIFY_MIN_RELEVANCE` (70) and the `buying`-only intent filter in
`reddit-scan/index.ts` are **judgement calls, not measurements** — read
`/leads all` against what the owner actually replied to before moving either.

⚠️ **Unproven: this channel has produced nothing yet.** It went live
2026-09-15 with no leads surfaced and no reply posted. Judge it on replies
actually sent, never on leads surfaced — a radar that fills `/leads` with
threads nobody answers is a cost, not a channel.

### Instagram drafts — owner-approved, never auto-published (2026-09-22)

`insta-draft` (cron `relay-insta-draft`, daily 08:00 UTC) generates ONE post —
a 1080×1350 JPEG plus a caption — and sends it to the owner's Telegram as a
photo with two buttons, **Post** and **Skip** (`insta:post:<uuid>` /
`insta:skip:<uuid>`, handled in `telegram-webhook`). **Post** publishes it to
the app's Instagram account through Meta's Instagram API with Instagram Login
(container → poll `status_code` → `media_publish`, `_shared/instagram.ts`).
Owner decision: Telegram approval, not auto-posting.

🔴 **Nothing publishes without the owner's tap.** `insta-draft` does not import
the publish path at all; `publishImage` has exactly one caller, the Post
handler, and it runs only for the winner of an atomic
`pending → publishing` claim (`.eq("status","pending")` + row count), so a
double-tap, a Telegram retry or a stale button cannot publish twice. A row
**stuck at `publishing`** means the worker died mid-call — the post MAY be
live; check Instagram by hand, nothing retries it.

Kinds alternate off the last row: `screenshot` (a real screenshot from the
public `insta` bucket's `screens/*.png`, listed at runtime, with an AI headline
drawn above it) and `ai` (a model-generated image, cover-cropped to 4:5).
Themes rotate from `THEMES` in `_shared/instaCopy.ts`, avoiding the last four.
A cron run within 20h of the last draft is a no-op; `{"force":true}` overrides.
`{"probe":"image"}` composes one screenshot-kind image with a fixed headline,
uploads it to `insta/probe/` and returns its URL — **no model, no Instagram,
no credentials**; it exists to prove the image stack runs in the HOSTED runtime.

🔴 **The caption guardrails are product rules, stated twice on purpose** — in
the model prompt (`CAPTION_SYSTEM`) and in a code validator (`BANNED_PATTERNS`,
one exported constant) that rejects the draft outright: no prices or currency
of any kind (the storefront rule that binds every listing field), no supplier
named or hinted, no delivery promise (no "guaranteed", "100%", "instant"), no
outbound-texting promise, and **privacy framing only — never multiple/fake
accounts, bypassing verification or bans**, because this is posted ON
Instagram and Meta enforces against exactly that. A rejected caption is
retried once, then the draft is recorded `failed` and the owner is told.
⚠️ The validator covers the TEXT only. **A screenshot uploaded to
`insta/screens/` goes out as-is** — the raw Home capture shows "$3.99 first
month", a credit balance and the owner's first name. Upload only frames that
carry no price and no personal data. As of 2026-09-22 the bucket holds exactly
two, both checked by eye: `03_lineInbox.png` and `04_thread.png` (demo 555
numbers, sample codes). Of the 2026-09-10 raw set, `01_homeRouter`,
`05_home` and `07_homeLine` show the greeting name and balance, `06_email`
shows "$2.99/mo" and `02_lineStore` "only 8 credits" — all excluded.

🔴 **The live Instagram token is in `app_config.instagram_token`
(`{access_token, refreshed_at}`), NOT in a secret, and it must NEVER join the
`app_config` RLS whitelist** — it can post to the brand account. Supabase
secrets cannot be written from an edge function and a long-lived token dies
after 60 days unless refreshed, so the key is seeded once from the
`INSTAGRAM_ACCESS_TOKEN` secret and refreshed in place when older than 7 days
(`refresh_access_token`; a token must be ≥24h old to refresh). **After the seed,
changing the secret does nothing** — delete the key to re-seed.

Models are defaults (`anthropic/claude-sonnet-5` for captions,
`google/gemini-2.5-flash-image` via OpenRouter's Image API for images),
overridable without a deploy through service-role-only `app_config` keys
`insta_caption_model` / `insta_image_model` (a JSON string). Graph API version
is `GRAPH_VERSION` in `_shared/instagram.ts`.

Secrets: `OPENROUTER_API_KEY` (missing = clean 200 no-op, so the cron does not
flap), `INSTAGRAM_ACCESS_TOKEN` (seed only), `INSTAGRAM_USER_ID`. Image stack:
`imagescript@1.3.0` from deno.land/x (1.3.0, not 1.4.0, because 1.4.0 imports
its wasm as an ES module and 1.3.0 fetches it — the likelier shape to survive
bundling) and Inter ExtraBold fetched from a pinned jsDelivr path at runtime.
imagescript resizes nearest-neighbour only, so `instaImage.ts` carries its own
box+bilinear resample.

⚠️ **No watchdog check of its own — the same deliberate exception as
`reddit-scan`.** The failure mode is "no draft today", which costs nothing and
shows in the chat by its absence. Check by hand:
```sql
select status, count(*) from insta_posts group by 1;
select created_at, error from insta_posts where status='failed' order by 1 desc limit 5;
```

⚠️ **Unproven end to end.** As written 2026-09-22 it has been type-checked and
the image composition run LOCALLY only; no caption or image has been generated
by a real model, nothing has been posted, and whether imagescript's wasm loads
in the hosted runtime is unknown until `{"probe":"image"}` returns a URL. Judge
the channel on what it does for installs, not on posts made.

### Support is a server-controlled chat link, not in-app

🔴 **The in-app chat is GONE from the client (2.9).** Support is an external
chat link, `LegalLinks.supportURL`, opened from Account ("Chat with support"),
the Temp tab's "Have any questions?" card and `DeliveryInfoSheet`. **The
destination is `app_config.support_url`** (migration `20260923100000`, set from
the ops bot with `/supportlink <url>`), default **`https://t.me/vSMSAPP`** — the
owner's Telegram support account. The prefilled draft is exactly `Hi vSMS
Support`, in every locale (owner decision 2026-09-23: no build, no account id).

🔴 **WhatsApp Business BANNED the support account `+14375243093` on
2026-09-23**, and that is why the link is server-controlled. Builds 2.9–2.17
hardcode a `wa.me` link to that number, so **every Support button in every
build ≤ 2.17 still dead-ends at the banned WhatsApp account** and nothing
server-side can move them — only adoption of a build that reads the key fixes
it. From that build on, the next ban is one `/supportlink` command, not a
release.

Three properties that reading the code does not give you:

- **Only `https` links on host `t.me` or `wa.me` are accepted — by BOTH the
  client (`LegalLinks.validSupportBase`) and the bot (`supportBase` in
  `_shared/tgHandlers.ts`). Keep them in step.** Anything else falls back to
  the compiled default on the client, and is refused by the bot, so a stored
  value the app rejects cannot silently send everyone to the default. Any
  query/fragment on the stored link is dropped; the client appends its own
  `?text=`.
- **Unlike `launch_tab`, a fetched value is used IMMEDIATELY** — `supportURL`
  reads `PrefKey.supportURL` at tap time, and `refreshAppStatus` runs on every
  launch AND every foreground. It is persisted only so a launch whose status
  fetch fails keeps the last destination; an absent or rejected server value
  CLEARS it, returning the app to the compiled default.
- ⚠️ **`support_whatsapp_open` keeps its name for series continuity** (the
  Temp-tab card; `source: "home"` there means the TEMP tab — see "Home leads the
  app"). From the build after 2.17 it and `delivery_info_support_tapped` carry
  `dest` = the link's host (`t.me` / `wa.me`); read the event as "support
  opened", never as "WhatsApp opened".

⚠️ Build-verified only — the link has never been tapped on a device, so
whether Telegram honours the `?text=` draft from this app is unverified.

**Everything server-side stays deployed** — `support_threads`,
`support-send`, the Telegram relay, `/support` — because 2.8 and older still
send through it. Do not tear it down until 2.9 is fully adopted. Why it changed:
the Telegram path was answered late or not at all (a refund request sat 11 days
unanswered).

⚠️ **The bot has no way to CLOSE a support thread** — only `open → assigned` —
so answered threads sit in `/support` reading as live work. A `/close` command
is the missing piece; until then close one by hand
(`update support_threads set status='closed' where id=…`). 🔴 **The 6-hourly
`support_waiting` re-page is REMOVED (2026-09-22, owner request) — do not
re-add it**: with no way to close a thread, one stale pre-2.9 question paged
~68 times in 17 days. New messages are still relayed once by `support-send`.

## Non-obvious gotchas (real bugs, do not re-introduce)

- 🔴 **PostgREST drops ~1% of edge-function calls at the top of every minute,
  and it is the cron herd, not the query.** Every `* * * * *` relay fires at
  second :00, so three or four functions boot together and open their first
  PostgREST call at the same instant; on the free-tier compute PostgREST
  answers part of that burst with **504 after ~5s** (`postgrest_logs`: "Warp
  server error: Thread killed by timeout manager", ~2,000/day). Measured
  2026-09-12: 1,229 REST 504s in 24h, **89% in seconds 0–2 of the minute**, a
  flat ~50/hour around the clock, 99.7% from edge functions (the app itself
  took 4). The queries behind them run in under a millisecond. Consequences:
  a minutely job's FIRST read is the one that fails; a job that turns that
  into a 500 trips the watchdog's `relay-http` check; `poll-active-orders`'
  `app_config` health reads are the largest victim (819/day) and are simply
  lost until the next minute. Anything new on a minutely cadence must retry
  its reads — `readWithRetry` in `_shared/pgRetry.ts`, READS ONLY, used by
  `rc-sync`, `release-lines` and `sync-telnyx-cdr` — or start a few seconds
  late (`rc-sync` also sleeps 5s). The fix that
  would help everything — staggering the relays off :00, or paid compute —
  is an owner decision. Re-derive with the Supabase MCP `query_logs` tool on
  `edge_logs`, filtered to `response.status_code = 504` and grouped by
  `toSecond(timestamp)`; the second-of-minute histogram is the proof.
- **Edge functions die at ~150s wall clock**, and `EdgeRuntime.waitUntil`
  background tasks are killed at the same mark. Any job longer than ~2 minutes
  must be cursor-chunked across invocations.
  🔴 **`broadcast-push` hit exactly this on 2026-09-11** and it is the worst
  shape of the bug: a broadcast to 1,746 devices sent one push at a time, died
  on the timeout partway through, and **only FAILURES are logged — so which
  users were notified is unrecoverable, and a resend double-notifies everyone
  who already got it.** Fixed by sending `CONCURRENCY = 25` in flight. The
  lesson generalises: **a loop over a growing table is a time bomb with no
  alarm** — it was written for ~200 devices and silently outgrew its runtime.
- 🔴 **`push_devices` holds PushKit `.voip` tokens ALONGSIDE ordinary alert
  tokens** (`bundle_id` `com.anthersystems.VirtualSIM.voip`, 225 of them on
  2026-09-11, registered by the line product for incoming calls). **An alert
  push to one returns `400 DeviceTokenNotForTopic` and is never delivered.**
  Any user-visible send MUST filter `bundle_id = 'com.anthersystems.VirtualSIM'`;
  `broadcast-push` did not, and wasted ~13% of every broadcast. A `410
  Unregistered` is different and benign — APNs saying the app is gone.
- **A positional cursor must walk a SORTED list.** A query with no `order by`
  can return rows in a different order on any run, so the cursor skips some
  permanently — those routes never got probed and were sold as VoIP-only
  forever.
- **`order_status` cannot grow a value without shipping the app first.** iOS
  `OrderStatus` is a plain `String` enum with **no unknown case**, so a status it
  does not recognise throws on decode and breaks the Orders tab for everyone on
  the released build.
- **A status string written from TS is NOT checked against the enum — and the
  error is discarded.** `create-esim-order` wrote `"canceled"`, a member of
  `order_status` but **not** of `esim_status`; PostgREST rejected the UPDATE,
  the code did not destructure `error`, and **every failed eSIM purchase charged
  the user and silently kept the money.** The two enums share several names and
  differ in exactly the ones that matter.
- **An unqualified `UPDATE` inside a SECURITY DEFINER function fails when called
  over RPC** — `UPDATE requires a WHERE clause`. Fine in the SQL editor, throws
  the moment `sb.rpc()` invokes it. Add `where id is not null` to any deliberate
  table-wide UPDATE, and check `maintenance.*` in the `sync-prices` response for
  `"error: ..."` strings — each job is wrapped in try/catch, so a broken one
  returns 200 with the error nested in the body.
- 🔴 **`on conflict (version) do nothing` WILL SILENTLY SWALLOW YOUR MIGRATION
  RECORD** when two sessions pick the same timestamp. **After recording a
  migration, SELECT it back by name**, and pick a version by reading
  `select max(version) from supabase_migrations.schema_migrations` rather than
  from the clock — more than one session works on this repo per day.
- **`apply_migration` (MCP) mints its own version and does NOT write a repo
  file.** Three migrations performing an entire provider cutover once existed
  only in the live DB. After any `apply_migration`, immediately write
  `supabase/migrations/<live-version>_<name>.sql` with the same SQL.
- **After writing a migration, `select proname from pg_proc` for what it
  creates** — not just `schema_migrations`. A migration that is merely missing is
  inert; one that is missing *while something calls it* is a live bug wearing no
  symptom, and that shipped for three days.
- **`supabase db push` is BROKEN** — it aborts on remote versions with no local
  file. **Do NOT run the `migration repair --status reverted` it suggests**:
  those migrations really are applied, and marking them reverted invites a later
  push to re-run them. Apply with `db query --linked --file <path>`, then record
  the row yourself. (`db query` parses a leading `--` SQL comment as a CLI flag —
  always use `--file`.)
- **PostgREST `max_rows` is `60000`.** Crossing the cap makes PostgREST
  **truncate silently** — HTTP 206, no error, the app just gets fewer routes and
  every missing one renders "Unavailable". Indistinguishable from "the prices
  are wrong" from the phone.
- **Clients get `UPDATE` on `profiles.display_name` ONLY.** RLS cannot restrict
  columns, so a table-wide grant let any user PATCH their own `referred_by` and
  null the payout flag — farming credits forever.
- **A constant duplicated across files WILL drift.** Surviving duplicates:
  `MAX_WHOLESALE_CENTS` (four syncs), `ESIM_MARGIN`/`CREDIT_VALUE_USD` (two
  each), and the balance alert level (three copies, table above). Changing one
  in one place once stripped 1,432 routes of their carrier pin.
- **`isOk()` dereferences its argument and callers pass it `null`.** Fixed, but
  the shape recurs: `smsGetBalance().catch(() => null)` then `isOk(before)` is a
  `TypeError` **after the number is already reserved**.
- **Deleting an IAP receipt to force StoreKit redelivery can eat the payment.**
  The client runs two paths into `iap-verify`, so a concurrent duplicate may
  already have been answered `already_credited` and called `finish()`. It now
  zeroes `granted_credits` instead, keeping both the audit trail and the replay
  guard.
- 🔴 **`INFOPLIST_KEY_<name>` SILENTLY DOES NOTHING for keys outside Xcode's
  allowlist.** `INFOPLIST_KEY_UIBackgroundModes` is accepted, appears in
  `-showBuildSettings`, and never reaches the generated Info.plist — no warning,
  build succeeds, **VoIP pushes are then never delivered and nothing logs a
  reason.** The real keys live in **`VirtualSIM-Info.plist` at the repo root**
  (`INFOPLIST_FILE`, `GENERATE_INFOPLIST_FILE` still YES so Xcode merges).
  It must stay OUT of `VirtualSIM/`, a synchronized root group, or the build
  fails with *"Multiple commands produce …/Info.plist"*. **Assert against the
  BUILT plist, never the build setting:** `plutil -p "$APP/Info.plist"`.
  ⚠️ **The launch-screen colour was the same shape** (found 2026-09-24):
  `INFOPLIST_KEY_UILaunchScreen_BackgroundColor = LaunchBackground` was set,
  yet the built `UILaunchScreen` was an empty dict, so the system launch
  screen drew white / black and `LaunchBackground.colorset` was never used.
  `UILaunchScreen.UIColorName` now lives in `VirtualSIM-Info.plist` beside
  `UIBackgroundModes`, and the dead build setting is deleted (2026-09-25).
- **`UUID.uuidString` is UPPERCASE and Telnyx's detail records are lowercase.**
  Exact-string matching would settle nothing and look exactly like a provider
  that never reported the call.
- **Cover/sheet content does NOT inherit `@Observable` env objects from the
  presenter.** Always wrap sheet/cover content with `EnvBundle`.
- 🔴 **Which PRODUCT the user is buying is declared, never inferred** —
  `AppState.PurchaseIntent`, set at each entry point and cleared centrally in
  `flow`'s `didSet`. This bug class has appeared **three** times: a checkout
  draft read outside its flow priced the Temp screen (then named
  `HomeScreen`) for the last-checked-out service; a
  never-cleared eSIM plan made every "how many credits do you need?" answer for
  that plan for the rest of the session; and turning e-mail mode off was a
  no-op. **The general rule: when a write path branches on `flow` but the
  matching read path doesn't, the two disagree the moment the flow ends.** A
  mode switched *outside* a flow needs its own clear, because `flow`'s `didSet`
  never fires for it.
- 🔴 **A BACKGROUND SWEEP MUST NEVER WRITE WHAT A SCREEN IS RENDERING.**
  `ContentView`'s app-wide e-mail poll used `state.activeEmailOrder` as its
  cursor — and that is also the single property `EmailCodeScreen` renders,
  which holds no copy of its own. So the instant an order delivered, the sweep
  called it finished (`received` satisfies `EmailStatus.isTerminal`), moved its
  cursor to another waiting order, and **replaced a delivered code on screen
  within ten seconds**. The cover never dismissed — the digits just turned back
  into "Fetching the code…", which is exactly how the subscriber who reported
  it on 2026-09-21 described it. It only bites when a second `waiting` row
  exists locally, which for an 8-a-day subscriber is routine: `refreshEmailOrder`
  updates one row and only `loadEmailOrders` re-reads the rest, so
  server-expired orders sit in the client array as `waiting` all session.
  Fixed by giving the sweep a LOCAL cursor and making `refreshEmailOrder` take
  an explicit target that touches `activeEmailOrder`/`flow` only when it IS the
  on-screen order. ⚠️ **This is also the `code is not null` rule breaking one
  level up from where anyone looks for it**: rendering honoured it correctly
  all along; the violation was the *poller's* "is this finished?" test asking
  `status.isTerminal`. Build-verified only — never walked on a device.
- **In e-mail mode the SMS route price and delivery record must NOT render.**
  Another product's evidence is not this product's.
- **A snake_case property name is a decode FAILURE, not a no-op.**
  `.convertFromSnakeCase` means `{thread_id}` arrives as `threadId`; a struct
  declaring `let thread_id` matches nothing and throws. A support message that
  was stored AND relayed reported "Couldn't reach the server" to the user. When
  a caller discards the response, decode `APIClient.Empty` and give the endpoint
  no client-side contract to break.
- **`APIError.decoding` must never render as a connectivity message.** A decode
  failure means the request **succeeded** — telling the user to check their wifi
  and retry an action the server already performed is worse than saying nothing.
- **`tint_hex`, not `tint`** — and the same snake→camel rule for every
  Service/Country/Route field.
- **Logos + flags are bundled** and the Xcode synchronized group **flattens**
  them into the bundle root, so lookup is by flat filename. Clearbit was removed
  (host no longer resolves); do not re-add it.
- **Review prompt must stay incentive-free (App Store 5.6.4).** Never tie
  credits to a review, and never build a custom review UI that deep-links to the
  App Store page.
- **A git worktree cannot build until you copy `Secrets.swift` in** (it is
  gitignored), and **is not linked to Supabase** until you copy
  `supabase/.temp`. Both failures look like your edit broke something and are
  neither. Do NOT re-run `supabase link` in a worktree.
- **Xcode rewrites `Localizable.xcstrings` in the PRIMARY checkout while you
  work in a worktree.** It is the string extractor, not human edits. Diff before
  discarding, then `git checkout --` it.
- **DEPLOY AFTER COMMITTING, never before.** Every stale-deploy bug in this
  codebase comes from deploying mid-edit and then committing the final version.
  One such bug had eSIMs turning back on every morning for days: the function
  was deployed three minutes *before* the commit that taught it about pausing,
  so production ran a bundle that had never heard of the feature. **The symptom
  pointed at the pause code; the fault was that the pause code was never
  running.**

## Provider switch checklist

All FOUR switches broke something that threw no error. If you change the SMS
provider again:

0. **Record ownership in `routes.provider` and make the router read it FIRST.**
   Once a route can carry codes for two providers, code-presence routing sends
   the order to whichever adapter is checked first — which may not be the one
   that PRICED it. That is a margin gate reading one provider's cost against
   another's price list: it once refused **3,064 of 4,080 routes** as
   `margin_too_low`, charging and refunding every time.
1. **Update `providerOrder()`** — the only routing truth.
2. **Re-home `routes`.** Hand every combo the new provider can serve back to it,
   or `sync-prices` will skip those rows and never reprice them — that silently
   killed the two best-delivering routes in the app.
3. **Check the crons.** Unscheduling a provider's sync also kills anything else
   living inside that function. Four maintenance jobs died this way and froze
   the "self-correcting" catalog with no signal.
4. **Re-price before re-enabling.** Confirm `count(*) where smoothed_cost_cents
   < last_cost_cents` is **0**.
5. **Classify the new provider's errors.** `create-order` branches on
   `errorType`. If the adapter does not set it, *every* failure — dead account,
   bad key, rate limit, genuine stockout — collapses into "no numbers
   available", so users are told to try another country while the product is
   down, and the escalation never fires.
6. **Point balance monitoring at it** (`app_config.<provider>_health` + the
   `ROLE` map in `_shared/opsFormat.ts`).
7. **Verify with data, not the deploy log.** A single blended rate averages a
   dead provider with a live one and describes neither.
8. **Re-check `active_sms_provider()` AFTER the dust settles.** A per-service
   split plus a sync that hides unfulfillable rows can leave the **retired**
   provider holding more rows than the live one — which is exactly what
   happened, pointing all five evidence functions at the wrong provider.
9. **Give the new provider its own cost column**, and scope every cached-cost
   fallback to the provider that owns the row. A `??` onto a stale value passes
   the margin gate and then fails at reservation — a charge-and-refund that
   looks like a stockout.

## Current state

🔴 **Every number in this section moves. RE-QUERY; do not quote this block.**
Each has been wrong within a day of being written at least once.

**Verified 2026-09-09:**

- **iOS**: **2.18 (build 70) is `WAITING_FOR_REVIEW`** (submitted
  2026-09-23 12:08Z; version `5e0ecfd7-…`, submission `d9485c31-…`). It
  carries the Telegram support link (`app_config.support_url`) — the only fix
  for the dead WhatsApp support button in every build ≤ 2.17 — plus the
  pre-review audit fixes: the recovered line-purchase state, the phone-only
  e-mail warning, the Delete Account warning, the 30-day mail limit
  disclosure, the US texting failure copy, cross-category search, the mailto
  fallback, VoiceOver labels, and five new events. Build 69 (support link
  only) was uploaded and superseded before submission. ⚠️ `asc-release.py
  submit` hit HTTP 500 at `POST /v1/reviewSubmissionItems` twice, leaving an
  empty staged submission; it was finished by adding the item to THAT
  submission and PATCHing `submitted: true` — do not create a second one.
  Release notes (13 locales) mention Telegram support; `asc-listing-check.py`
  0 findings. All of it build-verified only, never walked on a device.
- **2.17 (build 68) is `READY_FOR_SALE`** (approved 2026-09-23; version
  `0a058c80-…`, submission `c99cea28-…`, submitted 2026-09-22 17:55Z). It carries the 1-credit e-mail fallback, the subscriber usage
  meter, the correct `monthly_cap_reached` message, and the Home cut-down of
  2026-09-21. 13 release-note locales written and read back (no numbers, no
  prices); `asc-listing-check.py` 0 findings; `BuildMachineOSBuild` → `25F84`
  patched and verified in the IPA with VoIP background modes present.
- **2.16 (build 67) is `READY_FOR_SALE`** — submitted 2026-09-17 20:10Z and
  approved; this block said "NOT YET SUBMITTED" for five days after that.
  It carries the US/CA texting disclosure (`LineStoreScreen.sendingNotice`,
  `LineCheckoutScreen.capabilityNote`) and NOT the e-mail cap copy: every
  build ≤ 2.16 renders `monthly_cap_reached` as the generic 429 "You're going
  a bit fast".
- **2.15 (build 66) is `READY_FOR_SALE`** — approved (read from ASC
  2026-09-17); this block called it `WAITING_FOR_REVIEW` for two days.
  Historical: it was submitted 2026-09-15
  22:58Z, submission `6c5dd143-…`, version `2819e552-…`). It carries the
  announcement banner's move to Home, the vRoam card, the review prompt
  extended to line subscribers, **the two review-gate fixes of 2026-09-16**
  (a successful credit purchase lifts `suppressReviewThisSession`;
  `reviewCalmFloorHours` is 0), and **the re-scored keyword fields in all 13
  locales** — the first release that could carry them, since keywords ship
  only with a version and there was no editable one until 2.15 existed. It
  therefore also UNDOES 2.14's hand-edit.
  ⚠️ **Build 65 was cancelled and replaced by 66** (owner, 2026-09-16), the
  fourth exercise of the DEVELOPER_REJECTED recovery path: submission
  `567b7a25-…` cancelled → version `DEVELOPER_REJECTED` → attach 66 →
  `PREPARE_FOR_SUBMISSION` → resubmit. The 13 localizations and the
  screenshots survived untouched, and `asc-listing-check.py` read 0 findings
  immediately before the resubmit.
  ⚠️ Built on beta macOS `26A5388g`, so the `BuildMachineOSBuild` → `25F84`
  patch was applied and verified in the exported IPA; without it Apple rejects
  the binary as ITMS-90111.
- **2.14 (build 64) is the LIVE version, `READY_FOR_SALE`** (version id
  `2e856187-…`, submitted 2026-09-13 10:04Z). It carries the delivery
  explainer. 🔴 **It also carries a hand-edited en-US keyword field that no
  document approved** — see the ASO section; 2.15 reverses it. 2.13 (build 63) is also `READY_FOR_SALE` and is the version this
  block used to call current; historical detail follows.
  **2.13 (build 63)** (read from ASC 2026-09-12 22:00Z;
  submitted 2026-09-11 12:07Z as `c131076d-…`; 22 distinct users fired
  `home_view` — which only 2.13 emits — in the 24h to 2026-09-12 22:00Z, so
  approval landed within a day of submission and adoption has begun). Build
  62's submission (`42c648b1-…`) was
  cancelled the same day and replaced; the version row, its 13 localizations
  and **the 11 screenshots the owner uploaded by hand are unchanged** — which
  is the whole reason this shipped as a new BUILD of 2.13 rather than a new
  version, since a new version row would need the screenshots again.
  Build 63 adds, on top of build 62's Home tab / intro display / grant-at-0:
  the rebuilt review prompt, the trial-eligibility gate on both subscription
  stores, the checkout better-odds steer, and the **approved keyword field in
  all 13 locales**.
  ⚠️ **Read ASC, never this line** — `python3 scripts/asc-release.py status
  2.13`. Pull a version back out of review with `asc-release.py cancel 2.13
  --apply`, which REFUSES if the submission carries anything but the app
  version (cancelling IAP items is recoverable only in the web UI).
  ⚠️ **2.12 was never released**: Apple refuses a second editable version
  (`ENTITY_ERROR.RELATIONSHIP.INVALID`, "You cannot create a new version of
  the App in the current state"), so the 2.12 row was RENAMED to 2.13 rather
  than a new one created — same version id `614dfb01-…`, its 13
  localizations intact. There is no separate 2.12 on ASC any more.
  Historical 2.12 detail follows.
- **iOS (2.12, superseded)**: `CURRENT_PROJECT_VERSION 61`. **2.12 is
  `DEVELOPER_REJECTED` with build 61 still attached and NO open submission**
  (owner asked for the cancel on 2026-09-10 ~11:30Z; submission `19946a38-…`
  reads `COMPLETE`, version `614dfb01-…`). It is the THIRD cancel of 2.12:
  build 59 (09-09 18:28Z, replaced to carry the no-pre-selection change),
  build 60 (09-09 20:03Z, replaced to carry the recovery-card pool-rate
  steer), build 61 (09-10 08:57Z, cancelled unsubmitted-for-review; the
  $3.99 intro display on the worktree branch is a candidate for the next
  build, together with the Home tab (2.13)). Each cancel takes the version
  through `DEVELOPER_REJECTED`, the documented recovery path, with the 13
  localizations untouched. Recover with
  `scripts/asc-release.py build 2.12 <n> --apply` then `submit 2.12 --apply`.
  **2.11 and every earlier version are `READY_FOR_SALE`**. 2.12 carries the
  tab repositioning, the product-first line store, the `OtpScreen` upsell,
  `/tabs`, the first-run "Not selected" pair, and the recovery card's
  High-band pool offer.
  ⚠️ **Read ASC, never this line** — `python3 scripts/asc-release.py status
  2.12`. It has been wrong about the review state five versions running, and
  that is a decision error, not a typo: "still in review" is the argument for
  cutting another release.
- **Backend**: 52 edge function dirs besides `_shared`, 241 migration files, 29
  files in `_shared`, 139 Swift sources (re-counted 2026-09-15), 25 active
  cron jobs.
- **Catalog**: 9,364 active routes (5sim 8,074 / HeroSMS 1,290), 468 services,
  0 active eSIM plans (line parked). `active_sms_provider()` = `5sim`.
  Evidence: 53 routes `measured`, 23 `seeded`.
- **Lines**: 10 unreleased `phone_lines`; 19 line subscriptions all-time (8
  active, 1 grace, 9 expired, 1 revoked); 13 e-mail subscriptions (4 active, 3
  grace, 4 billing_retry, 2 expired).
- **Config**: signup grant **0** (owner decision 2026-09-10 — see the grant
  section above; `app_config.signup_bonus_credits`), free e-mail cap
  **1**/user/day, **subscriber e-mail cap 10/day AND 100 per rolling 30 days (raised from 8/60 on 2026-09-24),
  both counting DELIVERED addresses only since 2026-09-21
  (the monthly one added 2026-09-21 because the 25 → 8 daily cut did not stop
  the TikTok farm — see the temp-e-mail section)**, swap **8**
  credits, `launch_tab` = `line` (order behind Home; Home always first from
  2.13), mail subscription **enforced**, **no free trial on either
  subscription** (`mail.yearly`'s 175 territory offers removed 2026-09-16;
  `line.monthly`'s $3.99 PAID intro is the only introductory offer left),
  eSIM **paused**, lines **not**
  paused, daily credit **disabled**.
- **Balances** — re-query, these move hourly:
  `select key, value->>'balance_usd' from app_config where key like '%_health';`
  5sim $8.29, HeroSMS $14.85, Telnyx $12.87, eSIM Access $86.69
  (re-read 2026-09-11 08:14Z).

✅ **NO WATCHDOG CHECK IS FIRING** (verdict `[]` at 2026-09-13 07:07Z):
- **`5sim-float` cleared** — not by money but by the owner retiring the runway
  line for the SMS providers (above). 5sim is at $16.94 against the $5 floor,
  burning $4.38/day gross; it is the PRIMARY SMS provider, so an empty float
  fails every temp-SMS order as `provider_unreachable`, and the page now comes
  only under $5. Re-query, never quote.
- ✅ **`telnyx-float` cleared** — $12.87 against the $10 floor, `alert_tier` 0.
  It fell to $2.87 on the morning of 2026-09-11 (from $12.42 twelve hours
  earlier) and the owner funded it. **The drain was number purchases at $2.00
  each, 63% of them swaps — not calls, which cost $2.00 across 14 days.** See
  the Known-open entry and "The lapse machine".

### Territories and store

- **China is REMOVED from availability** (Apple/MIIT forbid CallKit in apps sold
  on the China App Store, and we ship CallKit). Re-adding China requires gating
  CallKit off by storefront first — do not re-tick it casually.
- **Supabase project is on the FREE plan (no backups).** Owner action.
- 🔴 **E-mail sign-up depends on the IONOS domain `vsmsapp.com`, and nothing
  monitors it.** Supabase Auth sends confirmation codes through Resend from
  `mail.vsmsapp.com`. IONOS put the domain on `clientHold` on 2026-09-02 —
  exactly 15 days after registration, the ICANN unverified-contact deadline —
  which removed it from DNS; Resend then refused every send and **every e-mail
  `/signup` returned 500 for three weeks** (45 in the last 22h before the fix)
  while Apple sign-in hid it. Fixed 2026-09-23 (registry hold dropped 10:54Z,
  Resend re-verified). Check: `whois -h whois.verisign-grs.com vsmsapp.com`
  must show no `clientHold`, and `auth_logs` `/signup` must not be 500 with
  "domain is not verified". A watchdog check on auth `/signup` 5xx is the
  missing guard.

## Known-open

Genuinely open items only. Resolved history is in `docs/decisions-archive.md`.

**Money / owner action**

- ⚠️ **5sim float is ~4 days of reservations** ($16.94 at $4.38/day gross on
  2026-09-13) and the watchdog no longer says so — the runway page is off by
  owner decision, so the next page arrives only under $5, roughly one day of
  burn. (Telnyx fell to $2.87 on the morning of 2026-09-11 and the owner
  funded it; $24.12 on 09-12. Re-query both, never quote either.)
- ⚠️ **Telnyx float is drained by NUMBER PURCHASES, and most of them are
  SWAPS — not by calls.** Measured 2026-09-11 over the prior 7 days: **24
  numbers bought, 15 of them swaps** (from **4** users; one line swapped 7
  times in 2 days), ≈ **$48/week** at $2.00 a number, against **$2.00 of call
  cost over 14 days**. A swap buys a fresh number AND forfeits the old one's
  remaining month, so it costs a full $2.00 every time.
  `app_config.line_swap_cooldown_days` is **0** and `begin_line_swap` caps
  nothing else, so swap frequency is unbounded. It is not abuse and not a
  loss — 8 credits (~$3.20 net) covers $2.00, and the four swappers are the
  app's heaviest pack buyers (8, 4 and 2 packs) — but Apple pays weeks later
  while Telnyx debits now, so **growth and swaps are a working-capital
  problem, not a leak**. A non-zero cooldown is an owner decision; the
  machinery already exists and needs only the config key set. Re-derive:
  ```sql
  select 'swap' src, count(*) from line_number_swaps where created_at > now()-interval '7 days'
  union all select 'new line', count(*) from phone_lines where created_at > now()-interval '7 days';
  ```
  ⚠️ **The swap is what some subscribers are actually buying, and the
  subscription is the tollgate — so a cancel inside the first hour is not
  churn and must not be read as one.** Walked end to end on 2026-09-14 from one
  new French user's first session: signed up 18:16Z, priced temp SMS for France
  at **90 credits** and backed out, subscribed at the €3.99 intro 18:19Z,
  received a verification code for a French consumer app on the number at
  18:20Z — then **swapped twice in seventeen minutes and collected three
  more codes**, turning auto-renew OFF at 18:32Z between the second and third
  while still actively succeeding. He was registering repeat accounts on one
  service; the line was a disposable-number machine bought for a burst, and the
  month was already paid. Read a fast `auto_renew = false` on a line that is
  still receiving SMS as THIS, not as a product failure.
  🔴 **The 8-credit pack costs EXACTLY one swap, so a swapper's balance
  returns to 0 every single time and every additional number is a fresh paywall
  plus an Apple sheet** — three sheets in seventeen minutes here, each
  preceded by `line_swap_topup_shown` with `shortfall: 8`, plus three
  `line_swap_open` events backed out of on seeing another charge. That is the
  friction to read `line_swap_topup_shown` against `line_swap_result` for; it
  is also what makes each swap self-funding, so do not "smooth" it by
  discounting the swap without re-checking the $2.00 number cost first.
  ⚠️ **Per-user margin is thinner than the swap arithmetic alone
  suggests, because the SUBSCRIPTION's number is bought at $2.00 too and then
  forfeited by the first swap.** That session: €11.97 gross (one intro month
  + two 8-packs), **≈€10.17 net at Apple's 15%**, against **three** Telnyx
  numbers = **$6.00** debited the same evening — so roughly half of what
  survives Apple went straight back out at the provider within the hour.
  Comfortably positive, and the working-capital shape above rather than a
  leak; the point is only that a revenue chart reading €12 is not €12 of
  margin. 🔴 **Apple's cut is 15%, not 30% — vSMS is on the Small Business
  Program** (`APPLE_COMMISSION = 0.15` in `_shared/opsFormat.ts`, and the
  measured `NET_USD_PER_CREDIT = 0.40` independently confirms it: at 30% no
  pack above the 5 nets even $0.33 a credit). Never net a vSMS figure at 30%.
- ⚠️ **`orders`, `esim_orders` and `email_orders` still expose per-order
  wholesale** to a self-reading user. Smaller than the cost-book leak that was
  closed (RLS is self-read, so a user leaks only their own), and **the adoption
  gate is NOT met**: `select=*` still arrives on `/email_orders` (84 distinct
  IPs) and `/orders` (34) in a 24h window. Re-run that edge-log query before
  revoking; revoking today breaks those clients.
- ⚠️ **The monthly voice allowance is enforced by one request the client
  chooses to make** (read from code 2026-09-24; live Telnyx values NOT read).
  The 100 minutes are checked only in `begin-line-call`
  (`consume_line_allowance`, 409 `allowance_exhausted`). That function places
  no call: `mint-line-token` hands the device the connection's SIP username
  and password, so a modified client can dial from any SIP client without the
  gate. The real backstop is the Telnyx per-voice-profile daily spend limit,
  **$5.00/day as the code default** (`_shared/telnyx.ts`, and its one caller
  in `_shared/lineVoice.ts` passes no override). **The live per-profile values
  were never read**, and whether the limit also covers the WebRTC leg is
  unknown. `channel_limit` is null (one profile, probed 2026-09-08) and there
  is no maximum call duration, by design. At $5/day the ceiling is about
  $150 per line per month. Read every profile's `daily_spend_limit` before
  relying on it.
- ⚠️ **An outbound NANP minute of CDR TALK time costs about $0.028–0.029,
  not the $0.007 (US) / $0.011 (CA) per-block headline** (measured 2026-09-24
  from `line_calls.provider_cost_usd`: $0.0281 over 90 days, 251 CDR-settled
  calls, 88.9 talk-minutes; $0.0287 over 30 days). Telnyx bills each call in
  60-second blocks, and the median outbound call lasts 2 s. That is per
  TALK-minute from detail records; the allowance's METERED minutes also
  include the 120 s reservations billed by the no-CDR backstop, so they are
  not the same unit. All calling cost about $3.25 in the 30 days to
  2026-09-24 ($2.42 outbound NANP, $0.72 inbound, $0.11 international);
  number rent is far larger. Re-derive both (queries run 2026-09-24):
  ```sql
  -- $ per CDR talk-minute, outbound NANP, 90 days (backstop rows excluded)
  select count(*) calls, round(sum(billed_seconds)/60.0, 1) talk_min,
         round(sum(provider_cost_usd)::numeric, 3) cost_usd,
         round((sum(provider_cost_usd)/nullif(sum(billed_seconds)/60.0,0))::numeric, 4) usd_per_talk_min,
         percentile_cont(0.5) within group (order by billed_seconds) p50_seconds
  from line_calls
  where direction = 'outbound' and credits_reserved = 0
    and provider_cost_usd is not null
    and coalesce(hangup_cause, '') not like 'no_cdr%'
    and created_at > now() - interval '90 days';
  -- 30-day calling cost and CDR talk-minutes, by direction, NANP vs international
  select direction, credits_reserved > 0 as intl,
         round(sum(provider_cost_usd)::numeric, 3) cost_usd,
         round(sum(billed_seconds) filter
               (where coalesce(hangup_cause,'') not like 'no_cdr%')/60.0, 1) cdr_talk_min
  from line_calls where created_at > now() - interval '30 days'
  group by 1, 2 order by 1, 2;
  ```
  **As of 2026-09-24 nobody had exceeded 60 metered minutes in a month; the
  top line was at 59.9 about 6 days into its period** (that figure includes
  backstop reservations). Re-derive the metered minutes per (user, month):
  ```sql
  select date_trunc('month', created_at)::date month, user_id,
         round(sum(billed_seconds)/60.0, 1) metered_min,
         round(sum(provider_cost_usd)::numeric, 3) cost_usd
  from line_calls
  where direction = 'outbound' and credits_reserved = 0 and allowance_settled
    and billed_seconds is not null
  group by 1, 2 order by 3 desc limit 5;
  ```
- ✅ **Owner decision 2026-09-24: unlimited US/Canada calling was considered
  and DECLINED; the 100-minute allowance stays.** The two items above and the
  Guam / Northern Mariana Islands / American Samoa row under "Correctness /
  hygiene" are what that research left open.

**Unproven claims**

- ⚠️ **The second-code resend window has never delivered a second code.** The
  pool list is 5sim's claim. Proof is the first `resend_promoted` log line.
- ✅ **RESOLVED 2026-09-13: `pool_rate_pct` DOES predict our delivery** (47% /
  40% / 17% per try across High / Medium / Low, 295 settled orders, both
  filters applied). The number stays on the row. See "The pool rate is the
  tie-break" for the table and for what the finding does NOT license.
- ⚠️ **The VoIP/`physicalCount` hypothesis is untested, not falsified.**
  `orders.operator_used` is the control arm; it needs volume.
- ⚠️ **The tail 5× pricing experiment has not been read out.**
- ⚠️ **The Reddit radar has produced no reply yet** (live 2026-09-15). Judge it
  on replies the owner actually POSTED, not on leads surfaced; a `/leads` list
  nobody answers is a cost. Its relevance threshold and `buying`-only intent
  filter are judgement calls that have never been read out.
- ⚠️ **The first non-NANP line order has never run.** Today's sellable set
  (US/CA/PR) needs no documents, so only the proven NANP path is exercised. When
  a requirement group first makes a documented country sellable, **the first
  order IS the probe**.
- ⚠️ **2.12's number picker and OTP upsell card were never walked on a device** —
  tap automation was unavailable, so both are build-and-screenshot verified only.
- ⚠️ **2.13's Home tab was never walked on a device** — the three card taps, the
  seven-service grid and its More tile, the Recent rows' openers, the `NameSheet`
  write, the `emailMode` switch and the Call-button gate are build-and-screenshot
  verified only (both states, iPhone 17 Pro and SE), same caveat as 2.12's picker
  and OTP card.
- ⚠️ **The $3.99 first-month intro (2026-09-10) has no reading yet.** Judge it
  on `line_purchase_result` `props.intro = true` sheet→paid at ~30 sheets,
  against 3 of 30 before. The client display ships in 2.13; until then only
  Apple's sheet shows it.
- ⚠️ **The checkout better-odds steer is build-verified only.** New in 2.13
  build 63: `CheckoutScreen.betterOddsCard` offers a HIGH-band country before
  the charge, the same `bestPoolRatedCountry` the recovery card uses after a
  failure. Never walked on a device, and its thresholds
  (`AppState.checkoutSteerMinGain` = 15 points) are judgement calls. Read
  `checkout_steer_shown` against `checkout_steer_taken` before moving either.

**Product / listing**

- ⚠️ **The ASC screenshots on the live listing predate the Home tab.** Six
  RAW frames (Home router, line store, inbox, thread, temp SMS, temp e-mail;
  iPhone 17 Pro Max, 1320×2868, untouched `simctl io screenshot` PNGs) were
  captured on 2026-09-10 into `~/Desktop/vSMS-Screenshots/raw/` for the owner
  to edit and upload with 2.13. 🔴 **The owner composes screenshots
  THEMSELVES — deliver raw captures, never captioned slides.** The composed
  pipeline (`scripts/screenshots/make-set.py`, `compose-slide.py`) still runs
  and writes a `set/` tree, but nothing the owner uploads comes from it.
- ⚠️ **The App Privacy label for 2.6's analytics is owner-reported, not
  verified** — the API cannot read or write it. Check for an unpublished draft.
- ⚠️ **The Telegram bot cannot close a support thread**, so answered threads
  read as live work in `/support` (they no longer page — see "Support is
  WhatsApp").
- ⚠️ **No server-sourced allowance exists before purchase** (verified
  2026-09-24 on branch `design-overhaul`): `line_country_menu` and
  `search-line-numbers` carry none, and the paywall's minutes figure is
  `LineProduct.voiceAllowanceMinutes`, a client mirror of the `phone_lines`
  schema default. The redesigned store (spec §4.1) therefore shows NO
  allowance. Showing one needs the owner to decide whether to publish it
  server-side.
- ⚠️ **The My number overhaul (branch `design-overhaul`) is build- and
  screenshot-verified only.** Tap automation is unavailable; a device walk
  (store → paywall → Apple sheet, Switch → confirm, thread push from a real
  notification, a real call over a pushed thread) is required before merge.
- ⚠️ **The store names the monthly price again on branch `design-overhaul`**
  (StoreKit only, hidden until it loads), reversing the 2026-09-09 'no price
  on the store' decision by the approved 2026-09-24 design.

**Correctness / hygiene**

- ⚠️ **Guam, the Northern Mariana Islands and American Samoa (+1671, +1670,
  +1684) are labelled "Included in your minutes" but likely cannot be
  dialled** (found 2026-09-24). CHECKED: they have no override row in
  `voice_rates`, and `voice_rate_for()` resolves them to the covered `'1'`
  "United States & Canada" row, so the dialer says they are included.
  INFERRED, never tested: the Telnyx refusal. The outbound voice profiles
  whitelist US, CA, PR and VI as their only +1 (NANP) destinations — 53 ISO
  codes in all (`voice_dial_destinations()`), the rest being the
  credits-priced international list — so the call most likely fails at the
  carrier after we reserve 120 s. The fix is three
  `voice_rates` override rows with `enabled = false` (a migration). Not done.

- ⚠️ **The Real SIM tier does not exist on ANY 5sim-owned route** — 0 of 8,065
  carry `premium_credits` (2026-09-10; `select provider, count(*) filter (where
  premium_credits is not null) from routes where status='active' group by 1`),
  and every US Meta/dating route paying users fail on (whatsapp/us 1 of 8,
  instagram/us 0 of 3, badoo/us 0 of 4, tinder/us 1 of 4) is 5sim-owned.
  `create-order` resolves `premiumPin` only for `smspva`/`herosms` owners, so
  a premium request there is a 409 by omission. HeroSMS holds real-carrier
  pins (`herosms_real_operators`) on 2,595 of those rows, at a fraction of
  5sim's cost (instagram/us 7¢ vs 175¢). Enabling premium there means a
  TIER-SCOPED second owner: `premiumPin` from `herosms_real_operators` when
  `provider='5sim'`, the reservation sent to HeroSMS, the margin gate reading
  `herosms_cost_cents`, and `sync-herosms` writing `premium_credits` on rows it
  does not own. That is a change to the "one provider per route" rule in a
  money path — **owner decision, not done.** The 4 premium orders ever placed
  delivered 3; that is the whole evidence base.
- ⚠️ **2.12 build 61's recovery-card pool-rate steer is build-verified only** — no
  device walk, same caveat as 2.12's picker and upsell card.
- 🔴 **`AppState.routes` is now genuinely dead** — written once
  (`AppState.swift:1795`), read nowhere. ⚠️ This file previously carried a
  *refutation* saying it was read in `CreditsSheet.swift`; that was true when
  written and is no longer, which is exactly why a "this is fine" note needs
  re-verifying like any other claim. It costs memory on every launch.
- ⚠️ **`probe-telnyx-connection` has 18 modes, not the 16 documented** — the
  two missing from the telephony rules are `messaging_profile` (reads back the
  messaging profile, including `daily_spend_limit`, $20.00/day account-wide)
  and `p2p` (WRITES: switches one number to P2P via `ensureP2P`, 2026-09-24).
  Re-count with `grep -c 'body.probe ===' supabase/functions/probe-telnyx-connection/index.ts`
  (17 on 2026-09-24) plus the default `connection_id=` read.
- ⚠️ **`countries.observed_*` is NOT provider-scoped** and still counts orders
  from retired providers. Third element of the steering key, so the blast radius
  is small — but it will recur wherever that column is read.
- ⚠️ **Migration drift: a fresh deploy would NOT reproduce production.** Dozens
  of recorded versions have no local file and vice versa; `db push` remains
  broken. Recover by writing each missing version out of
  `schema_migrations.statements` — do NOT mark anything reverted.
- ⚠️ **`sync-5sim` takes ~10 HTTP 429s per run.** The retry rescues almost all,
  but a country lost for an hour reads as "5sim does not serve it". Watch
  `fetch_faults`; do not add parallelism.
- ⚠️ **No test suite.** Of ~20 changes made in one day, **six were regressions
  introduced that same day**, two caught only by luck. Assume a similar rate.
- ⚠️ **The HeroSMS and Telnyx API keys both passed through chat transcripts and
  should be rotated.** They live only as Supabase secrets and are in no commit.

## Copy rules — never quote a number the server owns

⚠️ **Onboarding may never quote a credit amount.** Got wrong twice, both times
shipping to users. The screen runs **before sign-in**, so it cannot read
`app_config` even if we wanted it to, while the grant is a server value that
changes with no release — it has been 0, 1, 2, 3 and 5. Any number there is a
promise the server has not agreed to keep.

**The same rule killed a second constant**: `AppState.inviteJoinerCredits` was
the deliberate SUM of two grants — correct the day it was written, a 150%
overstatement the moment one of them changed. **A client constant derived from a
value the server changes without a release cannot be kept honest.** When a grant
amount moves, grep for every client constant derived from it.

**And the ops channel had it too.** `telegram-notify` rendered "N free credits
granted" from a `wallet_transactions` lookup — but no row is written when the
bonus is 0, so at a grant of 0 *every* signup alert claimed a credit was
granted. **A MISSING row means the grant did not happen, not that its size is
unknown.** To answer "did this user get a bonus?", use `signup_grants`, which
survives Delete Account; `wallet_transactions` cascades, so a deleted account
looks identical to one that was never granted.

## Error UX rule

Never display raw API errors. AppState's catch blocks call
`APIError.userMessage`, which maps known business-logic codes to plain English.

**Keep the Swift map and the backend codes in sync.** The backend was once
renamed to emit `provider_unreachable` while `APIError` still matched only the
old code, so a third-party outage fell through to the 5xx fallback and blamed
our own infrastructure. **When you add or rename an `{ error: "..." }` literal
in any edge function, add the matching case in `Networking/APIError.swift` in
the same commit.**

## When iOS data looks wrong, check in this order

1. **Force-quit the app.** The catalog is cached per launch, so any reprice you
   just ran will not show until a cold start. **Most "wrong price" reports are
   this.**
2. **Xcode console for catalog decode errors.** A field missing from the Swift
   model is dropped **silently** by `.convertFromSnakeCase` rather than erroring
   — that is how the eSIM SIM PIN sat in the database for a day.
3. **`curl` PostgREST directly.** Check the row **count** too, not just the
   shape (see the `max_rows` truncation gotcha).
4. Function logs in the Supabase dashboard.

## ASO

Moved to the `aso-listing` skill. **Search is the app's ENTIRE acquisition
channel** — invoke it before touching the listing, keywords or screenshots.

🔴 **RATINGS CAP SEARCH POSITION, AND THE APP HAS 8 — SIX OF THE SEVEN WRITTEN
REVIEWS ARE THE OWNER'S FRIENDS** (owner, 2026-09-11). The only organic review
is the DEU 1★, from a user who never received a code and was therefore never
prompted. **No prompt→rating rate has ever been measured in this product**; the
"~43%" once quoted was those friends. Re-read the count with
`python3 scripts/app-ratings.py` (no auth; ASC's `customerReviews` shows only
*written* reviews and cannot see a silent star) — never quote the 8.

✅ **The review prompt was rebuilt 2026-09-11 and it could not fire at all
before that.** From 2026-08-19 it was gated on a UserDefaults stamp written
only by a list diff that no real delivery ever reached, while 215 users
received codes. It is now DERIVED from `Order.arrivedAt`, fires from two arms
(cold launch + foreground) after a calm dwell, and emits
`review_prompt_eligible` / `_blocked` / `_requested`.

🔴 **FIRST READ-OUT, 2026-09-16: the rebuilt prompt asked ONE person, ever, and
the gate that swallowed it was `suppressReviewThisSession`.** Over the prior 30
days `review_prompt_blocked{paywall_session}` was **73 of 114 blocks** (6 users)
against `review_prompt_requested` **1** (1 user), while `app-ratings.py` read 8
— unmoved from the 09-11 baseline. The cause is a premise that broke under the
code rather than a coding error: the no-prompt-in-a-paywall-session rule assumes
"saw a paywall" means "was refused something", and **the signup grant went to 0
on 2026-09-10**, so every user now opens `CreditsSheet` before their first code
and every SUCCESSFUL session contained a paywall. Fixed 2026-09-16 — a
successful credit purchase lifts the suppression, a cancelled one does not, and
only the surface that set the flag may lift it. Detail, and the
`cooldown`-before-`paywallSession` ordering that now keeps it safe, in
`.claude/rules/ios-client.md`. ⚠️ Ships in the next release and is UNREAD; it
removes a blocker, it does not by itself produce ratings.

🔴 **`reviewCalmFloorHours` is also 0 now (owner, 2026-09-16) — the 2-hour calm
floor is OFF and the 8-second dwell is the only timing gate left.** A floor in
HOURS required a return visit and this product is disposable: 20 of the 185
users who received a code in 30 days came back at all, and `too_soon` blocked 22
times across 4 of the 6 users the gate ever evaluated. It is not a return to the
rushed moment — `scheduleReviewPrompt` has only two arms (cold launch,
background→foreground), so the ask lands on the user's NEXT return, and a user
whose code failed is inside a flow by then and blocks on `.flowActive`.
⚠️ Accepted risk: a code arriving is not the verification succeeding. Reverse
with a floor of 10–30 MINUTES if `app-ratings.py` shows the AVERAGE falling.

⚠️ **The real ceiling right now is ADOPTION, not the gates.** Of the 185 users
who received a code in the 30 days to 2026-09-16, only **9** were on a build
that can emit the prompt at all (2.13+), so the addressable pool is ~9/month
until 2.13/2.14/2.15 adopt. Re-derive before judging either constant:
```sql
select count(distinct user_id) from app_events
 where name='home_view' and created_at > now()-interval '30 days';
```

🔴 **It covers ALL THREE products only from 2026-09-14 — a line subscriber
could never be asked before that**, because eligibility guarded on a temp
SMS/e-mail code and the two audiences have never overlapped (19 subscribers,
one temp order, zero codes between them). So the count of subscribers ever
eligible was **zero**, while subscriptions became the larger half of the
revenue, and the only cohort that COULD be asked was temp SMS — which fails
~78% of the time per order. `AppState.lastSuccessMoment` is now the one
eligibility input, adding `my_line.last_success_at` (migration
`20260914194532`: an inbound SMS, or any call that connected ≥10s in EITHER
direction — outbound counts, owner 2026-09-14). **Ships in 2.15; 2.14 and
older ask only temp users.** Reads out on `review_prompt_*` `props.surface` ∈
`sms` · `email` · `line`. Detail in `.claude/rules/ios-client.md`. Full detail — including
the two rules that make it safe, *never reintroduce a delivery stamp* and
*ask first, consume second* — is in `.claude/rules/ios-client.md`, "The review
prompt". ✅ **Ships in 2.13 build 63** (submitted 2026-09-11); 2.11 and 2.13
build 62 do not carry it. Nothing has been read out yet — run
`python3 scripts/app-ratings.py` regularly starting NOW, because Apple gives no
attribution for a rating and an interrupted time series is only a read-out if it
begins before the change reaches users.

The live name is `vSMS: Second Number & Temp SMS` / subtitle **`USA Phone Line
& Verification`**, in all 13 locales — localized, so de-DE is `USA-Nummer &
SMS-Code`, fr-FR `Ligne USA & SMS temporaire`, it `Linea USA e SMS temporanei`.
The USA token shipped with **2.10 (2026-09-06)**.

🔴 **THE LIVE en-US FIELD IS NOT THE ONE BELOW. 2.14 dropped `email` and added
`sim` and `usa` by hand** (read from ASC 2026-09-15; the field is stored per
version, so `scripts/asc-keywords.py`-style reads recover the whole history):

```
2.0–2.11  email,virtual,disposable,temporary,online,otp,code,inbox,fake,spam,signup,burner,text,call,receive
2.13      email,virtual,disposable,temporary,online,otp,code,burner,mail,verify,receive,text,call,2nd,get
2.14      sim,virtual,disposable,temporary,online,otp,code,burner,mail,verify,receive,text,call,2nd,get,usa
```

That edit matches no approval and appears in no document, and it is a
regression on two counts. **`usa` bought nothing** — the subtitle has carried
`USA Phone Line & Verification` since 2.10 and Apple indexes name + subtitle +
keywords as ONE pool, which is exactly what `asc-keywords.py`'s own header
says. And the characters for it came out of **`email`**, so `temporary email`
(popularity 71, difficulty 52 — a *good target*) and `disposable email` stopped
being formable in the storefront that is **64% of all revenue**, while
temp-email is roughly half of all order volume. vSMS is measured **outside the
top 182** for `temporary email` in en-US on 2026-09-15.
🔴 **US SEARCH IMPRESSIONS STEPPED DOWN ~37% ON 2026-09-11/12 AND HAVE BEEN
FLAT SINCE — measured at Apple, not inferred (2026-09-18).** Signups fell from
≈49/day (08-19→09-10) to ≈28/day (09-13→09-17). Apple's own daily reports put
the loss upstream of the product page: **US search impressions ran ≈1,709/day
through 09-10 and ≈1,079/day from 09-11 on**, and the US is ~90% of all
impressions. First-time installs fell 50/day → 38/day. The rates BELOW the
impression held or improved (page-views-per-impression ~4%, installs-per-page-
view up), so the product page and the app are not what changed. It is a **step
change, not a slide**: every day from 09-11 to 09-17 sits in a flat 921–1,184
band.

The step lands on the keyword rewrites. First-time downloads per version date
the releases exactly (`asc-analytics.py versions`): **2.13 live 09-12, 2.14
live 09-13, 2.15 live 09-16.** ⚠️ The US fall begins **09-11**, the day the 13
localized fields were written to the 2.13 record but a day BEFORE 2.13 reached
anyone — so either Apple re-indexes on the metadata edit rather than the
release, or the 09-11 timing is coincidence. Not resolved; do not state the
mechanism as known.

⚠️ **This supersedes a much larger claim that was wrong, and the way it was
wrong is the lesson.** An earlier pass reported impressions falling 6,200/day →
1,244/day with Europe "wiped out" 90–100%. Both were artifacts:

- 🔴 **An analytics instance holds a ROLLING 3-DAY WINDOW (processingDate D
  carries D-1, D-2, D-3), so summing the files counts a settled day three
  times and the newest day once.** That alone manufactured a ~3× cliff out of
  flat data. `asc-analytics.py` now keeps each data date from the newest
  instance that contains it and prints the last two days as `PROVISIONAL` —
  those read LOW until two more instances land, so **never call the last row a
  trend**.
- 🔴 **Europe never had traffic to lose.** SE, NL, DK, FI, NO, PL, IE and the
  rest run at **≈28 impressions/day COMBINED** and did before and after. What
  the "collapse" actually measured was a **two-day spike on 09-11/09-12 —
  ≈2,490 and ≈1,640 EU impressions, against ~28 either side** — sitting inside
  the "before" window. Comparing against it made a normal week look like a
  wipeout.

✅ **That spike is the most interesting unexplained thing in the data, and it
is a LEAD, not a loss.** It was genuine App Store search (not browse) and it
converted: **54 page views and 25 first-time installs on 09-11, 13 more on
09-12**, against ~1 install/day from Europe normally. Two days produced ~38 EU
installs. Nothing in this repo explains it — the localized keyword fields were
applied to the 2.13 record on 09-11, but 2.11's own fields were never
overwritten (read them back per version; they still hold the old tokens).
**If it can be reproduced it is a bigger prize than recovering the US step**,
because the European fields have otherwise bought essentially nothing.

🔴 **The next move is to STOP EDITING and let it settle.** 2.16 carries 2.15's
field unchanged, which is correct. Three rewrites in five days (2.13, the 2.14
en-US hand-edit, 2.15) is why nothing here can be attributed cleanly; a fourth
would extend that. 2.15 restored `email`, `mail` and `inbox` to en-US on 09-16
— whether the US step recovers is the open question, and it needs several
SETTLED days, not the provisional tail.

⚠️ **One secondary signal, unconfirmed: signups per install fell ≈0.97 →
≈0.73** across the same break. If real it is a first-run regression rather than
a discovery one, and 2.13's Home tab and 2.14's delivery explainer are the
candidates. It may equally be install/signup date skew across timezones and the
provisional tail. **Check it before acting on it.**

Re-derive all of it — these numbers move daily:
```bash
python3 scripts/asc-analytics.py daily                  # impressions -> page views -> installs
python3 scripts/asc-analytics.py territory 2026-09-13   # PASS THE PIVOT (see the script)
python3 scripts/asc-analytics.py versions               # when each version actually went live
```
Plan and earlier evidence:
`docs/superpowers/specs/2026-09-15-organic-acquisition-design.md`.

✅ **This drift is now DETECTED, since 2026-09-15** —
`python3 scripts/asc-listing-check.py` diffs the live field in every locale
against `asc-keywords.py`'s approved list and exits 1 on any disagreement. It
currently reports exactly this one finding. 🔴 **It never writes, and neither
should you reflexively**: a disagreement may mean the SCRIPT is stale rather
than the listing, so decide which is right and make them agree in one commit.

✅ **APPLIED to 2.13 on 2026-09-11** (owner-approved), all 13 locales, read back
13/13 matching, and submitted with build 63. Keywords ship only with a release,
so they take effect when 2.13 is approved — **nothing about ranking can be read
before then**, and Apple exposes no per-query search terms, so attribution is
before/after inference over 7–14 days. Re-apply with
`python3 scripts/asc-keywords.py --apply` (dry-run by default; it REFUSES to
write to a version already in review, and reads back). en-US, 95/100:

```
email,virtual,disposable,temporary,online,otp,code,burner,mail,verify,receive,text,call,2nd,get
```

⚠️ **`usa` is NOT in it, deliberately — and this file used to call its absence
the app's big ASO gap. That was wrong.** Apple indexes **name + subtitle +
keyword field as ONE pool**, and the subtitle has carried `USA Phone Line &
Verification` since 2.10 — so `usa`, `phone`, `line` and `verification` are
already indexed, and repeating any of them here wastes characters. Same for
`second` and `number`: they are in the NAME, the highest-weight field. (The
`it` field's `usaegetta` is Italian for *usa e getta*, "disposable", and is one
token — a false positive for any `usa` grep.)

Three facts behind the list, none derivable from the code:
- 🔴 **Apple does not substring-match.** `email` does not answer a search for
  "mail"; `verification` does not answer "verify". Each is a separate purchase.
  **`mail` was the missing token**: "temp mail" is popularity **82** — higher
  than "second number" (72) — and was UNFORMABLE despite `Temp` being in the
  app name.
- 🔴 **The app has 8 ratings (2026-09-11), and ratings cap position.** So the
  second-number cluster is not bought here at any price: "second phone number"
  is popularity 92 but its top results are TextNow (**919k** ratings), Text
  Free (602k) and Text Me (672k). The verification cluster is winnable — its
  leaders have 10, 46, 153 and 2,800 ratings. Scored via `aso-connect`, us
  storefront, 2026-09-11.
- ⚠️ **`burner` is in at the owner's explicit instruction, against the
  scoring** (pop 61 / difficulty 67, Burner.app at 93k ratings), displacing
  `inbox`. Note the owner separately PAUSED `burner` as an ASA keyword on
  2026-09-07 for drawing two-way-texting intent the product cannot serve. Paid
  and organic are different calculus — do not "fix" one to match the other.

✅ **ALL 13 LOCALES ARE WRITTEN** (2026-09-11), each scored in its own
storefront, each checked against its OWN name+subtitle. The script holds them;
this is the summary:

| locale | field | len |
|---|---|---|
⚠️ **The table below is the 2026-09-11 set and it is SUPERSEDED.** A full
per-storefront re-score on 2026-09-15 replaced all 13 fields; they are STAGED
in `scripts/asc-keywords.py` (run it for a dry-run print) and ship with the
next version. Headlines: **no shared `EN` constant any more** (the four English
storefronts diverge because their difficulty does); **`ru` and `ar-SA` go
NATIVE**, because a Latin field cannot match a Cyrillic or Arabic query and
those two were therefore buying nothing at all; **de-DE gains
`telefonnummer`**, unlocking `zweite telefonnummer` 78/50 at opportunity 39 —
the best score in any locale, against beatable incumbents (2Number 3,006).
Dropped for cause: fr `activation` (top result is an AI-chat app) and `boite`
(returns temp-work agencies — *boîte* reads as "firm"), pt-BR `correio`
(popularity **10**) and `caixa` (65/**78**), it `spam` (anti-spam blockers) and
`numeri` (completes nothing without the plural adjective), ja `テンポラリ`
(popularity **1**, one result, which is vSMS) and `ワンタイム` (bank token apps).
🔴 **`sms activate` measures 62/54 and is deliberately NOT bought** — it is a
competitor's name, so the supplier rule and 2.3.7 both bite.

| locale | field (SUPERSEDED — see above) | len |
|---|---|---|
| en-US/GB/CA/AU, ru, ar-SA | `email,virtual,disposable,temporary,online,otp,code,burner,mail,verify,receive,text,call,2nd,get` | 95 |
| fr-FR | `recevoir,mail,verification,virtuel,jetable,deuxieme,code,email,otp,temp,boite,activation` | 88 |
| de-DE | `virtuelle,empfangen,verifizierung,zweite,mail,email,wegwerf,handynummer,online,otp,trashmail` | 92 |
| es-ES, es-MX | `correo,recibir,virtual,verificacion,codigo,desechable,email,online,otp,mail,falso,movil` | 87 |
| it | `mail,temporanea,temporaneo,virtuale,verifica,ricevere,codice,email,getta,ricevi,numeri,spam` | 91 |
| pt-BR | `correio,receber,virtual,verificacao,codigo,descartavel,email,online,otp,mail,caixa,falso` | 88 |
| ja | `仮想,ワンタイム,メール,一時的,スパム,テンポラリ,迷惑メール,登録` | 35 |

🔴 **A field cannot be copied between locales** — each name+subtitle indexes a
different set, so the wasted-duplicate list differs. `Nummer` is in the de
subtitle, `temporaire` in the fr one, and **`temporanei` in the it one is
PLURAL and does NOT cover `temporanea`/`temporaneo`**, which is why both
singulars are bought there.

🔴 **The US-number angle does not sell in Europe.** `numero americain` (fr)
scores 34 popularity / 57 difficulty and `numero americano` (es) scores **3**.
The European fields buy verification and temp-mail intent instead — which is
also where the Sweet Spots are: `mail temporanea` (it) 59/31 is the single
best-scoring term in any locale, `correo temporal` (es) 53/26, `mail
temporaire` (fr) 58/34, `sms verifizierung` (de) 42/29.

⚠️ **`ja` is the least confident field.** Apple segments Japanese
morphologically, so a comma-split duplicate check cannot prove a token is free
— `使い捨て` was caught only by substring against the NAME. Kept deliberately
short. ⚠️ **`ru` and `ar-SA` get the ENGLISH field** because their name and
subtitle are English on this listing; a native field would beat both, but
neither is a real market yet.

✅ **Promotional text is SET in all 13 locales on BOTH the live version and the
editable one (2026-09-11)** — "One app, three jobs: a real US number you keep
for calls and texts, temp numbers for sign-up codes, and temp email addresses.
No SIM, no contract.", localized to each locale's subtitle tone. Written and
read back by `scripts/asc-promotional-text.py` (dry-run by default, `--apply`
to write). Three properties that are not derivable from the code:

- 🔴 **It is the ONLY listing field that changes WITHOUT review**, because it
  is editable on the `READY_FOR_SALE` version and lands on the live product
  page in minutes.
- 🔴 **So writing it ONLY on the in-review version means nobody sees it** until
  that version ships — which is exactly what happened here before the fix.
  **Write BOTH**: the live one to be visible now, the editable one because a
  new version does NOT inherit it once its localizations already exist.
- ⚠️ **It is NOT indexed by Apple Search.** Name, subtitle and the 100-char
  keyword field are; this is not. It is a CONVERSION lever on the product page
  (tap→install, currently 68.4%), never a ranking lever — **do not spend
  keywords here.**
- ⚠️ Accents ARE written in this field, unlike the keyword field which strips
  them for indexing. It is display copy. And **no price claim may appear in
  `en-US`**: it is the fallback locale for NL/SE/DK/NO/FI/PL, so a "$3.99"
  there renders in Sweden.

🔴 **NO LISTING FIELD MAY QUOTE A PRICE — release notes and description
included, in EVERY locale, not just `en-US`** (2026-09-11). The rule above was
written for promotional text; the mechanism is a property of the listing, so it
binds all of them, and stating it narrowly let a live example through. Every one
of the twelve 2.13 release notes that mentioned the intro offer quoted it in
**dollars**: fr-FR, de-DE, it and es-ES said "3,99 $" where Apple bills €3.99;
`ja` said "$3.99" where Japan is billed **¥600**; pt-BR said "US$ 3,99" against
**R$24.9**. Corrected before build 63 went out — the claim stays, the numeral is
gone ("costs less for your first month"), and the real figure is rendered by
StoreKit on `LineCheckoutScreen` and again on Apple's sheet, localized and
correct in both.

This is the listing-side instance of the rule the code already follows twice
over — *never hardcode a price*, *never quote a number the server owns*. The
pack ladder drifted to $4.99-vs-€5.99 on its top product for the same reason,
and **the app's only organic review is a 1★ saying the price rose overnight**.
✅ **ENFORCED since 2026-09-15 — run it before every submission:**

```bash
python3 scripts/asc-listing-check.py     # exits 1 on any finding
```

It scans `description`, `whatsNew` and `promotionalText` on the version, plus
`name` and `subtitle` at the app level, in EVERY locale, for `[$€£¥₹₦₺₪₩฿₫]`
and for `USD/EUR/GBP/JPY/INR/US$`. Verified against the five strings that
actually shipped wrong in 2.13 — it catches all five and stays silent on clean
copy. ⚠️ **A written invariant is not an enforced one**, which is the whole
reason this exists: the rule below was in this file while twelve locales
violated it.

⚠️ **The fallback language is the app's PRIMARY locale, `en-US`, not en-GB**
(`GET /v1/apps/6774768570` → `primaryLocale`). GB and IE resolve to `en-GB`;
every storefront with no listing locale — NL, SE, DK, NO, FI, PL — resolves to
`en-US`. The two keyword fields differ in load-bearing tokens: `receive` is in
en-US and **not** in en-GB. There is no `nl` locale at all.

**Rebrand trigger:** a non-SMS line exceeds **40% of monthly net for two
consecutive months** (read from `/profit` once it includes subscriptions — it
does not yet). The in-app display name, icon and onboarding can change per
release without touching the indexed store name; the store name cannot hold an
umbrella brand AND both SMS terms.

## Release prep

Moved to the `release-prep` skill — the headless ASC pipeline, the beta-macOS
`BuildMachineOSBuild` patch for ITMS-90111, and the in-app-purchase review rules
(including the one-way-door cancel).
