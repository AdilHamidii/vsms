# Design Overhaul — Plan 2: My number (store, paywall, subscriber home, drill-ins)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the My number tab so it looks like Verify, sells the number honestly, and gives a subscriber their number, messages and calls without a misplaced button: tokens and one-green everywhere, the false Canada claims removed, an inline store with a ✓/✗ ledger and a StoreKit price row, a D4 paywall, a subscriber home (title, number card with a compact **Switch** capsule, Messages · Calls · Number segments, no FAB), the §3a motion pass, and thread/compose pushed on a `NavigationStack`.

**Architecture:** `LineScreen` becomes a `NavigationStack(path: $state.linePath)` whose root is either the store (`LineStoreScreen`) or the subscriber home (`LiveLineView`). Pushed destinations are one enum, `LineRoute` (`countries`, `cities`, then `thread(id)`, `compose`), registered once by `.lineRouteDestinations()`; the "Rent another number" cover (`.lineStoreMore`) hosts the same store in its own stack (`LineStoreCover`). The paywall, provisioning and dialer stay `fullScreenCover`s driven by `state.flow`; `FlowStage.thread` and `.compose` are deleted. A line-SMS push goes through `AppState.openLineThread(_:)` (closes any cover, selects `.line`, pushes the thread). The gear's settings sheet is replaced by the Number segment. No backend change.

**Tech Stack:** SwiftUI (iOS 18: `NavigationStack(path:)`, `Group(subviews:)`, `containerBackground(_:for:)`, symbol effects, `matchedGeometryEffect`), `@Observable` `AppState`, StoreKit 2 via `SubscriptionStore`, String Catalog via `scripts/xcstrings-add.py`, Python 3 + Pillow for background sampling.

**Spec:** `docs/superpowers/specs/2026-09-24-my-number-overhaul-design.md` (the authority; §4.5 as revised by the owner the same day: a compact "Switch" capsule beside the number). Parent: `docs/superpowers/specs/2026-09-24-design-overhaul-design.md` §2, §5, §7. Audit: `docs/design-overhaul/my-number-audit.md` (file:line inventory, §4 load-bearing checklist).

**This is plan 2 of several.** Plan 1 (foundation) has landed. Guest mode is a later plan: this plan only guards the store's number search on a session (Task 3) and leaves the sign-in sheet to that plan.

**Fixture placement.** Spec §8 puts fixtures in step 7. A task cannot verify a screen it cannot capture, so each new fixture case lands in the task whose screen it proves (the task lists it under **Files**). Task 7 captures the full set in both appearances, samples every background and updates the docs. Four fixtures go beyond spec §7, and each one exists to verify a named risk: `lineStoreError` (risk 2), `lineInboxMulti` (Review Focus 3), `lineInCall` and `linePushThread` (risk 1, spec §9).

## Global Constraints

- **Backend untouched.** `git diff main --stat -- supabase` prints nothing before every commit. No new endpoint, column, config key or `app_config` whitelist change.
- **Onboarding untouched.** `git diff main --stat -- VirtualSIM/Onboarding` prints nothing.
- **iOS 18.0 minimum.** Anything iOS 26-only goes behind `if #available(iOS 26, *)` with a working 18 path. (`Group(subviews:)`, `containerBackground(_:for:)`, `.symbolEffect(.bounce)` and `.contentTransition(.symbolEffect(.replace))` are all iOS 17/18 APIs.)
- **The only build check** is:
  ```bash
  xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10
  ```
  It must end `** BUILD SUCCEEDED **`. `swiftc -typecheck` is retired. `VirtualSIM/Networking/Secrets.swift` is already in this worktree. `VirtualSIM/` is a synchronized root group: a new `.swift` file under it is compiled without touching the project file.
- **Strings.** Every user-facing string is `Text("literal")` or `String(localized:)`. A new key goes into `VirtualSIM/Localizable.xcstrings` in de (Sie), es (tú), fr (vous), it (tu), ja (polite) and pt-BR (você) **in the same commit**, through `python3 scripts/xcstrings-add.py <file.json>`. Before running it, drop keys that already exist so existing translations are not overwritten:
  ```bash
  python3 -c "import json,sys;s=json.load(open('VirtualSIM/Localizable.xcstrings'))['strings'];print([k for k in json.load(open(sys.argv[1])) if k in s])" /tmp/p2-tN.json
  ```
  Interpolation makes the key: an `Int` becomes `%lld`, a `String` becomes `%@`. The key's punctuation must match the Swift literal byte for byte (the em dash is ` — `, U+2014 with spaces; the middle dot is ` · `, U+00B7). No interpolated pluralised nouns in NEW keys.
- **Vocabulary.** The product is "Your own number" (store title) and "My number" (tab and subscriber title). The swap is "Switch": the capsule reads "Switch", its accessibility label and the Number-segment row read "Switch number" / "Switch number…". "Change number" leaves the UI by the end of Task 5.
- **No supplier named** in any string, comment-free literal or fixture (no Telnyx, 5sim, HeroSMS).
- **No hardcoded server-owned number or StoreKit price.** Prices come only from `SubscriptionStore` (`monthlyPriceDisplay`, `yearlyPriceDisplay`, `monthlyIntroPriceDisplay`, `selectedIntroPriceDisplay`, `trialLabel`); the swap price only from `state.appStatus.lineSwapCredits` with **no client default** (nil hides the Switch control). `LineProduct.voiceAllowanceMinutes` is the one sanctioned client mirror (a schema default that changes by migration, see its doc comment) and is used only where it is used today, on the paywall.
- 🔴 **The US/PR rule.** `LineStoreScreen.unreliableSendingCountries` stays the ONE list. The US/PR texting warning must stay on screen (checkout `capabilityNote`, uncollapsed on US/PR). **If any change removes it, `force_block` US and PR in the same commit** (CLAUDE.md; the migration `20260917090000` carries the SQL). This plan never removes it.
- **No plan or renewal talk on this tab** (owner, 2026-09-01, re-confirmed 2026-09-24): no renewal date, no "Manage subscription", no plan card anywhere under `LineScreen`. The paywall's 3.1.2(a) renewal sentence is the one exception, because the paywall is the purchase screen. (The Calls footer shows no reset date: it is the renewal date. See the note in Task 5.)
- **Motion.** Every new animation uses `RMotion.standard` or an existing `RMotion` token and is skipped under Reduce Motion, through `RMotion.unlessReduced(_:_:)` (added in Task 3) or a view that reads `@Environment(\.accessibilityReduceMotion)`.
- **Fixture code.** `ScreenshotMode.screen` and `ScreenshotMode.isActive` exist in every build. `ScreenshotMode.sample*` exists only under `#if DEBUG`, so any line referencing it outside `ContentView.applyScreenshotState` must itself be inside `#if DEBUG … #endif`, or the Release build fails.
- **Sheets and covers** do not inherit `@Observable` environment objects. Sheet content is wrapped in `LineEnv(...)` or given explicit `.environment(...)`; covers go through `EnvBundle` in `ContentView`. A `NavigationStack` root or pushed page needs `.containerBackground(theme.bg, for: .navigation)`, or dark mode renders pure black.
- **Commit messages end with:**
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01G3g3LLutZtZy4JEkaSwpfD
  ```
- Run every command from the worktree root `/Users/adyl/Desktop/IOS_APPS/VirtualSIM/.claude/worktrees/design-overhaul`. Never touch the "Mavira Shots 6.9" simulator.

### Verification kit (create once; every task uses it)

If `/Users/adyl/.claude/jobs/c5c3d119/tmp/p2-shots.sh` or `p2-loadbearing.sh` does not exist, create them exactly as below. They live in the scratch directory, never in the repo.

**`/Users/adyl/.claude/jobs/c5c3d119/tmp/p2-shots.sh`** — builds into the private DerivedData, installs, captures each fixture in dark and light, and samples the background (`#0A0A0C` dark, `#F6F5F2` light) at x = 12 px (4 pt, inside the 16 pt gutter), half height.

```zsh
#!/bin/zsh
# usage: zsh p2-shots.sh <fixture> [<fixture> ...]
WT=/Users/adyl/Desktop/IOS_APPS/VirtualSIM/.claude/worktrees/design-overhaul
SIM=787A6027-0A86-4AE0-9412-C99DCF4CE992
DD=/Users/adyl/.claude/jobs/c5c3d119/tmp/dd
APP=$DD/Build/Products/Debug-iphonesimulator/VirtualSIM.app
OUT=/Users/adyl/.claude/jobs/c5c3d119/tmp/p2
BID=com.anthersystems.VirtualSIM
mkdir -p $OUT
cd $WT
xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath $DD build 2>&1 | grep -E "(error:|BUILD)" | tail -3
xcrun simctl boot $SIM 2>/dev/null
xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $APP
for f in "$@"; do
  for mode in dark light; do
    xcrun simctl terminate $SIM $BID 2>/dev/null
    xcrun simctl launch --stderr=$OUT/$f-$mode.log $SIM $BID \
      -screenshot $f -pref.appearance $mode >/dev/null
    sleep 6
    xcrun simctl io $SIM screenshot $OUT/$f-$mode.png >/dev/null 2>&1 && echo "shot $f-$mode"
  done
done
python3 - "$OUT" "$@" <<'EOF'
import sys
from PIL import Image
out, names = sys.argv[1], sys.argv[2:]
want = {"dark": (0x0A, 0x0A, 0x0C), "light": (0xF6, 0xF5, 0xF2)}
bad = 0
for n in names:
    for mode in ("dark", "light"):
        im = Image.open(f"{out}/{n}-{mode}.png").convert("RGB")
        w, h = im.size
        px = im.getpixel((12, h // 2))
        ok = px == want[mode]
        bad += 0 if ok else 1
        print(("ok  " if ok else "BAD ") + f"{n}-{mode} bg #{px[0]:02X}{px[1]:02X}{px[2]:02X}")
sys.exit(1 if bad else 0)
EOF
```

After a run, open each PNG with the Read tool and check it against the task's **Expected** list. `lineInCall` is the one fixture whose half-height pixel may be covered by the call screen's own `theme.bg` (it is the same colour, so it still passes).

**`/Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh <task>`** — the audit §4 checklist as greps. `<task>` is `1`, `2`, `3`, `4`, `5`, `5a`→`5`, `6` or `7`; checks that only become true at a later task are gated on it.

```zsh
#!/bin/zsh
# usage: zsh p2-loadbearing.sh <task number, 1-7>
cd /Users/adyl/Desktop/IOS_APPS/VirtualSIM/.claude/worktrees/design-overhaul
T=${1:-7}; fail=0; S=VirtualSIM/Screens
has()     { if grep -rqF -- "$2" "$1"; then echo "ok       $3"; else echo "MISSING  $3"; fail=1; fi; }
hasnt()   { if grep -rqF -- "$2" "$1"; then echo "PRESENT  $3"; fail=1; else echo "ok       $3"; fi; }
atleast() { n=$(grep -rF -- "$2" "$1" | wc -l | tr -d ' ')
            if [ "$n" -ge "$3" ]; then echo "ok       $4 ($n)"; else echo "MISSING  $4 ($n < $3)"; fail=1; fi; }

has $S/LineStoreScreen.swift 'static let unreliableSendingCountries: Set<String> = ["US", "PR"]' "one US/PR list"
atleast VirtualSIM 'LineStoreScreen.unreliableSendingCountries' 2 "list read by checkout + thread"
[ $T -ge 2 ] && atleast VirtualSIM 'LineStoreScreen.unreliableSendingCountries' 3 "list read by checkout + thread + swap"
has $S/LineCheckoutScreen.swift 'if sendingWarningShown' "checkout US/PR note, uncollapsed"
[ $T -ge 2 ] && has VirtualSIM "Texts you send to US numbers usually don't arrive." "ledger ✗ row"
[ $T -ge 2 ] && hasnt VirtualSIM/Screens "A Canadian number sends texts reliably" "Canada claim removed"
[ $T -ge 2 ] && hasnt VirtualSIM/Screens "from a Canadian number arrive normally" "Canada branch removed"
has $S/LineCheckoutScreen.swift 'Terms of Use (EULA)' "EULA named"
has $S/LineCheckoutScreen.swift 'Privacy Policy' "Privacy Policy named"
has $S/LineCheckoutScreen.swift 'iap.restorePurchases()' "Restore on the paywall"
has $S/LineCheckoutScreen.swift "This number can't call 911 or any emergency service." "911 on the paywall"
has $S "This number can't call 911 or any other emergency service." "911 in Number settings / segment"
has $S/DialerScreen.swift "This number can't reach emergency services." "911 in the dialer"
has $S/LineCheckoutScreen.swift 'Good to know' "Good to know on the paywall"
has $S/LineCheckoutScreen.swift 'private enum CheckoutVisit' "CheckoutVisit static"
has $S/LineCheckoutScreen.swift 'guard state.flow != .lineCheckout else { return }' "exit guard"
has VirtualSIM/IAP/SubscriptionStore.swift 'isEligibleForIntroOffer' "intro eligibility gate"
has $S/LineProvisioningScreen.swift "Please don't subscribe again." "provisioning failure copy"
has $S/LineScreen.swift "Resubscribe and we'll set you up with a new one." "suspended banner never promises the number back"
has $S/LineSwapSheet.swift 'is given up for good' "swap: given up for good"
has $S/LineSwapSheet.swift 'Your balance' "swap: balance on confirm"
has $S/LineSwapSheet.swift '.environment(iap)' "swap: IAPStore into CreditsSheet"
has $S/LineSwitchNumberButton.swift '.environment(iap)' "swap sheet gets IAPStore"
has $S/LineSwitchNumberButton.swift 'lineSwapCredits' "Switch hidden without a server price"
has $S/LineSwitchNumberButton.swift 'line.status == .active' "Switch hidden unless active"
atleast VirtualSIM/ContentView.swift 'InCallOverlay()' 2 "InCallOverlay root + cover copies"
has VirtualSIM/ContentView.swift 'if calls.isLive, state.flow == nil' "root call overlay scoped to no cover"
atleast $S 'isVoiceAvailable' 3 "voice gates (keypad, call-back, thread call)"
for e in line_store_view line_numbers_shown line_place_changed line_number_picked \
         line_checkout_view line_plan_selected line_checkout_exit line_purchase_result \
         line_provisioned voice_login_failed voice_push_handoff_failed line_swap_open \
         line_swap_numbers_shown line_swap_number_picked line_swap_confirm_view \
         line_swap_topup_shown line_swap_result line_upsell_shown line_upsell_tapped; do
  atleast VirtualSIM "\"$e\"" 1 "event $e"
done
if [ $T -ge 3 ]; then hasnt VirtualSIM '"line_choose_number_tapped"' "retired: line_choose_number_tapped"
else atleast VirtualSIM '"line_choose_number_tapped"' 1 "event line_choose_number_tapped (retires in T3)"; fi
for p in '"how"' '"seconds"' '"plan"' '"intro"' '"capability_note"' '"good_to_know_expanded"'; do
  has $S/LineCheckoutScreen.swift "$p" "line_checkout_exit prop $p"
done
[ $T -ge 5 ] && has $S/LineSwapSheet.swift '"from": .string(from)' "line_swap_open{from}"
if grep -nE 'Text\("[^"]*\$[0-9]' $S/Line*.swift $S/ThreadScreen.swift $S/ComposeScreen.swift $S/DialerScreen.swift; then
  echo "PRESENT  hardcoded price literal"; fail=1; else echo "ok       no hardcoded price literals"; fi
if grep -rniE 'Text\("[^"]*(telnyx|5sim|herosms)' $S VirtualSIM/Components; then
  echo "PRESENT  supplier named"; fail=1; else echo "ok       no supplier named"; fi
hasnt $S/LineStoreScreen.swift 'CoinIcon' "no credit pill on the store"
if [ $T -ge 5 ]; then
  for f in $S/LineScreen.swift $S/LineNumberSegment.swift $S/LineRecentsView.swift VirtualSIM/Components/LineNumberCard.swift; do
    if grep -nE 'Renews|renews|Manage subscription|manageSubscriptions|currentPeriodEnd' $f; then
      echo "PRESENT  plan talk in $f"; fail=1; fi
  done; echo "ok       no plan talk on the tab (T5+)"
  hasnt $S '"Change number"' "vocabulary: Change number gone"
fi
exit $fail
```

## Review Focus

1. **A US or PR number.** The store's ✗ row ("Texts you send to US numbers usually don't arrive.") shows for every country; the paywall's uncollapsed note shows on US/PR with the Canada sentence gone and `line_checkout_exit.capability_note` still reading the same `sendingWarningShown`; a failed send from a US/PR line shows the corrected sentence; a swap whose target country is US/PR shows the ✗ row on its confirm page. Pinned in **Task 2 Steps 4–6 and 10** (copy, swap ✗, `lineSwapConfirm` frame) and **Task 4 Steps 10–11** (`linePaywallUS` frame, top of the paywall, note uncollapsed; the exit event carries `capability_note`).
2. **No voice client.** The keypad toolbar button, the call-back glyph and tile in Calls, and the thread's call button are HIDDEN (never disabled) when `CallController.isVoiceAvailable` is false; the compose button is unaffected. Pinned in **Task 5 Step 12** (temporary local edit: attach no voice client, capture `lineCalls` and `lineInbox`, revert) and **Task 6 Step 9** (same edit, `thread` frame).
3. **A multi-line subscriber.** The line switcher `Menu` sits next to the number on the card with the elsewhere-unread badge; Messages/Calls filter to the selected line; a reply leaves from the THREAD's line (`openThreadId` is set before every send), a new message from the selected line. Pinned in **Task 5 Step 12** (`lineInboxMulti` frame) and **Task 6 Step 3** (`ThreadScreen.send` sets `openThreadId`; `ComposeScreen` clears it).
4. **A line in grace or past due.** The banner sits directly under the number card (silent when healthy), the Switch capsule and the "Switch number…" row are hidden (only `.active` swaps), the suspended copy still never promises the number back, and the composer shows its refusal reason. Pinned in **Task 5 Step 12** (`lineBanner` frame, past due) plus the load-bearing grep.
5. **The seller unavailable or paused, or the search failing.** The inline numbers never flash an error before the first answer (skeleton while `lineOffers` is empty with no reason), a failure shows the fail-tinted empty state with **Try again**, `lines_paused` shows the paused copy with no retry, a refused country offers another country, and a StoreKit that has not answered hides the price row (never a placeholder price). Pinned in **Task 3 Step 11** (`lineIntro` loading with no pricing shim, so the price row must be absent; `lineStoreError`; a temporary `.paused` edit).

---

### Task 1: Tokens pass across the line files (no layout change)

**Files:**
- Modify: `VirtualSIM/Screens/LineScreen.swift`, `LineStoreScreen.swift`, `LineCheckoutScreen.swift`, `LineRecentsView.swift`, `LineSettingsScreen.swift`, `LineSwapSheet.swift`, `LineProvisioningScreen.swift`, `ThreadScreen.swift`, `ComposeScreen.swift`, `DialerScreen.swift`, `InCallOverlay.swift` (all under `VirtualSIM/Screens/`)
- Modify: `VirtualSIM/Components/LinePickerRows.swift`, `VirtualSIM/Components/Buttons.swift` (the `sub` label only), `VirtualSIM/Sheets/PeerNameSheet.swift`
- Modify: `VirtualSIM/DesignSystem/ScreenshotMode.swift`, `VirtualSIM/ContentView.swift` (new fixture `lineDialer`)

**Interfaces:**
- Consumes: `RSpace.gutter`, `RRadius.card` (20), `RRadius.group` (14), `RRadius.xs`, `View.numberStyle(size:weight:color:)`, `Card(radius:elevation:fill:border:)`.
- Produces: no new API. Fixture `ScreenshotMode.Screen.lineDialer`.

Screens that Tasks 3–5 rebuild (the store, the paywall, the live-line view) get only the mechanical replacements here, so a reviewer can approve the token pass on its own. The FAB and the accent-filled "Change number" button stay until Task 5 removes them.

- [ ] **Step 1: Run the baseline load-bearing check** — `zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 1` (create the kit first if it does not exist). Expected: every line `ok`. Record the output.

- [ ] **Step 2: Gutter.** In every file listed above, replace each horizontal screen gutter literal `20` with `RSpace.gutter`. Find them with:
  ```bash
  grep -nE "padding\(\.horizontal, 20\)|padding\(\.trailing, 20\)" VirtualSIM/Screens/Line*.swift VirtualSIM/Screens/ThreadScreen.swift VirtualSIM/Screens/ComposeScreen.swift
  ```
  (Today: LineScreen.swift:113, 117, 119, 294, 457, 519, 538; LineStoreScreen.swift:101, 685; LineCheckoutScreen.swift:85, 236; LineRecentsView.swift:59, 81; LineSettingsScreen.swift:49; LineSwapSheet.swift:79; ComposeScreen.swift:90, 97, 138.) ThreadScreen's `padding(.horizontal, 16)` at :205, :276, :348 becomes `RSpace.gutter` (same value, now a token).
  **LineRecentsView double gutter (audit §2.5):** delete `.padding(.horizontal, 20)` from `strip` (:81); in the empty branch wrap `strip` in `.padding(.horizontal, RSpace.gutter)` so it keeps one gutter there; the non-empty branch already gets one from the `LazyVStack`.

- [ ] **Step 3: Radii and shadows.** Replace, in the listed files only (never change `Card`'s or `HeroCard`'s defaults, which other tabs use):
  - every `Card(elevation: .raised)` → `Card(radius: RRadius.card, elevation: .flat)` (LineScreen.swift:553, LineStoreScreen.swift:229, LineCheckoutScreen.swift:488 and :601, LineSwapSheet.swift:252 and :399);
  - every `Card(elevation: .flat)` with no radius → `Card(radius: RRadius.group, elevation: .flat)` (LineStoreScreen.swift:710, :751; LineSwapSheet.swift:195, :219; ComposeScreen.swift toField and bodyField; LinePickerRows.swift `LineCountryWideRow`; LineSettingsScreen's `numberCard` `Card {` and `emergencySection` `Card {` → `Card(radius: RRadius.group, elevation: .flat) {`);
  - every `radius: RRadius.md` → `radius: RRadius.group` (LineStoreScreen.swift:524, :568, :883; LineCheckoutScreen.swift:342, :365, :730, :786, :859; LineSwapSheet.swift:264, :356, :376; LinePickerRows.swift:334);
  - `LinePickerRows.swift:334` `Card(radius: RRadius.md, elevation: .raised)` → `Card(radius: RRadius.group, elevation: .flat)`; the two skeleton `RoundedRectangle(cornerRadius: RRadius.md…)` (:302, :418) → `RRadius.group`;
  - LineCheckoutScreen.swift:404 `HeroCard {` → `Card(radius: RRadius.card, elevation: .flat) {`;
  - literal radii: `ThreadRow` `.rect(cornerRadius: 16)` (LineScreen.swift:786) and `RecentRow` `.rect(cornerRadius: 16)` (LineRecentsView.swift:283) → `RRadius.group`; `LineStatusBanner`/`VoiceReadinessNotice` `.rect(cornerRadius: 14)` (LineScreen.swift:654, :863) → `RRadius.group`; `RecentRow.action` `.rect(cornerRadius: 12)` → `RRadius.xs`.

- [ ] **Step 4: SF Mono → `numberStyle`.** Replace each `.font(RFont.mono(N, weight: W))` + following `.foregroundStyle(C)` pair with `.numberStyle(size: N, weight: W, color: C)`, keeping the original weight; where the original passed no weight, pass `weight: .regular` (the modifier's default is `.semibold`):
  - LineScreen.swift:248 → `.numberStyle(size: 17, color: theme.text)`; :761 → `.numberStyle(size: 13, weight: .bold, color: theme.text)`
  - LineCheckoutScreen.swift:429 → `.numberStyle(size: 31, color: theme.text)`
  - LineSwapSheet.swift:324 → `.numberStyle(size: 18, weight: .medium, color: muted ? theme.text2 : theme.text)`; :404 → `.numberStyle(size: 20, weight: .medium, color: theme.text)`
  - LineProvisioningScreen.swift:115 → `.numberStyle(size: 19, weight: .medium, color: theme.text2)`
  - ThreadScreen.swift:167 → `.numberStyle(size: 11, weight: .regular, color: theme.text3)`
  - ComposeScreen.swift:150 (a `TextField`) → `.font(RFont.text(16, weight: .medium)).monospacedDigit()` (a TextField takes no content transition)
  - DialerScreen.swift:214 → `.numberStyle(size: 30, color: digits.isEmpty ? theme.text3 : theme.text)` (keep its `.contentTransition` line or drop it: `numberStyle` already applies one)
  - InCallOverlay.swift:89 → `.numberStyle(size: 14, weight: .regular, color: theme.text3)`; :95 → `.numberStyle(size: 27, color: theme.text)`
  - LinePickerRows.swift:338 → `.numberStyle(size: 18, weight: .medium, color: theme.text)`
  - PeerNameSheet.swift:25 → `.numberStyle(size: 15, weight: .regular, color: theme.text2)` (keep its existing colour if different)
  - Buttons.swift:60 (`PrimaryButton`'s `sub`) → `.font(RFont.text(15, weight: .medium)).monospacedDigit()` — this changes every screen that passes `sub:` (CreditsSheet, TempScreen, EsimCheckout, the paywall) from SF Mono to SF Pro digits, which is spec §3 rule 3.

- [ ] **Step 5: One green per screen (colour only).**
  - `ThreadRow` unread dot (LineScreen.swift:781) `theme.ink` → `theme.text`.
  - `MessageBubble` code chip (ThreadScreen.swift:497–502): `foregroundStyle(copiedCode ? theme.live : theme.ink)` → `copiedCode ? theme.live : theme.text`; background `(copiedCode ? theme.live : theme.ink).opacity(0.12)` → `copiedCode ? theme.liveSoft : theme.chipBg`.
  - `RecentRow` call-back glyph `.foregroundStyle(theme.ink)` → `theme.text2`; its expanded `action(icon: RIcon.phone, label: "Call back", tint: theme.ink…` → `tint: theme.text`.
  - `LineSettingsScreen.rentAnotherSection`: `.foregroundStyle(theme.ink)` → `theme.text`; `.background(theme.inkSoft.opacity(0.5), in: Capsule())` → `.background(theme.chipBg, in: Capsule())`.
  - `DialerScreen` call button (:311) `theme.live` → `theme.ink` (spec §4.4: the call button is the dialer's one primary action).
  - `LineStoreScreen` pitch `BenefitRow`s: add `tint: theme.text2` to the four rows that pass no tint (the codes row keeps `theme.live` until Task 3 deletes the pitch).

- [ ] **Step 6: Title style.** `LineStoreScreen.header` (:810–813): replace `.font(RFont.display(28, weight: .bold)).tracking(-0.7)` with `.displayType(30)`. `LineCheckoutScreen.intro` (:252) `.displayType(29)` → `.displayType(30)`.

- [ ] **Step 7: Fixture `lineDialer`.** In `ScreenshotMode.Screen` add after `lineInbox`:
  ```swift
          // The keypad over a live line, with a number typed. The dialer is a
          // cover reached only by a tap, so without a frame it ships unseen.
          case lineDialer
  ```
  In `ContentView.applyScreenshotState`, add after the `.lineInbox` case:
  ```swift
          case .lineDialer:
              state.tab = .line
              state.lines = [ScreenshotMode.sampleLine]
              state.lineThreads = ScreenshotMode.sampleThreads
              // 555 range, like every fixture. Read AND cleared by the dialer.
              state.dialerPrefill = "+13105550199"
              state.flow = .dialer
  ```
  (`CallController.performPrepareVoice` already returns early in screenshot mode, and `AuthGate` attaches the real voice client, so `isVoiceAvailable` is true and the `.dialer` case renders `DialerScreen`.)

- [ ] **Step 8: Build.** Run the Global Constraints build command. Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Prove the pass.**
  ```bash
  grep -nE "RFont\.mono|MonoText" VirtualSIM/Screens/Line*.swift VirtualSIM/Screens/ThreadScreen.swift VirtualSIM/Screens/ComposeScreen.swift VirtualSIM/Screens/DialerScreen.swift VirtualSIM/Screens/InCallOverlay.swift VirtualSIM/Components/LinePickerRows.swift VirtualSIM/Sheets/PeerNameSheet.swift VirtualSIM/Components/Buttons.swift || echo NO-MONO
  grep -nE "elevation: \.raised|HeroCard|RRadius\.md|padding\(\.horizontal, 20\)|cornerRadius: 1[26]\)" VirtualSIM/Screens/Line*.swift VirtualSIM/Screens/ThreadScreen.swift VirtualSIM/Screens/ComposeScreen.swift VirtualSIM/Components/LinePickerRows.swift || echo NO-OFF-SYSTEM
  ```
  Expected: `NO-MONO` and `NO-OFF-SYSTEM`.

- [ ] **Step 10: Screenshots.** `zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-shots.sh lineStore linePaywall lineInbox thread lineDialer credits`. Expected: every background line `ok`; the lineStore/lineInbox/paywall layouts unchanged except the 16 pt column (card edges at x ≈ 48 px), no drop shadows in light, phone numbers in SF Pro with even digit columns; the thread's "Copy 123456" chip neutral; the dialer's call button in the accent colour, digits in SF Pro; the credits sheet CTA's price sub in SF Pro.

- [ ] **Step 11: Checks + commit**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 1   # every line ok
  git diff main --stat -- supabase VirtualSIM/Onboarding          # prints nothing
  git add -A VirtualSIM
  git commit -m "my number: tokens pass — 16pt gutter, 20/14 radii, no shadows, SF Pro digits, one green"
  ```
  (append the two attribution lines to every commit message in this plan)

---

### Task 2: Copy corrections and the ✓/✗ ledger (the one list stays)

**Files:**
- Create: `VirtualSIM/Components/LineLedger.swift`
- Modify: `VirtualSIM/Screens/LineStoreScreen.swift` (`numbersPage` :401–431, `voiceOnlyNotice` :518–541, `sendingNotice` :562–602, pitch body :279)
- Modify: `VirtualSIM/Screens/LineCheckoutScreen.swift` (`capabilityNote` text :349)
- Modify: `VirtualSIM/Screens/ThreadScreen.swift` (`failureCopy` :553–555)
- Modify: `VirtualSIM/Screens/LineSwapSheet.swift` (`confirmPage` :250–312, `.task` :85)
- Modify: `VirtualSIM/Screens/LineSwitchNumberButton.swift` (fixture hook only)
- Modify: `VirtualSIM/DesignSystem/ScreenshotMode.swift`, `VirtualSIM/ContentView.swift` (fixture `lineSwapConfirm`)
- Modify: `VirtualSIM/Localizable.xcstrings` via `/tmp/p2-t2.json`

**Interfaces:**
- Produces: `LineLedger<Content: View>(content:)` (a grouped container that draws a hairline between rows) and `LineLedgerRow(kind: .yes | .no, figure: String? = nil, text: Text, detail: Text? = nil)`. Fixture `ScreenshotMode.Screen.lineSwapConfirm`, `ScreenshotMode.sampleSwapOffer`.
- Consumes: `LineStoreScreen.unreliableSendingCountries` (unchanged), `RSpace`, `RRadius.group`, `numberStyle`.

- [ ] **Step 1: `LineLedger.swift`**

```swift
import SwiftUI

/// What a rented number does (✓) and does not do (✗), stated as rows
/// (spec §4.1). One component for the store, the paywall's "What you get"
/// and the swap confirm page, so a limitation reads the same everywhere.
///
/// Neutral by the one-green rule: ✓ is `text2`, ✗ is `warn` — a limitation,
/// not a fault, so never `fail`. The glyphs are hidden from VoiceOver: every
/// ✗ sentence states its own negative.
struct LineLedger<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(theme.sep)
                            .frame(height: 0.5)
                            .padding(.leading, RSpace.lg + 18 + RSpace.md)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }
}

struct LineLedgerRow: View {
    @Environment(\.theme) private var theme

    enum Kind { case yes, no }

    let kind: Kind
    /// A quantity that leads the sentence ("100"), set in the number voice.
    var figure: String? = nil
    let text: Text
    /// A qualifier under the sentence, e.g. the inbound NANP limit.
    var detail: Text? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RSpace.md) {
            Image(systemName: kind == .yes ? "checkmark" : "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(kind == .yes ? theme.text2 : theme.warn)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let figure {
                        Text(verbatim: figure)
                            .numberStyle(size: 15, weight: .bold, color: theme.text)
                    }
                    text
                        .font(RFont.text(15))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    detail
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RSpace.lg)
        .padding(.vertical, RSpace.md)
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 2: The store's ledger replaces both notices.** In `LineStoreScreen`, add:

```swift
    /// The honest ledger (spec §4.1). It replaces `sendingNotice` and its
    /// false Canada branch, and `voiceOnlyNotice`.
    ///
    /// 🔴 The ✗ row renders for EVERY country, not only US/PR: 10DLC is
    /// enforced by the RECIPIENT's network, so a Canadian number texting a US
    /// number fails too (CA→US 0 of 8, all `40010`, CLAUDE.md 2026-09-24).
    /// The ✓ row's detail is the inbound NANP limit (`usSoon`'s claim): a
    /// number does not receive texts from outside the US and Canada, and the
    /// unqualified "texts" is honest only while this line is on screen.
    private var ledger: some View {
        LineLedger {
            if isVoiceOnly {
                LineLedgerRow(kind: .no,
                              text: Text("Calls only. This number can't send or receive texts."))
            } else {
                LineLedgerRow(kind: .yes,
                              text: Text("Receive texts and verification codes"),
                              detail: Text("From US and Canadian numbers and services."))
            }
            LineLedgerRow(kind: .yes, text: Text("Calls"))
            if !isVoiceOnly {
                LineLedgerRow(kind: .no,
                              text: Text("Texts you send to US numbers usually don't arrive."))
            }
        }
    }
```
  In `numbersPage` (:421) replace `if isVoiceOnly { voiceOnlyNotice } else { sendingNotice }` with `ledger`. Delete `voiceOnlyNotice` (:512–541) and `sendingNotice` with its doc comment (:543–602). Keep `static let unreliableSendingCountries` (:604–607) and its doc; rewrite the doc's last sentence to: "Read by checkout's `capabilityNote`, the thread's failed-send copy and the swap sheet's confirm page, so they cannot disagree about who is warned. The store's ledger ✗ row is shown for every country and does not read it."

- [ ] **Step 3: Proof line.** In the pitch (:279) replace the `Text("Verify WhatsApp or WhatsApp Business with it — also works with TikTok, DoorDash and most other apps. The code lands here, with one tap to copy it.")` literal with `Text("Has received codes from WhatsApp, TikTok and DoorDash.")` (same modifiers). Update the comment above it: "Owner, 2026-09-24: past tense, exactly these three (each has a real code in `line_messages`). 'And most other apps' was unmeasured and is gone."

- [ ] **Step 4: Checkout note.** In `LineCheckoutScreen.capabilityNote` (:349) replace the text with `Text("Texts you send from an American number often don't arrive — most US networks block them. Receiving codes and calling work normally.")`. In the comment above (:340–341) replace "It names Canada because the remedy has to be actionable…" with: "It no longer names Canada: CA→US fails the same way (0 of 8, CLAUDE.md 2026-09-24), so a Canadian number is not a remedy." Leave `sendingWarningShown` and the condition untouched — `line_checkout_exit.capability_note` reads it.

- [ ] **Step 5: Thread failure copy.** In `MessageBubble.failureCopy` (ThreadScreen.swift:553–555) replace the returned literal with `"Texts you send from an American number often don't arrive — most US networks block them. Receiving codes and calling work normally."` (the same key checkout now uses, so the buyer reads here what they read before buying).

- [ ] **Step 6: Swap confirm ✗ row.** In `LineSwapSheet`, add:

```swift
    /// The country the swap will land in — the same expression `perform`
    /// sends as `country`.
    private var targetCountry: String { state.lineCountry ?? line.countryCode }

    /// The ledger's ✗ row, when the NEW number is US/PR (spec §4.4). Reads the
    /// one list, like checkout and the thread.
    private var sendsUnreliably: Bool {
        LineStoreScreen.unreliableSendingCountries.contains(targetCountry.uppercased())
    }
```
  In `confirmPage`, directly after the Current → New `Card { … }` (:252–260), insert:
```swift
            if sendsUnreliably {
                LineLedger {
                    LineLedgerRow(kind: .no,
                                  text: Text("Texts you send to US numbers usually don't arrive."))
                }
            }
```
  Replace the two `(state.lineCountry ?? line.countryCode)` / `state.lineCountry ?? line.countryCode` expressions in `confirmPage.task` and `perform` with `targetCountry` (same value).

- [ ] **Step 7: Fixture `lineSwapConfirm`.**
  - `ScreenshotMode.Screen`: add `case lineSwapConfirm   // the swap sheet's last page: price, balance, given up for good, US ✗ row`.
  - `ScreenshotMode` (inside the `#if DEBUG` extension, after `sampleLine`):
    ```swift
    /// The number the `lineSwapConfirm` frame switches TO. US on purpose, so
    /// the ✗ row renders. 555 range, like every fixture.
    static var sampleSwapOffer: LineNumberOffer {
        LineNumberOffer(phoneNumber: "+13105550164", region: "Los Angeles, CA",
                        monthlyCents: 100, upfrontCents: 100, countryCode: "US")
    }
    ```
  - `LineSwapSheet` `.task { await loadInitial() }` (:85) becomes:
    ```swift
            .task {
                #if DEBUG
                // Screenshot harness: open straight on the confirm page. No
                // search, no `line_swap_open` — the frame is not a visit.
                if ScreenshotMode.screen == .lineSwapConfirm {
                    state.lineCountry = "US"
                    page = .confirm(ScreenshotMode.sampleSwapOffer)
                    return
                }
                #endif
                await loadInitial()
            }
    ```
  - `LineSwitchNumberButton.body`: on the outer `VStack`, add
    ```swift
            .onAppear {
                // Screenshot harness: the swap sheet is `@State` here, so the
                // frame raises it itself. The live-line instance only.
                if ScreenshotMode.screen == .lineSwapConfirm, style == .primary { choosing = true }
            }
    ```
  - `ContentView.applyScreenshotState`, after `.lineDialer`:
    ```swift
            case .lineSwapConfirm:
                state.tab = .line
                state.lines = [ScreenshotMode.sampleLine]
                state.lineThreads = ScreenshotMode.sampleThreads
                // The live price, as every line fixture sets it (`simctl` never
                // fetches `app_config`); 8 is what it read on 2026-09-01.
                state.appStatus = AppStatus(announcement: nil, esimPaused: false, lineSwapCredits: 8)
    ```
    (balance is 42 for every fixture, so the Switch CTA renders, not Top up.)

- [ ] **Step 8: Strings** — `/tmp/p2-t2.json`:

```json
{
  "Texts you send from an American number often don't arrive — most US networks block them. Receiving codes and calling work normally.": {"de": "SMS, die Sie von einer amerikanischen Nummer senden, kommen oft nicht an – die meisten US-Netze blockieren sie. Codes empfangen und Telefonieren funktionieren normal.", "es": "Los SMS que envías desde un número estadounidense a menudo no llegan: la mayoría de las redes de EE. UU. los bloquean. Recibir códigos y llamar funciona con normalidad.", "fr": "Les SMS que vous envoyez depuis un numéro américain n'arrivent souvent pas : la plupart des réseaux américains les bloquent. La réception des codes et les appels fonctionnent normalement.", "it": "Gli SMS che invii da un numero americano spesso non arrivano: la maggior parte delle reti statunitensi li blocca. Ricevere codici e chiamare funziona normalmente.", "ja": "米国の番号から送信したSMSは届かないことがよくあります。米国のほとんどの通信網がブロックするためです。コードの受信と通話は通常どおりご利用いただけます。", "pt-BR": "As mensagens que você envia de um número americano muitas vezes não chegam — a maioria das redes dos EUA as bloqueia. Receber códigos e fazer ligações funciona normalmente."},
  "Texts you send to US numbers usually don't arrive.": {"de": "SMS, die Sie an US-Nummern senden, kommen meist nicht an.", "es": "Los SMS que envías a números de EE. UU. no suelen llegar.", "fr": "Les SMS que vous envoyez vers des numéros américains n'arrivent généralement pas.", "it": "Gli SMS che invii a numeri statunitensi di solito non arrivano.", "ja": "米国の番号宛てに送信したSMSは、通常届きません。", "pt-BR": "As mensagens que você envia para números dos EUA geralmente não chegam."},
  "Receive texts and verification codes": {"de": "SMS und Bestätigungscodes empfangen", "es": "Recibe SMS y códigos de verificación", "fr": "Recevez des SMS et des codes de vérification", "it": "Ricevi SMS e codici di verifica", "ja": "SMSと認証コードを受信", "pt-BR": "Receba SMS e códigos de verificação"},
  "From US and Canadian numbers and services.": {"de": "Von Nummern und Diensten aus den USA und Kanada.", "es": "De números y servicios de EE. UU. y Canadá.", "fr": "Depuis des numéros et services américains et canadiens.", "it": "Da numeri e servizi di Stati Uniti e Canada.", "ja": "米国・カナダの番号やサービスから受信できます。", "pt-BR": "De números e serviços dos EUA e do Canadá."},
  "Has received codes from WhatsApp, TikTok and DoorDash.": {"de": "Hat bereits Codes von WhatsApp, TikTok und DoorDash empfangen.", "es": "Ya ha recibido códigos de WhatsApp, TikTok y DoorDash.", "fr": "A déjà reçu des codes de WhatsApp, TikTok et DoorDash.", "it": "Ha già ricevuto codici da WhatsApp, TikTok e DoorDash.", "ja": "WhatsApp、TikTok、DoorDashからのコード受信実績があります。", "pt-BR": "Já recebeu códigos do WhatsApp, TikTok e DoorDash."}
}
```
  Run the existing-keys check, then `python3 scripts/xcstrings-add.py /tmp/p2-t2.json`. Expected `added/updated 5 keys`. ("Calls" and "Calls only. This number can't send or receive texts." already exist.) The two retired Canada sentences stay in the catalog (Xcode marks them stale on its own; do not hand-delete keys).

- [ ] **Step 9: Build.** Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Screenshots.** `zsh …/p2-shots.sh lineSwapConfirm linePaywall thread`. Expected: `lineSwapConfirm` shows "Confirm your new number", Current `+1 (212) 555-0128` struck through, New `+1 (310) 555-0164`, then the ✗ row "Texts you send to US numbers usually don't arrive.", Price 8 credits, Your balance 42 credits, the amber "given up for good" warning, the Switch CTA. Backgrounds `ok`. (The store's ledger lives in the picker sheet until Task 3, which no fixture opens; Task 3 captures it on the root.)

- [ ] **Step 11: Checks + commit**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 2   # every line ok
  git diff main --stat -- supabase VirtualSIM/Onboarding
  git add -A VirtualSIM
  git commit -m "my number: remove the false Canada claims; ✓/✗ ledger; US ✗ row on the swap confirm page"
  ```

---

### Task 3: Store rebuild — inline numbers, country segment, pushed place pages, price row, proof line

**Files:**
- Create: `VirtualSIM/Components/CapsuleSegmentedControl.swift`
- Create: `VirtualSIM/Screens/LineStorePages.swift` (`LineStoreSearch`, `LineCountriesPage`, `LineCitiesPage`, `LineStoreCover`)
- Modify: `VirtualSIM/Screens/LineStoreScreen.swift` (the whole `body` and everything between `// MARK: - The pitch` and the end, except `unreliableSendingCountries`, `defaultCountry()`, `currentCountry`, `isVoiceOnly`, `sellableCountries`, `chipOrder`, and the Task 2 `ledger`)
- Modify: `VirtualSIM/Screens/LineScreen.swift` (`LineScreen` :9–42 only; add `lineRouteDestinations()`)
- Modify: `VirtualSIM/State/AppState.swift` (add `enum LineRoute`, `var linePath`)
- Modify: `VirtualSIM/DesignSystem/Motion.swift` (`RMotion.unlessReduced`, Reduce-Motion-aware `riseIn`)
- Modify: `VirtualSIM/Components/LinePickerRows.swift` (`LineOfferRow` :323–401 → a list row, new `LineOfferList`, `LineOfferSkeleton` :412–449, delete `LineCountryChip` :144–187)
- Modify: `VirtualSIM/Screens/LineSwapSheet.swift` (`numbersPage` list :154–166)
- Modify: `VirtualSIM/ContentView.swift` (`case .lineStoreMore:` :733–738; fixtures `lineIntro`, `lineStore`, new `lineStoreError`)
- Modify: `VirtualSIM/DesignSystem/ScreenshotMode.swift` (case `lineStoreError`; comments on `lineIntro`/`lineStore`)
- Modify: `VirtualSIM/Localizable.xcstrings` via `/tmp/p2-t3.json`

**Interfaces:**
- Produces:
  - `enum LineRoute: Hashable { case countries, cities }` (Task 6 adds `thread(String)`, `compose`) and `AppState.linePath: [LineRoute]`.
  - `View.lineRouteDestinations()` — registers every `LineRoute` destination on the enclosing `NavigationStack`.
  - `LineStoreScreen(onOpenSms: () -> Void, onClose: (() -> Void)? = nil, push: (LineRoute) -> Void)`.
  - `LineStoreCover()` — the `.lineStoreMore` cover's content (its own `NavigationStack`).
  - `@MainActor enum LineStoreSearch { static func reload(_:api:city:country:) async; static func changePlace(_:api:city:country:); static func selectCountry(_:state:api:) }`.
  - `CapsuleSegmentedControl<Tag: Hashable, Label: View>(selection: Binding<Tag>, tags: [Tag], label: (Tag, Bool) -> Label)`.
  - `LineOfferList(offers:country:placeFallback:onPick:)`; `LineOfferRow` now a flat list row.
  - `RMotion.unlessReduced(_ animation: Animation, _ reduceMotion: Bool) -> Animation?`.
  - Fixture `lineStoreError`. Event change: `line_numbers_shown` gains `source: "store_inline"`; `line_choose_number_tapped` retired.
- Consumes: `LineLedger` (Task 2), `SubscriptionStore.monthlyPriceDisplay` / `monthlyIntroPriceDisplay`, `Session.accessToken`, `AppState.loadLineNumbers/loadLineCountries`, `LineUnavailableCopy`, `LineCityRow`, `LineCountryRow`, `LineCountryWideRow`, `LinePickerRowSkeleton`.

**Allowance (spec §4.1) — verified, nothing added.** No server-sourced allowance exists before purchase: `line_country_menu` publishes only `country_code, country_name, number_type, supports_*, available, sell_reason, has_localities` (migration `20260826160000`, and `LineAPI.countries()` selects exactly those), `search-line-numbers` returns numbers, localities and capabilities (`LineAvailability`), and the only figures in the client before purchase are `LineProduct.smsAllowance` / `voiceAllowanceMinutes`, which are client mirrors of `phone_lines` schema defaults (`SubscriptionStore.swift:692–711`), not server values. The store therefore shows no allowance; Task 7 records it as an owner open item.

- [ ] **Step 1: Motion helpers** (`Motion.swift`). Add to `enum RMotion`:

```swift
    /// nil under Reduce Motion, so `withAnimation(RMotion.unlessReduced(…))`
    /// and `.animation(RMotion.unlessReduced(…), value:)` change instantly.
    /// Every animation added by the My number overhaul goes through this
    /// (spec §3a: "every one is skipped under Reduce Motion").
    static func unlessReduced(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
```
  Replace the `riseIn` extension body with a modifier that honours Reduce Motion (same signature, so every call site keeps compiling):

```swift
extension View {
    /// Fade + rise entrance, driven by an external "has appeared" flag.
    ///
    /// Takes the flag rather than owning `@State` so a parent can replay the
    /// entrance when its content changes identity. Under Reduce Motion the
    /// content simply appears: no offset, no animation.
    func riseIn(_ shown: Bool, index: Int = 0, distance: CGFloat = 10) -> some View {
        modifier(RiseIn(shown: shown, index: index, distance: distance))
    }
}

private struct RiseIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool
    let index: Int
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .animation(reduceMotion ? nil : RMotion.stagger(index), value: shown)
    }
}
```

- [ ] **Step 2: `CapsuleSegmentedControl.swift`**

```swift
import SwiftUI

/// A segmented control whose selection capsule GLIDES between segments
/// (matched geometry, spec §3a). The system `Picker(.segmented)` cannot take
/// the overhaul's tokens or this motion, so this is the one custom control on
/// the My number tab: the store's country choice and the subscriber's
/// Messages · Calls · Number.
///
/// Neutral by the one-green rule: an `elev` capsule on a `chipBg` track, no
/// accent, no shadow. 44pt tall including the track.
struct CapsuleSegmentedControl<Tag: Hashable, Label: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selection: Tag
    let tags: [Tag]
    @ViewBuilder let label: (Tag, Bool) -> Label

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tags, id: \.self) { tag in
                let active = tag == selection
                Button {
                    guard !active else { return }
                    RHaptic.select()
                    withAnimation(RMotion.unlessReduced(RMotion.standard, reduceMotion)) {
                        selection = tag
                    }
                } label: {
                    label(tag, active)
                        .font(RFont.text(14, weight: .semibold))
                        .foregroundStyle(active ? theme.text : theme.text2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if active {
                                Capsule()
                                    .fill(theme.elev)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(theme.chipBg, in: .capsule)
    }
}
```

- [ ] **Step 3: `LineRoute` + `linePath`** (`AppState.swift`, directly after `enum AppTab { … }`):

```swift
/// Pages pushed inside the My number tab (spec §4.4). One enum for the tab's
/// stack AND the "Rent another number" cover's own stack, so a place page is
/// one definition wherever the store is shown.
enum LineRoute: Hashable {
    /// Every catalog country, sellable first (the store's "Try another country").
    case countries
    /// The current country's localities ("Other city").
    case cities
}
```
  and next to `var tab: AppTab = .verify`:
```swift
    /// Navigation inside the My number tab. Not persisted. Emptied when the
    /// tab's ROOT changes (store ↔ live line) — see `LineScreen`.
    var linePath: [LineRoute] = []
```

- [ ] **Step 4: `LineScreen` hosts the stack** (replace `LineScreen.body` :16–41; keep the struct's doc and `onOpenSms`):

```swift
    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $state.linePath) {
            root
                .containerBackground(theme.bg, for: .navigation)
                .toolbar(.hidden, for: .navigationBar)
                .lineRouteDestinations()
        }
        .task {
            // Cheap (one row, RLS-scoped) and it must run on every visit: the
            // subscription can change state — renew, lapse, be refunded —
            // entirely outside the app.
            await state.loadLine(using: LineAPI(client: api))
        }
        // A purchase (store → live line) or a lapse (live line → store)
        // replaces the stack's ROOT; a page pushed over the old root means
        // nothing over the new one.
        .onChange(of: state.line?.status.isLive ?? false) { _, _ in
            state.linePath = []
        }
    }

    @ViewBuilder
    private var root: some View {
        if let line = state.line, line.status.isLive {
            LiveLineView(line: line)
                // The back-button label on pushed pages; the bar itself is hidden here.
                .navigationTitle(Text("My number"))
        } else if !state.linesLoaded {
            // (keep the existing comment block from :21–26 here)
            theme.bg.ignoresSafeArea()
        } else {
            // (keep the existing RELEASED-line comment from :29–31 here)
            LineStoreScreen(onOpenSms: onOpenSms,
                            push: { state.linePath.append($0) })
                .navigationTitle(Text("Your own number"))
        }
    }
```
  and add at file scope in `LineScreen.swift`:
```swift
extension View {
    /// Registers every `LineRoute` destination on the enclosing
    /// `NavigationStack` — the tab's and `LineStoreCover`'s.
    func lineRouteDestinations() -> some View {
        navigationDestination(for: LineRoute.self) { route in
            switch route {
            case .countries: LineCountriesPage()
            case .cities:    LineCitiesPage()
            }
        }
    }
}
```

- [ ] **Step 5: `LineStorePages.swift`**

```swift
import SwiftUI

/// The store's two search entry points, shared by the store root and the
/// pushed place pages so `line_numbers_shown` / `line_place_changed` cannot
/// drift from what they measure.
@MainActor
enum LineStoreSearch {
    /// Every search the store runs. `line_numbers_shown` fires on the RESULT.
    ///
    /// ⚠️ SEMANTICS CHANGED with the inline list (2026-09-24): on `main` this
    /// event meant "the reader opened the picker"; here it fires whenever the
    /// store renders a fresh search (every visit that searches). `source`
    /// marks the new series; do not compare it with main's.
    static func reload(_ state: AppState, api: APIClient,
                       city: String? = nil, country: String? = nil) async {
        await state.loadLineNumbers(using: LineAPI(client: api), city: city, country: country)
        Analytics.shared.track("line_numbers_shown", [
            "country": .string(state.lineCountry ?? "unknown"),
            // "any" is a real answer — a country with no curated localities
            // sells country-wide — and must not read as a missing one.
            "city": .string(state.lineCity ?? "any"),
            "count": .int(state.lineOffers.count),
            "source": .string("store_inline")])
    }

    /// One definition of "the user chose somewhere else".
    static func changePlace(_ state: AppState, api: APIClient,
                            city: String? = nil, country: String? = nil) {
        Analytics.shared.track("line_place_changed", [
            "country": .string(country ?? state.lineCountry ?? "unknown"),
            "city": .string(city ?? "any")])
        Task { await reload(state, api: api, city: city, country: country) }
    }

    /// A different country invalidates everything downstream: cleared first,
    /// loaded second, so Toronto never shows under a Polish flag.
    static func selectCountry(_ country: LineCountry, state: AppState, api: APIClient) {
        state.lineCountry = country.countryCode
        state.lineCity = nil
        state.lineCities = []
        state.lineOffers = []
        state.lineOffer = nil
        state.lineReservation = nil
        state.lineUnavailableReason = nil
        changePlace(state, api: api, country: country.countryCode)
    }
}

/// Every catalog country, pushed from the store's "Try another country".
/// Unsellable rows stay visible and gray ("Not available yet").
struct LineCountriesPage: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = state.lineCountries.pickerOrder
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows) { country in
                    if country.id != rows.first?.id { RowRule(inset: RSpace.lg) }
                    LineCountryRow(country: country) {
                        RHaptic.select()
                        LineStoreSearch.selectCountry(country, state: state, api: api)
                        dismiss()
                    }
                }
            }
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
            .padding(.horizontal, RSpace.gutter)
            .padding(.vertical, RSpace.lg)
        }
        .background(theme.bg.ignoresSafeArea())
        .containerBackground(theme.bg, for: .navigation)
        .navigationTitle(Text("Where should it be?"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The current country's localities ("Other city ›"). A country with no
/// curated localities sells country-wide, and an empty list mid-load must
/// not render as "nowhere".
struct LineCitiesPage: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Group {
                if state.lineCities.isEmpty {
                    if state.isLoadingLineNumbers {
                        LinePickerRowSkeleton()
                    } else {
                        LineCountryWideRow(countryLabel: state.linePlaceCountryLabel) {
                            choose(city: nil)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.lineCities) { city in
                            if city.id != state.lineCities.first?.id { RowRule(inset: RSpace.lg) }
                            LineCityRow(city: city) { choose(city: city.id) }
                        }
                    }
                    .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
                }
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.vertical, RSpace.lg)
        }
        .background(theme.bg.ignoresSafeArea())
        .containerBackground(theme.bg, for: .navigation)
        .navigationTitle(Text("Which city?"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Back to the numbers, which reload behind the pop.
    private func choose(city: String?) {
        RHaptic.select()
        LineStoreSearch.changePlace(state, api: api, city: city)
        dismiss()
    }
}

/// "Rent another number" (`flow == .lineStoreMore`): the same store, as a
/// cover with its own stack so its place pages push inside the cover.
struct LineStoreCover: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @State private var path: [LineRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            LineStoreScreen(onOpenSms: { state.flow = nil; state.openCodeStore() },
                            onClose: { state.flow = nil },
                            push: { path.append($0) })
                .containerBackground(theme.bg, for: .navigation)
                .toolbar(.hidden, for: .navigationBar)
                .navigationTitle(Text("Your own number"))
                .lineRouteDestinations()
        }
    }
}
```
  In `ContentView.flowContent`, replace the `case .lineStoreMore:` body (:733–738) with `LineStoreCover()` (keep its comment).

- [ ] **Step 6: Offer rows as one grouped list** (`LinePickerRows.swift`). Replace `LineOfferRow` (:323–401, including its `capabilities` helper) with:

```swift
/// One candidate number: flag, the number in the number voice (compact form,
/// spec §3 rule 3), its place beneath. A flat row inside `LineOfferList`.
///
/// ⚠️ No price here, deliberately: `monthlyCents`/`upfrontCents` are the
/// WHOLESALE quote, and the retail price is stated once by the caller.
struct LineOfferRow: View {
    @Environment(\.theme) private var theme
    let offer: LineNumberOffer
    /// The country the search ran in, when the offer carries none.
    var country: String? = nil
    /// Shown when the offer names no region (older server bundles).
    var placeFallback: String? = nil
    let action: () -> Void

    private var place: String? {
        if let r = offer.region, !r.isEmpty { return r }
        return placeFallback
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: RSpace.md) {
                if let code = offer.countryCode ?? country {
                    CodeFlag(code: code, size: 34)
                } else {
                    PeerAvatar(e164: offer.phoneNumber, size: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PhoneFormat.compact(offer.phoneNumber))
                        .numberStyle(size: 20, color: theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let place {
                        Text(verbatim: place)
                            .font(RFont.text(13))
                            .foregroundStyle(theme.text2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: RSpace.sm)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, RSpace.lg)
            .padding(.vertical, RSpace.md)
            .frame(minHeight: 64)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98, dim: true))
        .accessibilityElement(children: .combine)
    }
}

/// The candidate numbers as ONE grouped list (spec §4.1) — the store's three
/// and the swap sheet's full search.
struct LineOfferList: View {
    @Environment(\.theme) private var theme
    let offers: [LineNumberOffer]
    var country: String? = nil
    var placeFallback: String? = nil
    let onPick: (LineNumberOffer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(offers) { offer in
                if offer.id != offers.first?.id {
                    RowRule(inset: RSpace.lg + 34 + RSpace.md)
                }
                LineOfferRow(offer: offer, country: country,
                             placeFallback: placeFallback) { onPick(offer) }
            }
        }
        .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }
}
```
  Replace `LineOfferSkeleton.body` (:416–449) with the same grouped shape at the real row height (64 pt), so the section does not jump:
```swift
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<max(rows, 1), id: \.self) { i in
                if i > 0 { RowRule(inset: RSpace.lg + 34 + RSpace.md) }
                HStack(spacing: RSpace.md) {
                    Circle().fill(theme.chipBg).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(theme.chipBg).frame(width: 150, height: 16)
                        RoundedRectangle(cornerRadius: 3).fill(theme.chipBg).frame(width: 80, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RSpace.lg)
                .frame(height: 64)
            }
        }
        .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
        .accessibilityHidden(true)
        .transition(.opacity)
    }
```
  Delete `LineCountryChip` and its doc comment (:144–187); nothing else uses it (`grep -rn LineCountryChip VirtualSIM` must print nothing afterwards).
  In `LineSwapSheet.numbersPage` replace the `VStack(spacing: 8) { ForEach(state.lineOffers…) { LineOfferRow(…) } GhostButton… }` block (:154–166) with:
```swift
                VStack(spacing: RSpace.sm) {
                    LineOfferList(offers: state.lineOffers, country: state.lineCountry,
                                  placeFallback: state.linePlaceLabel) { pick($0) }
                    GhostButton(label: "Show different numbers", icon: RIcon.refresh, fillsWidth: false) {
                        Task { await reload() }
                    }
                    .disabled(state.isLoadingLineNumbers)
                    .opacity(state.isLoadingLineNumbers ? 0.5 : 1)
                    .padding(.top, RSpace.xs)
                }
```

- [ ] **Step 7: The store root** (`LineStoreScreen.swift`). Rewrite the top-of-file doc to describe the new screen (title, country control, ledger, proof line, three inline numbers, price row, one-off link; the picker sheet is gone; the price is back on the store by the approved 2026-09-24 design, reversing 2026-09-09; StoreKit only). Add `@Environment(Session.self) private var session` and `@Environment(\.accessibilityReduceMotion) private var reduceMotion`; add `var push: (LineRoute) -> Void` after `onClose`. Delete: `SheetPage`, `showsPicker`, `sheetPage`, `reloadNumbers`, `changePlace`, `pitch`, `placeLabel`, `chooseNumber`, `openPicker`, `numbersPage`, `countryChips`, `numberList`, `numberRow`, `numberSkeleton`, `unavailableTitle`/`unavailableBody` (inline them), `placeSheet`, `sheetTitle`, `showsCountryStep`, `sortedCountries`, `countryList`, `select`, `selectCountry`, `cityList`, `countryWide`, `rowSkeleton`, `countryLabel`, `cityLabel`, `header(kicker:title:)`, `priceNote`, `usSoon`, `smsEscape`. Keep: `@State private var appeared` (:51), `visibleOffers`, `defaultCountryCode`, `defaultCountry()`, `unreliableSendingCountries`, `sellableCountries`, `chipOrder`, `currentCountry`, `isVoiceOnly`, `ledger` (Task 2). Then add:

```swift
    private var hasSession: Bool { session.accessToken != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.riseIn(appeared, index: 0)
                countryControl.padding(.top, RSpace.xl).riseIn(appeared, index: 1)
                ledger.padding(.top, RSpace.lg).riseIn(appeared, index: 1)
                proofLine.padding(.top, RSpace.md).riseIn(appeared, index: 2)
                numbers.padding(.top, RSpace.xl).riseIn(appeared, index: 2)
                priceRow.padding(.top, RSpace.lg).riseIn(appeared, index: 3)
                oneOffLink.padding(.top, RSpace.xl).riseIn(appeared, index: 4)
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.top, RSpace.lg)
            .padding(.bottom, RSpace.xxl)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg.ignoresSafeArea())
        // `appeared` is set BEFORE any await: nothing above the numbers needs
        // the network, and awaiting first left the screen at opacity 0.
        .task {
            withAnimation(RMotion.unlessReduced(RMotion.content, reduceMotion)) { appeared = true }
            Analytics.shared.track("line_store_view")
            async let product: () = subs.loadProduct()   // the price row; idempotent
            await state.loadLineCountries(using: LineAPI(client: api))
            if state.lineCountry == nil, let iso = defaultCountry() {
                state.lineCountry = iso
            }
            await searchIfNeeded()
            _ = await product
        }
    }

    /// Runs the inline search once per visit (leaving the tab clears the
    /// draft, so the next visit searches again). Screenshot frames seed the
    /// offers themselves; a live search from `simctl` would wipe them.
    /// 🔴 `search-line-numbers` needs a session: a guest (a later plan) must
    /// not hit it, and a 401 would render as "We couldn't load any numbers".
    private func searchIfNeeded() async {
        guard !ScreenshotMode.isActive, hasSession,
              state.lineOffers.isEmpty, !state.isLoadingLineNumbers else { return }
        await LineStoreSearch.reload(state, api: api)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: RSpace.md) {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                Text("Your own number")
                    .displayType(30)
                    .foregroundStyle(theme.text)
                Text("A number that stays yours. Receive codes, texts and calls here.")
                    .font(RFont.text(15))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                // The ✕ exists because the cover had no exit (owner report 2026-09-06).
                Button(action: onClose) {
                    Image(systemName: RIcon.close)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 36, height: 36)
                        .background(theme.chipBg, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScaleStyle(scale: 0.92))
                .accessibilityLabel(Text("Close"))
            }
        }
    }

    // MARK: - Country

    /// A capsule segmented control built from the LIVE sellable list (never
    /// hardcoded), a menu past three countries or when three do not fit, and
    /// nothing at all for one. "Other city ›" pushes the localities.
    @ViewBuilder
    private var countryControl: some View {
        let countries = chipOrder
        VStack(alignment: .leading, spacing: RSpace.sm) {
            if countries.count > 1 {
                if countries.count <= 3 {
                    ViewThatFits(in: .horizontal) {
                        CapsuleSegmentedControl(selection: countryBinding(countries),
                                                tags: countries.map(\.countryCode)) { iso, _ in
                            HStack(spacing: 6) {
                                CodeFlag(code: iso, size: 18)
                                Text(verbatim: name(of: iso, in: countries))
                            }
                        }
                        countryMenu(countries)
                    }
                } else {
                    countryMenu(countries)
                }
            }
            if currentCountry?.hasLocalities != false {
                Button { RHaptic.select(); push(.cities) } label: {
                    HStack(spacing: 4) {
                        if let city = state.linePlaceCityLabel {
                            Text(verbatim: city).foregroundStyle(theme.text2)
                            Text(verbatim: "·").foregroundStyle(theme.text3)
                        }
                        Text("Other city").foregroundStyle(theme.text)
                        Image(systemName: RIcon.chev)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.text3)
                    }
                    .font(RFont.text(14, weight: .medium))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func name(of iso: String, in countries: [LineCountry]) -> String {
        countries.first { $0.countryCode == iso }?.displayName ?? iso
    }

    private func countryBinding(_ countries: [LineCountry]) -> Binding<String> {
        Binding(
            get: { state.lineCountry ?? Self.defaultCountryCode },
            set: { iso in
                guard iso != state.lineCountry,
                      let c = countries.first(where: { $0.countryCode == iso }) else { return }
                LineStoreSearch.selectCountry(c, state: state, api: api)
            })
    }

    private func countryMenu(_ countries: [LineCountry]) -> some View {
        Menu {
            ForEach(countries) { c in
                Button {
                    RHaptic.select()
                    guard c.countryCode != state.lineCountry else { return }
                    LineStoreSearch.selectCountry(c, state: state, api: api)
                } label: {
                    if c.countryCode == state.lineCountry {
                        Label(c.displayName, systemImage: RIcon.check)
                    } else {
                        Text(verbatim: c.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: RSpace.sm) {
                if let iso = state.lineCountry { CodeFlag(code: iso, size: 22) }
                Text(verbatim: state.linePlaceCountryLabel ?? "")
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: RSpace.sm)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, RSpace.lg)
            .frame(minHeight: 44)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
        }
    }

    // MARK: - Proof, numbers, price

    private var proofLine: some View {
        Text("Has received codes from WhatsApp, TikTok and DoorDash.")
            .font(RFont.text(13))
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Three available numbers, inline. Four states:
    /// - no session: nothing (a guest never searches — a later plan adds sign-in);
    /// - loading, or not answered yet (empty with no reason): the skeleton;
    /// - answered empty or failed: the three-cause empty state, with Try again
    ///   when the cause is unknown (a load failure must not look healthy);
    /// - answered: the grouped list and "Show different numbers".
    @ViewBuilder
    private var numbers: some View {
        if hasSession || ScreenshotMode.isActive {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                if let place = state.linePlaceLabel {
                    MicroLabel("Available now in \(place)")
                } else {
                    MicroLabel("Available now")
                }
                if state.isLoadingLineNumbers
                    || (state.lineOffers.isEmpty && state.lineUnavailableReason == nil) {
                    LineOfferSkeleton(rows: Self.visibleOffers)
                } else if state.lineOffers.isEmpty {
                    unavailable
                } else {
                    LineOfferList(offers: Array(state.lineOffers.prefix(Self.visibleOffers)),
                                  country: state.lineCountry,
                                  placeFallback: state.linePlaceLabel) { pick($0) }
                    GhostButton(label: "Show different numbers", icon: RIcon.refresh,
                                fillsWidth: false) {
                        Task { await LineStoreSearch.reload(state, api: api) }
                    }
                    .padding(.top, RSpace.xs)
                }
            }
        }
    }

    private var isFailure: Bool {
        state.lineUnavailableReason == nil || state.lineUnavailableReason == .unknown
    }

    private var unavailable: some View {
        let reason = state.lineUnavailableReason
        // A load failure offers Try again (it must not look like a healthy
        // absence); paused and "no stock" do not.
        let retry: (label: String, action: () -> Void)? = isFailure
            ? (label: String(localized: "Try again"),
               action: { Task { await LineStoreSearch.reload(state, api: api) } })
            : nil
        // A refused COUNTRY cannot be fixed by another city; paused has no
        // escape at all (every city is paused).
        let elsewhere: (label: String, action: () -> Void)? = reason == .paused
            ? nil
            : (label: reason == .countryNotSellable
                    ? String(localized: "Try another country")
                    : String(localized: "Try another city"),
               action: {
                   push(reason == .countryNotSellable
                        && state.lineCountries.offersCountryChoice ? .countries : .cities)
               })
        return EmptyState(
            icon: reason == .paused ? "pause.circle" : "phone.badge.waveform",
            title: LineUnavailableCopy.title(for: reason),
            message: LineUnavailableCopy.body(for: reason),
            tint: isFailure ? theme.fail : theme.text2,
            primary: retry,
            secondary: elsewhere)
    }

    /// The monthly price, StoreKit only (spec §4.1). "{regular}/month" leads;
    /// the intro sits beneath, only behind the eligibility gate
    /// (`monthlyIntroPriceDisplay` is nil for an ineligible Apple ID). Hidden
    /// until StoreKit answers — never a placeholder price.
    @ViewBuilder
    private var priceRow: some View {
        if let regular = subs.monthlyPriceDisplay {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(regular)/month")
                    .numberStyle(size: 20, color: theme.text)
                if let intro = subs.monthlyIntroPriceDisplay {
                    Text("\(intro) your first month · new subscribers")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var oneOffLink: some View {
        GhostButton(label: "Just need a one-off code?", action: onOpenSms)
    }

    // MARK: - Pick

    /// Tap a number → paywall (3 taps to Apple's sheet).
    private func pick(_ offer: LineNumberOffer) {
        RHaptic.select()
        Analytics.shared.track("line_number_picked", [
            "country": .string(offer.countryCode ?? state.lineCountry ?? "unknown")])
        state.lineOffer = offer
        state.intent = .line
        if state.flow == .lineStoreMore {
            // Cover → cover is not a swap SwiftUI performs reliably
            // (`fullScreenCover(item:)`), so dismiss first, raise next runloop.
            state.flow = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                state.flow = .lineCheckout
            }
        } else {
            state.flow = .lineCheckout
        }
    }
```
  (`EmptyState`'s `primary`/`secondary` are optional tuples, so passing `nil` is valid. `pickerOrder`/`sellable`/`offersCountryChoice` are in `LinePickerRows.swift`.)

- [ ] **Step 8: Fixtures.**
  - `ScreenshotMode.Screen`: change the comments to `case lineIntro       // the store while its numbers load (skeleton, no price)` and `case lineStore       // the store with three inline numbers and the StoreKit price`; add `case lineStoreError  // the store after a failed search: fail-tinted empty state, Try again`.
  - `ContentView.applyScreenshotState`: add `.lineStoreError` to the `case .lineIntro, .lineStore, .linePaywall, .linePaywallYearly:` list, and inside it add
    ```swift
                if shot == .lineIntro {
                    // No pricing shim: the price row must be HIDDEN until
                    // StoreKit answers (Review Focus 5).
                    state.isLoadingLineNumbers = true
                }
                if shot == .lineStoreError {
                    subs.screenshotPricing = .init()
                    state.lineCountry = "US"
                    state.lineOffers = []
                    state.lineUnavailableReason = .unknown
                }
    ```
    Update the `.lineStore` block's comments that mention `priceNote` and "the search that would fill them is skipped in screenshot mode (see `LineStoreScreen`'s root task)" to name `searchIfNeeded()`.

- [ ] **Step 9: Strings** — `/tmp/p2-t3.json`:

```json
{
  "A number that stays yours. Receive codes, texts and calls here.": {"de": "Eine Nummer, die Ihnen bleibt. Empfangen Sie hier Codes, SMS und Anrufe.", "es": "Un número que sigue siendo tuyo. Recibe aquí códigos, SMS y llamadas.", "fr": "Un numéro qui reste le vôtre. Recevez ici codes, SMS et appels.", "it": "Un numero che resta tuo. Ricevi qui codici, SMS e chiamate.", "ja": "ずっと使えるあなたの番号。コード、SMS、通話をここで受け取れます。", "pt-BR": "Um número que continua seu. Receba códigos, SMS e ligações aqui."},
  "Other city": {"de": "Andere Stadt", "es": "Otra ciudad", "fr": "Autre ville", "it": "Altra città", "ja": "別の都市", "pt-BR": "Outra cidade"},
  "%@/month": {"de": "%@/Monat", "es": "%@/mes", "fr": "%@/mois", "it": "%@/mese", "ja": "%@/月", "pt-BR": "%@/mês"},
  "%@ your first month · new subscribers": {"de": "%@ im ersten Monat · für Neuabonnenten", "es": "%@ el primer mes · nuevos suscriptores", "fr": "%@ le premier mois · nouveaux abonnés", "it": "%@ il primo mese · nuovi abbonati", "ja": "初月%@・新規登録の方", "pt-BR": "%@ no primeiro mês · novos assinantes"},
  "Just need a one-off code?": {"de": "Brauchen Sie nur einen einmaligen Code?", "es": "¿Solo necesitas un código puntual?", "fr": "Besoin d'un seul code ponctuel ?", "it": "Ti serve solo un codice una tantum?", "ja": "1回だけコードが必要ですか？", "pt-BR": "Só precisa de um código avulso?"}
}
```
  Existing-keys check, then `python3 scripts/xcstrings-add.py /tmp/p2-t3.json`. Expected `added/updated 5 keys`.

- [ ] **Step 10: Build + prove removals.**
  ```bash
  grep -rnE "line_choose_number_tapped|showsPicker|placeSheet|LineCountryChip|priceNote|usSoon" VirtualSIM || echo CLEAN
  ```
  Expected `CLEAN`, then `** BUILD SUCCEEDED **`.

- [ ] **Step 11: Screenshots (Review Focus 5).** `zsh …/p2-shots.sh lineStore lineIntro lineStoreError`. Expected:
  - `lineStore`: "Your own number" at 30 pt, the subtitle; a three-segment capsule control (US, Canada, Puerto Rico with flags; or a menu if they do not fit — note which); "New York · Other city ›"; the ledger (✓ Receive texts and verification codes / From US and Canadian numbers and services., ✓ Calls, ✗ Texts you send to US numbers usually don't arrive.); the proof line; "AVAILABLE NOW IN NEW YORK" and three rows `(212) 555-0128` etc. at 20 pt with places beneath in ONE grouped list; "Show different numbers"; "$5.99/month" with "$3.99 your first month · new subscribers" beneath; "Just need a one-off code?". Exactly one green element or none (no accent fills). No credit pill.
  - `lineIntro`: the same top half, three skeleton rows, **no price row**.
  - `lineStoreError`: fail-tinted "We couldn't load any numbers", **Try again** (the screen's one accent button) and "Try another city".
  Then the paused variant: temporarily change the fixture's `.unknown` to `.paused`, rebuild, capture `lineStoreError`: "Second numbers are unavailable", neutral tint, no Try again, no secondary. Revert the edit (`git diff VirtualSIM/ContentView.swift` must show only the committed fixture).

- [ ] **Step 12: Checks + commit**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 3
  git diff main --stat -- supabase VirtualSIM/Onboarding
  git add -A VirtualSIM
  git commit -m "my number: inline store — country segment, ledger, proof line, three numbers, StoreKit price, pushed place pages"
  ```

---

### Task 4: Paywall rebuild to D4

**Files:**
- Modify: `VirtualSIM/Screens/LineCheckoutScreen.swift` — replace `body` (:45–172, keeping every modifier from `.onAppear` at :110 through the `.task(id:)` at :164 verbatim), `header` (:181–239), `intro` (:243–275, delete), `numberCard` (:403–440), `holdLine` (:458–467), `included` (:483–563), `goodToKnow` (:580–657, restyle only), `planPicker`/`planRow` (:679–783), `priceBlock` (:785–849), `emergency` (:858–876, radius only), `legal` (:884–892), `cta` (:896–923), `ctaPriceSub` (:951–958, delete). Keep untouched: `cityLabel`, `country`, `numberSendsTexts`, `quoteSupportsSms`, `sendingWarningShown`, `capabilityNote` (Task 2 text), `areaCode`, `placeLine`, `busy`, `unavailable`, `ctaLabel`, `buy()`, `logExit`, `CheckoutVisit`.
- Modify: `VirtualSIM/Components/BottomBar.swift` (a `horizontalPadding` parameter)
- Modify: `VirtualSIM/Networking/Analytics.swift` (DEBUG-only echo in screenshot mode)
- Modify: `VirtualSIM/DesignSystem/ScreenshotMode.swift`, `VirtualSIM/ContentView.swift` (fixture `linePaywallUS`)
- Modify: `VirtualSIM/Localizable.xcstrings` via `/tmp/p2-t4.json`

**Interfaces:**
- Consumes: `SubscriptionStore.hasMonthly/hasYearly/isLoadingProduct/monthlyPriceDisplay/yearlyPriceDisplay/monthlyIntroPriceDisplay/selectedIntroPriceDisplay/yearlySavingsPercent/trialLabel/selectedPlan/lastFailure/lastError`, `IAPStore.restorePurchases()`, `LegalLinks.eula/privacy`, `LineLedger`, `LineLedgerRow`, `LineProduct.voiceAllowanceMinutes`, `state.appStatus.lineSwapCredits`.
- Produces: `BottomBar(scrimHeight:horizontalPadding:content:)` (default 20, so other callers are unchanged). Fixture `linePaywallUS`. Every event keeps its name and props; `CheckoutVisit` keeps its shape.

The "Held for you · m:ss" pill: `reserve-line-number` runs only inside `buy()`, after Subscribe, and a fresh search clears `lineReservation`, so on a normal open there is no hold and the pill does not render. The "Available now" pill is deleted (spec §4.2: the pill stays only where the server actually holds the number).

- [ ] **Step 1: `BottomBar` parameter.** Add `var horizontalPadding: CGFloat = 20` after `scrimHeight`, and use it in `.padding(.horizontal, horizontalPadding)`.

- [ ] **Step 2: Analytics echo (DEBUG, screenshot mode only)** — at the top of `Analytics.track(_:_:)`:
```swift
        #if DEBUG
        // Lets a simulator run prove what fired (`simctl launch --stderr=`),
        // e.g. that `line_checkout_exit` fires once. Screenshot mode only.
        if ScreenshotMode.isActive {
            NSLog("[analytics] %@ %@", name, String(describing: props ?? [:]))
        }
        #endif
```

- [ ] **Step 3: body and header.** Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion`. Replace the view part of `body` (the `ZStack { … }` at :46–109) with:

```swift
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    numberCard.riseIn(appeared, index: 0)
                    // As prominent as the price: the term most likely to be
                    // discovered after paying rather than before.
                    capabilityNote.padding(.top, RSpace.md).riseIn(appeared, index: 1)
                    whatYouGet.padding(.top, RSpace.xl).riseIn(appeared, index: 2)
                    // Choice first, then the sentence that restates it with its
                    // renewal terms (3.1.2(a)).
                    plans.padding(.top, RSpace.xl).riseIn(appeared, index: 3)
                        .id(Self.planAnchor)
                    priceSentence.padding(.top, RSpace.md).riseIn(appeared, index: 3)
                    rentalLine.padding(.top, RSpace.sm).riseIn(appeared, index: 3)
                    goodToKnow.padding(.top, RSpace.lg).riseIn(appeared, index: 4)
                    emergency.padding(.top, RSpace.lg).riseIn(appeared, index: 4)
                    links.padding(.top, RSpace.lg).riseIn(appeared, index: 5)
                }
                .padding(.horizontal, RSpace.gutter)
                .padding(.top, RSpace.lg)
                .padding(.bottom, RSpace.lg)
            }
            .scrollIndicators(.hidden)
            // Content scrolls UNDER a material header instead of being cut flat
            // by a bare HStack (audit §2.2 item 5).
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomBar(scrimHeight: 24, horizontalPadding: RSpace.gutter) { cta }
            }
            // The plan frames scroll to the plans; the US frame shows the top.
            .task {
                guard ScreenshotMode.screen == .linePaywall
                        || ScreenshotMode.screen == .linePaywallYearly else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(Self.planAnchor, anchor: .top)
            }
        }
        .background(theme.bg.ignoresSafeArea())
```
  followed, unchanged, by the existing `.onAppear { CheckoutVisit.begin() }`, `.onDisappear { … }`, `.onChange(of: scenePhase) { … }`, `.task { … line_checkout_view … }` and `.task(id: state.lineReservation?.heldUntil) { … }`.
  Replace `header` with:

```swift
    /// ✕, title, Restore on a `.bar` material. Restore lives here AND in the
    /// link row: a user who was charged and has no number is on this screen.
    private var header: some View {
        ZStack {
            Text("Your own number")
                .font(RFont.text(17, weight: .semibold))
                .foregroundStyle(theme.text)
            HStack {
                Button { state.flow = nil } label: {
                    Image(systemName: RIcon.close)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 36, height: 36)
                        .background(theme.chipBg, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScaleStyle(scale: 0.92))
                .accessibilityLabel(Text("Close"))
                Spacer()
                restoreButton
                    .font(RFont.text(15, weight: .medium))
                    .foregroundStyle(theme.text)
            }
        }
        .padding(.horizontal, RSpace.gutter)
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.sep).frame(height: 0.5)
        }
    }

    private var restoreButton: some View {
        Button(action: restore) {
            Text(isRestoring ? "Restoring…" : "Restore")
        }
        .buttonStyle(.plain)
        .disabled(isRestoring)
    }

    /// Moved verbatim from the old header's button (every comment kept).
    private func restore() {
        Task {
            isRestoring = true
            defer { isRestoring = false }
            subs.lastError = nil
            _ = await iap.restorePurchases()
            await state.loadLine(using: LineAPI(client: api))
            if state.line?.status.isLive == true {
                RHaptic.success()
                CheckoutVisit.exitVia = "restore"
                state.flow = nil
            } else if let failure = subs.lastFailure {
                RHaptic.warn()
                state.showError(failure)
            }
        }
    }
```
  Delete `intro` (:243–275). (Its body copy "Text and call US and Canadian numbers…" promised sending to US numbers, which the ledger now contradicts.)

- [ ] **Step 4: Number card, what you get.**

```swift
    /// The number being bought, flat (no shadow, spec §3 rule 1).
    private var numberCard: some View {
        VStack(spacing: RSpace.sm) {
            HStack(spacing: 6) {
                if let iso = state.lineOffer?.countryCode ?? state.lineCountry {
                    CodeFlag(code: iso, size: 18)
                }
                Text(placeLine)
                    .font(RFont.text(13, weight: .semibold))
                    .foregroundStyle(theme.text2)
            }
            Text(verbatim: PhoneFormat.national(state.lineOffer?.phoneNumber ?? ""))
                .numberStyle(size: 30, color: theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            holdLine
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RSpace.xl)
        .padding(.horizontal, RSpace.lg)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
    }

    /// Only where the server actually holds the number (spec §4.2).
    @ViewBuilder
    private var holdLine: some View {
        if let until = state.lineReservation?.heldUntil, until > now {
            StatusPill(text: "Held for you · \(PhoneFormat.duration(Int(until.timeIntervalSince(now))))")
                .contentTransition(.numericText())
        }
    }

    /// Five rows, down from nine (spec §4.2). The minutes row and the 50+
    /// countries row MUST stay: the store's "✓ Calls" carries no figures, and
    /// is honest only because these two state them before the purchase.
    /// The ✗ row is the store's, for a number that texts and is NOT US/PR
    /// (US/PR get the uncollapsed note above instead).
    private var whatYouGet: some View {
        VStack(alignment: .leading, spacing: RSpace.sm) {
            MicroLabel("What you get")
            LineLedger {
                if numberSendsTexts != false {
                    LineLedgerRow(kind: .yes,
                                  text: Text("Receive texts and verification codes"),
                                  detail: Text("From US and Canadian numbers and services."))
                }
                LineLedgerRow(kind: .yes,
                              figure: "\(LineProduct.voiceAllowanceMinutes)",
                              text: Text("minutes of outgoing calls a month"))
                LineLedgerRow(kind: .yes,
                              text: Text("Call 50+ countries, priced per minute before you dial"))
                // NO client default for the price (`line_swap_credits` moves
                // without a release). "As many times as you want" is true only
                // while `line_swap_cooldown_days` is 0.
                if let cost = state.appStatus.lineSwapCredits {
                    LineLedgerRow(kind: .yes,
                                  text: Text("Switch to a new number for only \(cost) credits — any time, as many times as you want"))
                } else {
                    LineLedgerRow(kind: .yes,
                                  text: Text("Switch to a new number any time, as many times as you want"))
                }
                if numberSendsTexts != false, !sendingWarningShown {
                    LineLedgerRow(kind: .no,
                                  text: Text("Texts you send to US numbers usually don't arrive."))
                }
            }
        }
    }
```
  (The swap keys already exist — they were the store pitch's. The old "Might not work on every service" caveat is kept in "Good to know" as "Some services refuse virtual numbers — switch to a new one and try again".)

- [ ] **Step 5: Plans, price sentence, rental line.**

```swift
    /// D4 (spec §4.2): "{regular}/month" at plan size, the intro beneath and
    /// smaller, behind the eligibility gate. Yearly is a plain second row.
    /// Only the selected plan carries a border. A single monthly row when the
    /// yearly is not offered in this storefront.
    @ViewBuilder
    private var plans: some View {
        if subs.hasMonthly || subs.isLoadingProduct {
            VStack(spacing: RSpace.sm) {
                planRow(.monthly)
                if subs.hasYearly { planRow(.yearly) }
            }
        }
    }

    private func planRow(_ plan: LinePlan) -> some View {
        let active = subs.selectedPlan == plan
        return Button { select(plan) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plan == .monthly ? "Monthly" : "Yearly")
                        .font(RFont.text(15, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if plan == .yearly, let pct = subs.yearlySavingsPercent {
                        // A text tag, never a second bordered thing (emphasis rule).
                        Text("SAVE \(pct)%")
                            .font(RFont.text(11, weight: .heavy))
                            .tracking(0.3)
                            .foregroundStyle(theme.text2)
                    }
                }
                planPrice(plan)
                planNote(plan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RSpace.lg)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
            .selectedEmphasis(active, radius: RRadius.group, color: theme.ink)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func planPrice(_ plan: LinePlan) -> some View {
        let price = plan == .monthly ? subs.monthlyPriceDisplay : subs.yearlyPriceDisplay
        if let price {
            Group {
                if plan == .monthly { Text("\(price)/month") } else { Text("\(price)/year") }
            }
            .numberStyle(size: 20, color: theme.text)
        } else {
            Text(verbatim: "—")
                .numberStyle(size: 20, color: theme.text3)
                .redacted(reason: subs.isLoadingProduct ? .placeholder : [])
        }
    }

    @ViewBuilder
    private func planNote(_ plan: LinePlan) -> some View {
        if plan == .monthly, let intro = subs.monthlyIntroPriceDisplay {
            Text("\(intro) your first month · new subscribers")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .monospacedDigit()
        } else if plan == .yearly, let trial = subs.trialLabel {
            Text("\(trial) free, then billed yearly")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
        }
    }

    /// Moved from the old `planRow` button action: only a REAL change counts.
    private func select(_ plan: LinePlan) {
        RHaptic.select()
        if subs.selectedPlan != plan {
            Analytics.shared.track("line_plan_selected", ["plan": .string(plan.rawValue)])
        }
        withAnimation(RMotion.select) { subs.selectedPlan = plan }
    }

    /// 3.1.2(a): what happens after the intro, and the renewal terms, for the
    /// SELECTED plan. The figure comes from StoreKit only.
    private var priceSentence: some View {
        Group {
            if subs.selectedPlan == .yearly {
                if let trial = subs.trialLabel, let price = subs.yearlyPriceDisplay {
                    Text("\(trial) free, then \(price). Renews every year until you cancel. Cancel any time in Settings.")
                } else {
                    Text("Renews every year until you cancel. Cancel any time in Settings.")
                }
            } else if subs.selectedIntroPriceDisplay != nil, let price = subs.monthlyPriceDisplay {
                Text("Then \(price) every month until you cancel. Cancel any time in Settings.")
            } else {
                Text("Renews every month until you cancel. Cancel any time in Settings.")
            }
        }
        .font(RFont.text(13))
        .foregroundStyle(theme.text2)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    /// True of the lapse machine: `reclaim_lapsed_lines` never releases a line
    /// before `current_period_end` (CLAUDE.md, "The lapse machine").
    private var rentalLine: some View {
        Text("Only need it for a month? Turn off renewal after buying — it stays yours until the end of the month you paid for.")
            .font(RFont.text(13))
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }
```

- [ ] **Step 6: Good to know, 911, links, CTA.**
  - `goodToKnow`: replace `MicroLabel("Good to know")` with `Text("Good to know").font(RFont.text(13, weight: .semibold)).foregroundStyle(theme.text2)` so the chevron sits beside it (audit §2.2 item 9), and the inner `Card(radius: RRadius.card, elevation: .flat) { … }` (Task 1) with `VStack(spacing: 0) { …same four rows… }.padding(.vertical, 4).background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))`. The four rows, their order, `limitsShown` and the toggle stay.
  - `emergency`: unchanged except it already uses `RRadius.group` (Task 1).
  - Replace `legal` with:

```swift
    /// 3.1.2(c): the labels NAME the documents, and they look like links
    /// (underlined, full-contrast) — the 2.0(37) rejection was links tinted
    /// like body text. One row when it fits; stacked in long locales.
    private var links: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: RSpace.sm) {
                eulaLink
                Text(verbatim: "·").foregroundStyle(theme.text3)
                privacyLink
                Text(verbatim: "·").foregroundStyle(theme.text3)
                restoreButton.underline()
            }
            VStack(alignment: .leading, spacing: RSpace.sm) {
                eulaLink
                privacyLink
                restoreButton.underline()
            }
        }
        .font(RFont.text(13, weight: .medium))
        .foregroundStyle(theme.text)
        .tint(theme.text)
    }

    private var eulaLink: some View {
        Link(destination: LegalLinks.eula) { Text("Terms of Use (EULA)").underline() }
    }

    private var privacyLink: some View {
        Link(destination: LegalLinks.privacy) { Text("Privacy Policy").underline() }
    }
```
  (`restoreButton.underline()` requires the label to be `Text`; if `Button.underline()` does not compile on iOS 18, give `restoreButton` a `underlined: Bool` parameter and apply `.underline(underlined)` to the inner `Text`.)
  - Replace `cta` with the same body minus the price sub:

```swift
    private var cta: some View {
        VStack(spacing: RSpace.sm) {
            if unavailable {
                Text("The App Store isn't offering this subscription right now. Please try again in a moment.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No typewriter price (spec §4.2): the price is stated in the plan
            // rows and the sentence above, and again on Apple's sheet.
            PrimaryButton(label: ctaLabel,
                          disabled: busy || state.lineOffer == nil || !subs.hasMonthly,
                          action: buy)
            Text("Cancel any time in Settings")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
        }
    }
```
  Delete `ctaPriceSub`, `priceBlock`, `planPicker`, the old `planRow(_:title:price:badge:note:)`, `included`.

- [ ] **Step 7: Fixture `linePaywallUS`.** `ScreenshotMode.Screen`: add `case linePaywallUS   // the TOP of the paywall on a US number: the US/PR note uncollapsed`. In `applyScreenshotState` add `.linePaywallUS` to the store/paywall case list and:
```swift
            if shot == .linePaywallUS {
                state.lineCountry = "US"
                state.lineCities = [.init(id: "new-york", label: "New York")]
                state.lineCity = "new-york"
                state.lineOffer = LineNumberOffer(phoneNumber: "+12125550128",
                                                  region: "New York, NY",
                                                  monthlyCents: 100, upfrontCents: 100,
                                                  countryCode: "US")
                state.flow = .lineCheckout
                subs.screenshotPricing = .init()
                subs.selectedPlan = .monthly
            }
```

- [ ] **Step 8: Strings** — `/tmp/p2-t4.json`:

```json
{
  "%@/year": {"de": "%@/Jahr", "es": "%@/año", "fr": "%@/an", "it": "%@/anno", "ja": "%@/年", "pt-BR": "%@/ano"},
  "Then %@ every month until you cancel. Cancel any time in Settings.": {"de": "Danach %@ pro Monat, bis Sie kündigen. Sie können jederzeit in den Einstellungen kündigen.", "es": "Después, %@ cada mes hasta que canceles. Cancela cuando quieras en Ajustes.", "fr": "Puis %@ chaque mois jusqu'à résiliation. Résiliez à tout moment dans Réglages.", "it": "Poi %@ ogni mese finché non annulli. Annulla quando vuoi in Impostazioni.", "ja": "その後は解約するまで毎月%@です。解約は「設定」からいつでも行えます。", "pt-BR": "Depois, %@ por mês até você cancelar. Cancele quando quiser em Ajustes."},
  "Renews every month until you cancel. Cancel any time in Settings.": {"de": "Verlängert sich monatlich, bis Sie kündigen. Sie können jederzeit in den Einstellungen kündigen.", "es": "Se renueva cada mes hasta que canceles. Cancela cuando quieras en Ajustes.", "fr": "Renouvelé chaque mois jusqu'à résiliation. Résiliez à tout moment dans Réglages.", "it": "Si rinnova ogni mese finché non annulli. Annulla quando vuoi in Impostazioni.", "ja": "解約するまで毎月自動更新されます。解約は「設定」からいつでも行えます。", "pt-BR": "Renova todo mês até você cancelar. Cancele quando quiser em Ajustes."},
  "Renews every year until you cancel. Cancel any time in Settings.": {"de": "Verlängert sich jährlich, bis Sie kündigen. Sie können jederzeit in den Einstellungen kündigen.", "es": "Se renueva cada año hasta que canceles. Cancela cuando quieras en Ajustes.", "fr": "Renouvelé chaque année jusqu'à résiliation. Résiliez à tout moment dans Réglages.", "it": "Si rinnova ogni anno finché non annulli. Annulla quando vuoi in Impostazioni.", "ja": "解約するまで毎年自動更新されます。解約は「設定」からいつでも行えます。", "pt-BR": "Renova todo ano até você cancelar. Cancele quando quiser em Ajustes."},
  "%@ free, then %@. Renews every year until you cancel. Cancel any time in Settings.": {"de": "%1$@ gratis, danach %2$@. Verlängert sich jährlich, bis Sie kündigen. Sie können jederzeit in den Einstellungen kündigen.", "es": "%1$@ gratis, después %2$@. Se renueva cada año hasta que canceles. Cancela cuando quieras en Ajustes.", "fr": "%1$@ gratuits, puis %2$@. Renouvelé chaque année jusqu'à résiliation. Résiliez à tout moment dans Réglages.", "it": "%1$@ gratis, poi %2$@. Si rinnova ogni anno finché non annulli. Annulla quando vuoi in Impostazioni.", "ja": "%1$@無料、その後%2$@。解約するまで毎年自動更新されます。解約は「設定」からいつでも行えます。", "pt-BR": "%1$@ grátis, depois %2$@. Renova todo ano até você cancelar. Cancele quando quiser em Ajustes."},
  "Only need it for a month? Turn off renewal after buying — it stays yours until the end of the month you paid for.": {"de": "Brauchen Sie sie nur einen Monat? Schalten Sie die Verlängerung nach dem Kauf aus – die Nummer bleibt bis zum Ende des bezahlten Monats Ihre.", "es": "¿Solo lo necesitas un mes? Desactiva la renovación después de comprar: seguirá siendo tuyo hasta el final del mes que pagaste.", "fr": "Vous n'en avez besoin que pour un mois ? Désactivez le renouvellement après l'achat — il reste à vous jusqu'à la fin du mois payé.", "it": "Ti serve solo per un mese? Disattiva il rinnovo dopo l'acquisto: resta tuo fino alla fine del mese che hai pagato.", "ja": "1か月だけ必要ですか？購入後に自動更新をオフにしてください。お支払い済みの月の終わりまで、番号はあなたのものです。", "pt-BR": "Só precisa por um mês? Desative a renovação depois de comprar — ele continua seu até o fim do mês que você pagou."}
}
```
  Existing-keys check, then run the helper. Expected `added/updated 6 keys`.

- [ ] **Step 9: Build.** Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Screenshots.** `zsh …/p2-shots.sh linePaywallUS linePaywall linePaywallYearly`. Expected:
  - `linePaywallUS` (top, not scrolled): a `.bar` header with ✕, "Your own number" and Restore; the flat number card (flag, "New York · 212", `+1 (212) 555-0128` in SF Pro at 30 pt, **no** "Available now" pill); the amber note "Texts you send from an American number often don't arrive — most US networks block them. Receiving codes and calling work normally." (no Canada sentence); "WHAT YOU GET" with four ✓ rows and no ✗ row (US gets the note instead); the sticky Subscribe with "Cancel any time in Settings" and no price sub.
  - `linePaywall` (scrolled to plans): Monthly `$5.99/month` at 20 pt with `$3.99 your first month · new subscribers` beneath; Yearly `$59.99/year` + "SAVE 17%" as text; only Monthly bordered; "Then $5.99 every month until you cancel. Cancel any time in Settings."; the rental line; "Good to know ›" with the chevron beside it; the 911 card; one link row "Terms of Use (EULA) · Privacy Policy · Restore", underlined.
  - `linePaywallYearly`: Yearly bordered, "Renews every year until you cancel. Cancel any time in Settings."
  - Count accent elements per frame: the CTA fill and the selected border only.

- [ ] **Step 11: `CheckoutVisit` does not double-fire (risk 4).**
  ```bash
  SIM=787A6027-0A86-4AE0-9412-C99DCF4CE992; BID=com.anthersystems.VirtualSIM; LOG=/tmp/p2-cv.log
  xcrun simctl terminate $SIM $BID 2>/dev/null
  xcrun simctl launch --stderr=$LOG $SIM $BID -screenshot linePaywallUS -pref.appearance dark >/dev/null
  sleep 6
  grep -c '\[analytics\] line_checkout_exit' $LOG          # expect 0: opening is not an exit
  xcrun simctl launch $SIM com.apple.Preferences >/dev/null   # backgrounds vSMS
  sleep 3
  grep '\[analytics\] line_checkout_view' $LOG | wc -l     # record it (1, or 2 — the known double build)
  grep '\[analytics\] line_checkout_exit' $LOG             # expect EXACTLY one line, containing how = background and capability_note = 1
  ```
  Then statically: `grep -c "CheckoutVisit.begin()" VirtualSIM/Screens/LineCheckoutScreen.swift` → 2; `grep -c 'track("line_checkout_exit"' …` → 1; `grep -n "logExit(how:" …` → 2 call sites (onDisappear, scenePhase background).

- [ ] **Step 12: Checks + commit**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 4
  git diff main --stat -- supabase VirtualSIM/Onboarding
  git add -A VirtualSIM
  git commit -m "my number: D4 paywall — regular price leads, intro beneath, bar header, one link row, ledger"
  ```

---

### Task 5: Subscriber home — title, number card with the Switch capsule, Messages · Calls · Number, no FAB

**Files:**
- Create: `VirtualSIM/Components/LineNumberCard.swift`
- Create: `VirtualSIM/Screens/LineNumberSegment.swift`
- Delete: `VirtualSIM/Screens/LineSettingsScreen.swift`
- Modify: `VirtualSIM/Screens/LineScreen.swift` — replace `LiveLineView` (:44–588, doc included) and the `fabBottomInset`/`fabClearance` extension (:65–75, delete); restyle `ThreadRow` (:708–810); `LineStatusBanner`, `VoiceReadinessNotice`, `LineEnv`, `PeerRef` unchanged
- Modify: `VirtualSIM/Screens/LineSwitchNumberButton.swift` (whole file)
- Modify: `VirtualSIM/Screens/LineSwapSheet.swift` (`from` parameter, `line_swap_open{from}`, `onSwapped` at success, no line reload in `perform`)
- Modify: `VirtualSIM/Screens/LineRecentsView.swift` (body :33–79, `strip` :76–83, `RecentRow` :185–332)
- Modify: `VirtualSIM/Components/PeerAvatar.swift` (`neutral` style), `VirtualSIM/Components/AllowanceStrip.swift` (neutral bar, doc), `VirtualSIM/Components/SegmentedTabs.swift` (doc comment only)
- Modify: `VirtualSIM/DesignSystem/ScreenshotMode.swift`, `VirtualSIM/ContentView.swift` (fixtures `lineInboxEmpty`, `lineCalls`, `lineNumber`, `lineBanner`, `lineInboxMulti`; `sampleLine(id:e164:status:)`, `sampleCalls`)
- Modify: `VirtualSIM/Localizable.xcstrings` via `/tmp/p2-t5.json`

**Interfaces:**
- Consumes: `CapsuleSegmentedControl` (Task 3), `LineStatusBanner`, `VoiceReadinessNotice`, `AllowanceStrip`, `PeerNameSheet`, `LineEnv`, `CallController.isVoiceAvailable/isLive/readiness/phase/activeLineId`, `AppState.threadsForSelectedLine/lineThreadsLoaded/hasMultipleLines/lineThreads/selectedLineId/contactName(for:)`.
- Produces:
  - `LineNumberCard(line: Line, swappedTo: Binding<String?>)`.
  - `LineSwitchNumberButton(line:style: .compact | .row, from: String, onSwapped: (String) -> Void)` and `static func isOffered(for: Line, state: AppState) -> Bool`.
  - `LineSwapSheet(line:cost:from:onSwapped:)`; `line_swap_open{from: "home" | "number_segment"}`.
  - `LineNumberSegment(line: Line, onSwapped: (String) -> Void)`.
  - `PeerAvatar(e164:name:size:neutral:)`.
  - Fixtures listed above.

**Spec deviations the reviewer should know (not contradictions of intent):** the card shows flag + country name + area code, not a city — `my_line` has no locality column and adding one is a backend change. Copy is a 36 pt capsule and Share a 36 pt circle, each inside a 44 pt hit area (spec §4.3 says 44 pt, §4.5 revised says "smaller"; this satisfies both). The Calls footer shows NO reset date (`showsResetDate: false`): `line.allowanceResetsAt` equals the renewal date and the owner keeps the tab plan-free (controller ruling 2026-09-24).

- [ ] **Step 1: `PeerAvatar` neutral.** Add `@Environment(\.theme) private var theme` and `var neutral: Bool = false` (after `size`). In `body`, fill `neutral ? theme.chipBg : color` and draw the initial/glyph in `neutral ? theme.text2 : .white` (`.white.opacity(0.92)` for the glyph when not neutral, as today).

- [ ] **Step 2: `LineSwitchNumberButton.swift`** (whole file):

```swift
import SwiftUI

/// "Switch" — the swap's two entry points (spec §4.5, owner 2026-09-24):
/// a compact capsule on the number card, right of the number, and a
/// "Switch number…" row in the Number segment. Both open `LineSwapSheet`.
///
/// ── No price on the control (owner decision 2026-09-05) ───────────────────
/// The price, the balance, the top-up path and "given up for good" live on
/// the sheet's LAST page, after a number is chosen, so nothing is offered
/// that `begin_line_swap` would refuse for money. The confirm page is the
/// safety net against an accidental tap.
///
/// Price rules, unchanged: `app_config.line_swap_credits` is read live and
/// has NO client default — nil HIDES the control (a sheet that cannot quote a
/// price cannot ask for money). Only an ACTIVE line swaps. Hidden, never
/// disabled.
struct LineSwitchNumberButton: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(IAPStore.self) private var iap
    @Environment(CallController.self) private var calls

    let line: Line
    var style: Style = .compact
    /// `line_swap_open.from`: "home" (the card) or "number_segment" (the row).
    let from: String
    /// The new number, reported once the sheet has gone.
    var onSwapped: (String) -> Void = { _ in }

    enum Style { case compact, row }

    @State private var choosing = false
    /// Set by the sheet the moment the cutover lands; reported on dismiss.
    @State private var completedSwap: String?

    /// The one definition of "the swap is offered", for callers that lay out
    /// around the control (the Number segment's divider).
    static func isOffered(for line: Line, state: AppState) -> Bool {
        state.appStatus.lineSwapCredits != nil && line.status == .active
    }

    var body: some View {
        if let cost = state.appStatus.lineSwapCredits, line.status == .active {
            trigger
                // The picker borrows the tab's search state; clearing it on the
                // way out keeps the store from inheriting a swap's place. The
                // line reload happens HERE, after the sheet has gone, so the
                // card's number visibly rolls to the new one (spec §3a) — the
                // sheet's own last page shows the new number meanwhile.
                .sheet(isPresented: $choosing, onDismiss: {
                    state.clearLineDraft()
                    guard let number = completedSwap else { return }
                    completedSwap = nil
                    onSwapped(number)
                    Task { await state.loadLine(using: LineAPI(client: api)) }
                }) {
                    LineSwapSheet(line: line, cost: cost, from: from) { completedSwap = $0 }
                        // 🔴 Sheet content does NOT inherit `@Observable`
                        // environment objects. `IAPStore` is what the top-up
                        // path needs, and it is a crash, not a blank screen.
                        .environment(\.theme, theme)
                        .environment(state)
                        .environment(api)
                        .environment(iap)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(theme.bg)
                }
                // A picker is not work worth preserving over a live call, and
                // a sheet would sit above the call screen (telephony trap 5).
                .onChange(of: calls.isLive) { _, live in if live { choosing = false } }
                .onAppear {
                    // Screenshot harness: the HOME instance raises the sheet.
                    if ScreenshotMode.screen == .lineSwapConfirm, from == "home" { choosing = true }
                }
        }
    }

    @ViewBuilder
    private var trigger: some View {
        switch style {
        case .compact:
            // Visible without competing (spec §4.5): neutral fill, a 1pt accent
            // border, never accent-filled — the one-green rule holds.
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Switch")
                        .font(RFont.text(15, weight: .semibold))
                }
                .foregroundStyle(theme.text)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(theme.chipBg, in: .capsule)
                .overlay(Capsule().strokeBorder(theme.ink, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle(scale: 0.95))
            .fixedSize()
            .accessibilityLabel(Text("Switch number"))
        case .row:
            Button(action: open) {
                HStack(spacing: RSpace.md) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 28)
                    Text("Switch number…")
                        .font(RFont.text(16))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: RSpace.sm)
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, RSpace.lg)
                .frame(minHeight: 52)
                .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle(scale: 0.98, dim: true))
        }
    }

    private func open() {
        RHaptic.select()
        choosing = true
    }
}
```

- [ ] **Step 3: `LineSwapSheet` changes.** Rewrite the file's first doc line `/// "Change number" — pick a new place and number…` to `/// "Switch" — pick a new place and number for a line you already rent, then pay for it in credits. Presented from `LineSwitchNumberButton` (the card's capsule or the Number segment's row).` (the Task 5 vocabulary grep looks for the quoted `"Change number"` under `Screens/`). Add `let from: String` after `cost`. In `loadInitial` change `Analytics.shared.track("line_swap_open")` to `Analytics.shared.track("line_swap_open", ["from": .string(from)])`. In `perform`, delete `await state.loadLine(using: LineAPI(client: api))` (the presenter reloads on dismiss — keep `refreshWallet`), and directly after `page = .done(result.phoneNumber)` add `onSwapped(result.phoneNumber)`. In `donePage` the Done button becomes `PrimaryButton(label: String(localized: "Done"), icon: "checkmark") { dismiss() }`. Update `onSwapped`'s doc: "Called the moment the cutover lands (so a swipe-dismiss still confirms it); the presenter reloads the line after the sheet has gone." Update `perform`'s doc paragraph about reloading accordingly.

- [ ] **Step 4: `LineNumberCard.swift`**

```swift
import SwiftUI

/// The subscriber's number (spec §4.3, §4.5): row 1 is the number in the
/// number voice with the compact "Switch" capsule on its right; row 2 is the
/// live dot, flag and country, with Copy and Share. The line switcher sits
/// beside the number for a multi-line subscriber. Flat, 20pt, no shadow.
///
/// `my_line` carries no locality, so row 2 says country and area code, not a
/// city — a city would need a backend change.
struct LineNumberCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var typeSize

    let line: Line
    /// The confirmation under the card after a swap, from either entry point.
    @Binding var swappedTo: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: RSpace.md) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: RSpace.sm) {
                    numberLine.frame(maxWidth: .infinity, alignment: .leading)
                    switchControl
                }
            } else {
                HStack(spacing: RSpace.md) {
                    numberLine.layoutPriority(1)
                    Spacer(minLength: 0)
                    switchControl
                }
            }
            HStack(spacing: RSpace.sm) {
                Circle().fill(statusTint).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                CodeFlag(code: line.countryCode, size: 20)
                Text(verbatim: placeLabel)
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                Spacer(minLength: RSpace.sm)
                copyButton
                shareButton
            }
            if let to = swappedTo {
                Text("Your new number is \(PhoneFormat.national(to)). Share it wherever you used the old one.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(RSpace.lg)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
    }

    // MARK: Row 1

    private var numberLine: some View {
        HStack(spacing: RSpace.sm) {
            Text(verbatim: PhoneFormat.national(line.e164))
                .numberStyle(size: 28, color: theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Only when there is a choice to make.
            if state.hasMultipleLines { lineSwitcher }
        }
    }

    private var switchControl: some View {
        LineSwitchNumberButton(line: line, style: .compact, from: "home") { swappedTo = $0 }
    }

    /// Moved verbatim from the old `LiveLineView.lineSwitcher` (the Menu of
    /// live lines with per-line unread, and the elsewhere-unread badge).
    private var lineSwitcher: some View {
        Menu {
            ForEach(state.lines.filter { $0.status.isLive }) { l in
                Button {
                    RHaptic.select()
                    withAnimation(RMotion.select) { state.selectedLineId = l.id }
                } label: {
                    let unread = state.lineThreads
                        .filter { $0.lineId == l.id }
                        .reduce(0) { $0 + $1.unreadCount }
                    Label(
                        unread > 0
                            ? "\(PhoneFormat.national(l.e164))  (\(unread))"
                            : PhoneFormat.national(l.e164),
                        systemImage: l.id == line.id ? RIcon.check : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text3)
                let elsewhere = state.lineThreads
                    .filter { $0.lineId != line.id }
                    .reduce(0) { $0 + $1.unreadCount }
                if elsewhere > 0 {
                    Text(verbatim: "\(elsewhere)")
                        .font(RFont.text(10, weight: .heavy))
                        .foregroundStyle(theme.bg)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.text, in: .capsule)
                }
            }
            .frame(minWidth: 28, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Row 2

    private var placeLabel: String {
        let country = Locale.current.localizedString(forRegionCode: line.countryCode) ?? line.countryCode
        let digits = line.e164.filter(\.isNumber)
        guard line.e164.hasPrefix("+1"), digits.count == 11 else { return country }
        return "\(country) · \(digits.dropFirst().prefix(3))"
    }

    /// Matches `LineStatusBanner`, which explains a fault in a sentence.
    private var statusTint: Color {
        switch line.status {
        case .active:             theme.live
        case .grace, .pastDue:    theme.warn
        case .suspended, .failed: theme.fail
        default:                  theme.text3
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 5) {
                Image(systemName: copied ? RIcon.check : RIcon.copy)
                    .font(.system(size: 12, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(RFont.text(14, weight: .semibold))
            }
            .foregroundStyle(copied ? theme.live : theme.text)
            .padding(.horizontal, RSpace.md)
            .frame(height: 36)
            .background(theme.chipBg, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .accessibilityLabel(copied ? Text("Copied") : Text("Copy number"))
    }

    private var shareButton: some View {
        ShareLink(item: PhoneFormat.national(line.e164)) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: 36, height: 36)
                .background(theme.chipBg, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .simultaneousGesture(TapGesture().onEnded { RHaptic.select() })
        .accessibilityLabel(Text("Share number"))
    }

    private func copy() {
        UIPasteboard.general.string = line.e164
        RHaptic.select()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}
```

- [ ] **Step 5: `LineNumberSegment.swift`**

```swift
import SwiftUI

/// The My number tab's third segment (spec §4.3): usage, "Switch number…",
/// "Rent another number", and the 911 disclosure. It replaces the gear's
/// `LineSettingsScreen` sheet (deleted with it).
///
/// 🔴 NO RENEWAL OR SUBSCRIPTION ROWS (owner, 2026-09-01, re-confirmed
/// 2026-09-24). Apple's manage-subscriptions sheet lives in Account only.
struct LineNumberSegment: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    let line: Line
    var onSwapped: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RSpace.xl) {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                SectionHeader(label: "Usage")
                group {
                    // Outbound texts: the allowance `begin_outbound_message`
                    // meters. Inbound is never metered and must never get a
                    // counter of its own.
                    usageRow(Text("Texts you can send"),
                             left: line.smsRemaining, of: line.smsAllowance)
                    rule
                    usageRow(Text("Minutes left"),
                             left: line.voiceMinutesRemaining,
                             of: line.voiceAllowanceSeconds / 60)
                }
            }
            group {
                if LineSwitchNumberButton.isOffered(for: line, state: state) {
                    LineSwitchNumberButton(line: line, style: .row,
                                           from: "number_segment", onSwapped: onSwapped)
                    rule
                }
                rentAnother
            }
            VStack(alignment: .leading, spacing: RSpace.sm) {
                SectionHeader(label: "Important")
                emergency
            }
        }
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }

    private var rule: some View { RowRule(inset: RSpace.lg) }

    private func usageRow(_ label: Text, left: Int, of total: Int) -> some View {
        HStack {
            label.font(RFont.text(16)).foregroundStyle(theme.text)
            Spacer(minLength: RSpace.sm)
            Text("\(left) of \(total)")
                .numberStyle(size: 16, weight: .medium, color: theme.text2)
        }
        .padding(.horizontal, RSpace.lg)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    /// The ONLY route to a second number: the tab shows the store only when
    /// there is no line at all. A cover, opened directly — there is no sheet
    /// to dismiss first any more.
    private var rentAnother: some View {
        Button {
            RHaptic.select()
            state.flow = .lineStoreMore
        } label: {
            HStack(spacing: RSpace.md) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 28)
                Text("Rent another number")
                    .font(RFont.text(16))
                    .foregroundStyle(theme.text)
                Spacer(minLength: RSpace.sm)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, RSpace.lg)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98, dim: true))
    }

    /// Unmissable, never behind a link — the same amber surface as the
    /// paywall's, so the one disclosure looks the same in both places.
    private var emergency: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.warn)
                .padding(.top, 1)
            Text("This number can't call 911 or any other emergency service. Always use your phone's own number for emergencies.")
                .font(RFont.text(13, weight: .medium))
                .foregroundStyle(theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.warnSoft, in: .rect(cornerRadius: RRadius.group, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                .strokeBorder(theme.warn.opacity(0.28), lineWidth: 1)
        }
    }
}
```
  Then `git rm VirtualSIM/Screens/LineSettingsScreen.swift`.

- [ ] **Step 6: `LiveLineView`** (replace :44–588 and delete the FAB extension :65–75):

```swift
/// A live line (spec §4.3): the title, the number card, the status banners,
/// and Messages · Calls · Number. No FAB — compose and the keypad are the
/// header's one trailing button, and the Switch capsule is on the card.
///
/// `LineStatusBanner` and `VoiceReadinessNotice` stay directly under the card
/// and never move into a segment: they are honesty surfaces, and a fault the
/// user has to go looking for is a fault they learn about from a stranger.
private struct LiveLineView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @Environment(CallController.self) private var calling
    /// Threaded through `LineEnv` for `PeerNameSheet`.
    @Environment(IAPStore.self) private var iap

    let line: Line

    enum Seg: CaseIterable, Hashable { case messages, calls, number }

    /// Opens on Messages: inbound SMS is the half that demonstrably works.
    @State private var seg: Seg = LiveLineView.initialSeg
    @State private var naming: PeerRef?
    @State private var swappedTo: String?

    /// Screenshot harness: `lineCalls` / `lineNumber` open on their segment.
    private static var initialSeg: Seg {
        switch ScreenshotMode.screen {
        case .lineCalls:  .calls
        case .lineNumber: .number
        default:          .messages
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                LineNumberCard(line: line, swappedTo: $swappedTo)
                    .padding(.top, RSpace.lg)
                LineStatusBanner(line: line)
                VoiceReadinessNotice(readiness: calling.readiness)
                if line.status.isSettingUp {
                    provisioning
                } else {
                    CapsuleSegmentedControl(selection: $seg, tags: Seg.allCases) { tag, _ in
                        segmentLabel(tag)
                    }
                    .padding(.top, RSpace.xl)
                    segmentContent
                        .padding(.top, RSpace.lg)
                }
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.bottom, RSpace.xxl)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg.ignoresSafeArea())
        .sheet(item: $naming) { peer in
            PeerNameSheet(e164: peer.id)
                .modifier(LineEnv(theme: theme, state: state, api: api,
                                  subs: subs, calling: calling, iap: iap))
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        // ↓ keep VERBATIM from the old LiveLineView, comments included:
        //   the `.task` (threads + calls, registerForVoIPPushes, prepareVoice),
        //   the `.onChange(of: calling.phase)` allowance refresh,
        //   `.onAppear { calling.activeLineId = line.id }`.
        .onChange(of: line.id) { _, id in
            calling.activeLineId = id
            swappedTo = nil
        }
        // A name sheet would sit above the call screen (telephony trap 5).
        .onChange(of: calling.isLive) { _, live in if live { naming = nil } }
    }

    private var unreadCount: Int {
        state.threadsForSelectedLine.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("My number")
                .displayType(30)
                .foregroundStyle(theme.text)
            Spacer(minLength: RSpace.md)
            headerAction
        }
        .padding(.top, RSpace.lg)
    }

    /// The segment's one action. 🔴 The keypad is HIDDEN, never disabled,
    /// without a voice client: a disabled button still advertises a
    /// capability the build lacks. Compose has no such gate — every refusal
    /// `send-line-message` can make is stated inside `ComposeScreen`.
    @ViewBuilder
    private var headerAction: some View {
        switch seg {
        case .messages:
            roundButton(icon: "square.and.pencil", label: Text("New message")) {
                state.flow = .compose
            }
        case .calls:
            if calling.isVoiceAvailable {
                roundButton(icon: "circle.grid.3x3.fill", label: Text("Make a call")) {
                    state.flow = .dialer
                }
            }
        case .number:
            EmptyView()
        }
    }

    private func roundButton(icon: String, label: Text,
                             action: @escaping () -> Void) -> some View {
        Button {
            RHaptic.select()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: 44, height: 44)
                .background(theme.chipBg, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    // MARK: Segments

    @ViewBuilder
    private func segmentLabel(_ tag: Seg) -> some View {
        switch tag {
        case .messages:
            HStack(spacing: 5) {
                Text("Messages")
                if unreadCount > 0 {
                    Text(verbatim: "\(unreadCount)")
                        .monospacedDigit()
                        .foregroundStyle(theme.text2)
                }
            }
        case .calls:  Text("Calls")
        case .number: Text("Number")
        }
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch seg {
        case .messages: messages
        case .calls:    LineRecentsView(line: line)
        case .number:   LineNumberSegment(line: line) { swappedTo = $0 }
        }
    }

    // MARK: Provisioning

    /// The number exists but is not usable yet (orders are asynchronous).
    private var provisioning: some View {
        VStack(spacing: RSpace.sm) {
            ProgressView()
            Text("Setting up your number")
                .font(RFont.text(16, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("This usually takes a few seconds. You can leave this screen, and we'll let you know when it's ready.")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, RSpace.xxl)
    }

    // MARK: Messages

    /// One inset-grouped list (spec §4.3). The empty state names no service:
    /// the old proof-of-life card's "and most other apps" was unmeasured.
    /// Rendered only once the first read has answered (the 2026-09-06 flash).
    @ViewBuilder
    private var messages: some View {
        let threads = state.threadsForSelectedLine
        if threads.isEmpty {
            if state.lineThreadsLoaded {
                VStack(spacing: RSpace.sm) {
                    Image(systemName: RIcon.message)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.text3)
                    Text("Codes and texts sent to this number appear here.")
                        .font(RFont.text(15))
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, RSpace.xxl)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(threads) { thread in
                    if thread.id != threads.first?.id {
                        RowRule(inset: RSpace.lg + 40 + RSpace.md)
                    }
                    ThreadRow(
                        thread: thread,
                        name: state.contactName(for: thread.peerE164),
                        onAddName: { naming = PeerRef(id: thread.peerE164) },
                        onCopy: { UIPasteboard.general.string = thread.peerE164
                                  RHaptic.select() },
                        onTap: {
                            state.openThreadId = thread.id
                            state.flow = .thread       // Task 6 turns this into a push
                        })
                }
            }
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
        }
    }
}
```
  **`ThreadRow` restyle** (same public API): `PeerAvatar(e164: thread.peerE164, name: name, size: 40, neutral: true)`; the code chip `Text(verbatim: code).numberStyle(size: 13, weight: .bold, color: theme.text)` on `theme.chipBg` (radius 6); unread dot `Circle().fill(theme.text).frame(width: 8, height: 8)`; replace `.padding(14).background(theme.elev, in: .rect(cornerRadius: RRadius.group))` with `.padding(.horizontal, RSpace.lg).padding(.vertical, RSpace.md)` (the list draws the group). Update its doc comment "Starting a NEW conversation is the Messages FAB" → "…is the header's compose button".

- [ ] **Step 7: `LineRecentsView`** — the parent now scrolls, so its own `ScrollView` goes. Replace `body` and delete `strip`:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: RSpace.lg) {
            if calls.isEmpty {
                EmptyState(icon: RIcon.phone,
                           title: "No calls yet",
                           message: "Calls you make and receive on this number appear here.",
                           tint: theme.text2)
            } else {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: RSpace.sm) {
                        dayHeader(day.date)
                        VStack(spacing: 0) {
                            ForEach(day.calls) { call in
                                if call.id != day.calls.first?.id {
                                    RowRule(inset: RSpace.lg + 40 + RSpace.md)
                                }
                                RecentRow(
                                    call: call,
                                    name: state.contactName(for: call.peerE164),
                                    isExpanded: expanded == call.id,
                                    canCall: calling.isVoiceAvailable,
                                    thread: thread(for: call.peerE164),
                                    justCopied: copied == call.id,
                                    onTap: { toggle(call) },
                                    onCallBack: { callBack(call) },
                                    onOpenThread: { open(thread(for: call.peerE164)) },
                                    onCopy: { copy(call) },
                                    onAddName: { naming = PeerRef(id: call.peerE164) })
                            }
                        }
                        .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
                    }
                }
            }
            allowanceFooter
        }
        .sheet(item: $naming) { peer in
            PeerNameSheet(e164: peer.id)
                .modifier(LineEnv(theme: theme, state: state, api: api,
                                  subs: subs, calling: calling, iap: iap))
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .onChange(of: calling.isLive) { _, live in if live { naming = nil } }
    }

    /// Minutes left. NO reset date: `allowanceResetsAt` is the renewal date,
    /// and the owner keeps this tab plan-free (ruling 2026-09-24). The meter
    /// meters calls, so it stays in Calls.
    private var allowanceFooter: some View {
        AllowanceStrip(line: line, showsResetDate: false)
            .padding(RSpace.lg)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }
```
  Update the struct doc ("The minutes meter stays at the top of THIS segment" → "…at the foot of this segment"). In `dayHeader` keep the logic, set `.padding(.horizontal, RSpace.xs)`. **`RecentRow`**: avatar `PeerAvatar(…, size: 40, neutral: true)`; the name always `theme.text` (a missed call shows a red GLYPH, not a red name, spec §4.3); the glyph keeps `call.status.isMissed ? theme.fail : theme.text3`; delete the row's `.background(theme.elev, in: .rect(cornerRadius: RRadius.group))`; padding `RSpace.lg` horizontal / `RSpace.md` vertical; expanded area padding `RSpace.lg`. The call-back glyph and tile stay behind `canCall` (hidden, never disabled).

- [ ] **Step 8: `AllowanceStrip`** — healthy tint `theme.ink` → `theme.text2` in both `tint(_:)` and `AllowanceBar.tint` (one green; amber/red thresholds unchanged). Rewrite the `showsResetDate` doc: "OFF on the My number tab's Calls footer: the reset date IS the renewal date, and the tab is plan-free (owner, 2026-09-24)." In the long "THERE IS NO texts left GAUGE HERE" comment, replace the last paragraph's rationale with: "The count is shown in the Number segment's Usage group (`LineNumberSegment`, 'Texts you can send') and, at ≤ 10, under the composer. Never an INBOUND counter." `SegmentedTabs.swift` doc: replace "the Number tab's Messages/Calls/Number" with "(the My number tab uses `CapsuleSegmentedControl` since 2026-09-24)".

- [ ] **Step 9: Fixtures.** In `ScreenshotMode` (DEBUG extension) turn `sampleLine` into a factory and add calls:

```swift
    static var sampleLine: Line { sampleLine() }

    /// The sample line with another id / number / status (multi-line and
    /// banner frames). Same body as before; only these three vary.
    static func sampleLine(id: String = "sample-line",
                           e164: String = "+12125550128",
                           status: LineStatus = .active) -> Line {
        let now = Date()
        return Line(
            id: id, e164: e164, countryCode: "US", numberType: "local",
            status: status,
            // …every other field exactly as the current `sampleLine` body,
            // including `lastSuccessAt: nil` and its 🔴 comment…
        )
    }

    /// Four calls across two days: a missed one (red glyph), an outgoing one
    /// with a settled duration, an incoming one, one awaiting its CDR.
    static var sampleCalls: [LineCall] {
        let now = Date()
        func call(_ id: String, _ dir: LineCallDirection, _ peer: String,
                  _ status: LineCallStatus, ago: TimeInterval, secs: Int?) -> LineCall {
            LineCall(id: id, lineId: "sample-line", direction: dir, peerE164: peer,
                     status: status, startedAt: now.addingTimeInterval(-ago),
                     answeredAt: secs == nil ? nil : now.addingTimeInterval(-ago + 5),
                     endedAt: secs.map { now.addingTimeInterval(-ago + 5 + Double($0)) },
                     durationSeconds: secs, billedSeconds: secs,
                     createdAt: now.addingTimeInterval(-ago))
        }
        return [
            call("c1", .inbound,  "+13105550199", .missed,    ago: 900,     secs: nil),
            call("c2", .outbound, "+13125550144", .completed, ago: 5_400,   secs: 142),
            call("c3", .inbound,  "+13105550199", .completed, ago: 90_000,  secs: 63),
            call("c4", .outbound, "+18885550111", .completed, ago: 93_600,  secs: nil),
        ]
    }
```
  (Check `LineCall`'s memberwise order against `LineModels.swift:310–326` and adapt the call.) `ScreenshotMode.Screen` cases:
  ```swift
          case lineInboxEmpty  // a live line with no conversations yet
          case lineCalls       // the Calls segment with sample history and the minutes footer
          case lineNumber      // the Number segment: usage, Switch number…, Rent another, 911
          case lineBanner      // a PAST-DUE line: the banner under the card, no Switch
          case lineInboxMulti  // two live lines: the switcher and its elsewhere-unread badge
  ```
  In `applyScreenshotState`, after `.lineInbox`:
  ```swift
          case .lineInboxEmpty:
              state.tab = .line
              state.lines = [ScreenshotMode.sampleLine]
              state.lineThreads = []
              state.lineThreadsLoaded = true
              state.appStatus = AppStatus(announcement: nil, esimPaused: false, lineSwapCredits: 8)
          case .lineCalls, .lineNumber:
              state.tab = .line
              state.lines = [ScreenshotMode.sampleLine]
              state.lineThreads = ScreenshotMode.sampleThreads
              state.lineCalls = ScreenshotMode.sampleCalls
              state.appStatus = AppStatus(announcement: nil, esimPaused: false, lineSwapCredits: 8)
          case .lineBanner:
              state.tab = .line
              state.lines = [ScreenshotMode.sampleLine(status: .pastDue)]
              state.lineThreads = ScreenshotMode.sampleThreads
              state.appStatus = AppStatus(announcement: nil, esimPaused: false, lineSwapCredits: 8)
          case .lineInboxMulti:
              state.tab = .line
              state.lines = [ScreenshotMode.sampleLine,
                             ScreenshotMode.sampleLine(id: "sample-line-2", e164: "+13125550177")]
              state.lineThreads = ScreenshotMode.sampleThreads + [
                  LineThread(id: "t4", lineId: "sample-line-2", peerE164: "+18885550122",
                             lastMessageAt: Date().addingTimeInterval(-60),
                             lastPreview: "Your code is 482913", unreadCount: 1,
                             blocked: false, createdAt: Date().addingTimeInterval(-600))]
              state.appStatus = AppStatus(announcement: nil, esimPaused: false, lineSwapCredits: 8)
  ```
  (`lineThreadsLoaded` is set by `loadLineThreads`' screenshot early return too; setting it here keeps the empty frame independent of task timing.)

- [ ] **Step 10: Strings** — `/tmp/p2-t5.json`:

```json
{
  "Switch": {"de": "Wechseln", "es": "Cambiar", "fr": "Changer", "it": "Cambia", "ja": "切り替え", "pt-BR": "Trocar"},
  "Switch number…": {"de": "Nummer wechseln…", "es": "Cambiar número…", "fr": "Changer de numéro…", "it": "Cambia numero…", "ja": "番号を切り替え…", "pt-BR": "Trocar número…"},
  "Codes and texts sent to this number appear here.": {"de": "Codes und SMS an diese Nummer erscheinen hier.", "es": "Los códigos y SMS enviados a este número aparecen aquí.", "fr": "Les codes et SMS envoyés à ce numéro apparaissent ici.", "it": "Codici e SMS inviati a questo numero compaiono qui.", "ja": "この番号に届いたコードとSMSはここに表示されます。", "pt-BR": "Códigos e SMS enviados para este número aparecem aqui."},
  "Texts you can send": {"de": "SMS, die Sie senden können", "es": "SMS que puedes enviar", "fr": "SMS que vous pouvez envoyer", "it": "SMS che puoi inviare", "ja": "送信できるSMS", "pt-BR": "SMS que você pode enviar"},
  "%lld of %lld": {"de": "%1$lld von %2$lld", "es": "%1$lld de %2$lld", "fr": "%1$lld sur %2$lld", "it": "%1$lld su %2$lld", "ja": "%2$lld中%1$lld", "pt-BR": "%1$lld de %2$lld"},
  "Share number": {"de": "Nummer teilen", "es": "Compartir número", "fr": "Partager le numéro", "it": "Condividi numero", "ja": "番号を共有", "pt-BR": "Compartilhar número"},
  "Usage": {"de": "Nutzung", "es": "Uso", "fr": "Utilisation", "it": "Utilizzo", "ja": "利用状況", "pt-BR": "Uso"}
}
```
  Existing-keys check (expect "Switch number", "Messages", "Calls", "Number", "Minutes left", "Important", "Rent another number", "Copy", "Copied", "Copy number", "New message", "Make a call", "My number" to exist already and not be in this file), then run the helper. Expected `added/updated 7 keys`.

- [ ] **Step 11: Build + prove removals.**
  ```bash
  grep -rnE "LineSettingsScreen|fabClearance|fabBottomInset|actionFAB|showingSettings|pendingRentAnother|proofOfLife|\"Change number\"" VirtualSIM || echo CLEAN
  ```
  Expected `CLEAN`, then `** BUILD SUCCEEDED **`.

- [ ] **Step 12: Screenshots (Review Focus 3, 4).** `zsh …/p2-shots.sh lineInbox lineInboxEmpty lineCalls lineNumber lineBanner lineInboxMulti lineSwapConfirm`. Expected:
  - `lineInbox`: "My number" at 30 pt with a neutral compose circle top-right; the card: `+1 (212) 555-0128` at 28 pt and the **Switch** capsule (neutral fill, thin accent border) on the SAME row; row 2 "● 🇺🇸 United States · 212", Copy, Share; the capsule segments Messages 2 · Calls · Number; ONE grouped thread list with neutral avatars, bold title + dot for unread, the code chip `123456` neutral. No FAB. No accent fill anywhere.
  - `lineInboxEmpty`: the card, then "Codes and texts sent to this number appear here." — the Switch capsule is the strongest control.
  - `lineCalls`: the keypad circle top-right; "Today" / "Yesterday" groups; the missed call's glyph red and its name NOT red; call-back glyphs neutral; the minutes footer with a neutral bar and NO "Resets …" date.
  - `lineNumber`: no header button; USAGE (Texts you can send 142 of 200, Minutes left 78 of 100), "Switch number…" and "Rent another number" rows, IMPORTANT with the amber 911 card. No renewal, no subscription row.
  - `lineBanner`: the past-due banner directly under the card; **no Switch capsule**; segments present.
  - `lineInboxMulti`: the switcher chevron beside the number with a "1" badge.
  - `lineSwapConfirm`: the confirm page still opens (from the card instance only — one sheet).
  **Review Focus 2 (no voice client):** temporarily change `AuthGate.swift`'s `calls.attach(api: api, voice: TelnyxVoiceClient())` to `calls.attach(api: api)`, rebuild, capture `lineCalls` and `lineInbox`: no keypad button on Calls, no call-back glyphs; compose still present. Revert (`git diff VirtualSIM/Auth` prints nothing).

- [ ] **Step 13: Checks + commit**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 5
  git diff main --stat -- supabase VirtualSIM/Onboarding
  git add -A VirtualSIM
  git commit -m "my number: subscriber home — title, number card with Switch, Messages · Calls · Number, no FAB"
  ```

---

### Task 5a: Motion pass (spec §3a)

**Files:**
- Modify: `VirtualSIM/Components/LineNumberCard.swift`, `VirtualSIM/Screens/LineScreen.swift` (`LiveLineView`), `VirtualSIM/Components/LinePickerRows.swift` (`LineOfferList`, `LineOfferSkeleton`), `VirtualSIM/Screens/LineStoreScreen.swift` (`numbers`), `VirtualSIM/Screens/LineCheckoutScreen.swift` (`planRow`, `priceSentence`, `select`), `VirtualSIM/Screens/ThreadScreen.swift` (`transcript`, `MessageBubble`)

**Interfaces:**
- Consumes: `RMotion.standard`, `RMotion.content`, `RMotion.select`, `RMotion.stagger`, `RMotion.unlessReduced`, `riseIn`, `.shimmer()`.
- Produces: `LiveDot(tint:pulses:)` (in `LineNumberCard.swift`). No behaviour change beyond motion.

Every item reads `@Environment(\.accessibilityReduceMotion) private var reduceMotion` (add it to each view that lacks it) and goes through `RMotion.unlessReduced`. No confetti, no decorative loop other than the live dot, nothing that delays a tap.

- [ ] **Step 1: Number card.** In `LineNumberCard` add `@Environment(\.accessibilityReduceMotion) private var reduceMotion`, `@State private var appeared = false`, `@State private var glow: Double = 0`, `@State private var copyTick = 0`.
  - Rise in (first appearance only — `TabView` keeps the view, so `appeared` survives tab switches): on the outer `VStack` after `.background(…)`:
    ```swift
            .overlay {
                RoundedRectangle(cornerRadius: RRadius.card, style: .continuous)
                    .strokeBorder(theme.live.opacity(glow), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .onAppear {
                guard !appeared else { return }
                withAnimation(RMotion.unlessReduced(RMotion.standard, reduceMotion)) { appeared = true }
            }
            // Switch success: a short mint glow (0.6 → 0 over 1.2s). The roll
            // itself is the number's `.animation(value: line.e164)` below —
            // the line reloads only after the swap sheet has gone.
            .onChange(of: swappedTo) { _, new in
                guard new != nil, !reduceMotion else { return }
                glow = 0.6
                withAnimation(.easeOut(duration: 1.2)) { glow = 0 }
            }
    ```
  - Number roll: on the `Text(verbatim: PhoneFormat.national(line.e164))` in `numberLine` add `.animation(RMotion.unlessReduced(RMotion.standard, reduceMotion), value: line.e164)` (`numberStyle` already sets `.contentTransition(.numericText())`). The success haptic is already fired by `LineSwapSheet.perform` at the moment of success; do not fire a second one.
  - Live dot: replace row 2's `Circle().fill(statusTint)…` with `LiveDot(tint: statusTint, pulses: line.status == .active)` and add at file scope:
    ```swift
    /// The status dot. Pulses gently (2s ease-in-out opacity loop) while the
    /// line is live — the tab's ONE looping animation (spec §3a). Still under
    /// Reduce Motion.
    struct LiveDot: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let tint: Color
        let pulses: Bool
        @State private var dim = false

        var body: some View {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .opacity(dim ? 0.35 : 1)
                .animation(pulses && !reduceMotion
                           ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                           : nil,
                           value: dim)
                .onAppear { dim = pulses && !reduceMotion }
                .onChange(of: pulses) { _, p in dim = p && !reduceMotion }
                .onChange(of: reduceMotion) { _, r in dim = pulses && !r }
                .accessibilityHidden(true)
        }
    }
    ```
  - Copy: in `copyButton` put `.contentTransition(.symbolEffect(.replace))` and `.symbolEffect(.bounce, value: reduceMotion ? 0 : copyTick)` on the `Image`; in `copy()` replace `copied = true` / `copied = false` with `withAnimation(RMotion.unlessReduced(RMotion.select, reduceMotion)) { copied = true }` (same for false) and add `copyTick += 1` before it.

- [ ] **Step 2: Segments.** In `LiveLineView` add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` and `@State private var segDirection: CGFloat = 1`. Pass `selection: segBinding` instead of `$seg`:
  ```swift
    /// Direction is set in the SAME transaction as the selection, so the
    /// insertion transition reads the new direction, not the previous one.
    private var segBinding: Binding<Seg> {
        Binding(get: { seg }, set: { new in
            let all = Seg.allCases
            segDirection = (all.firstIndex(of: new) ?? 0) > (all.firstIndex(of: seg) ?? 0) ? 1 : -1
            seg = new
        })
    }
  ```
  Wrap `segmentContent` as `ZStack { segmentContent }` and give each case's view `.transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 8 * segDirection)), removal: .opacity.combined(with: .offset(x: -8 * segDirection))))`. (`CapsuleSegmentedControl` already changes the selection inside `withAnimation(RMotion.unlessReduced(RMotion.standard, …))`, so the capsule glides and the content crossfades-and-slides together; under Reduce Motion both are instant.)

- [ ] **Step 3: Lists.** In `LiveLineView.messages`: add `@State private var listShown = false`; on each `ThreadRow` add `.riseIn(listShown, index: index)` where `index` is `threads.firstIndex(of: thread) ?? 0` (the stagger caps at 8), `.transition(.move(edge: .top).combined(with: .opacity))`; on the list `VStack` add `.animation(RMotion.unlessReduced(RMotion.standard, reduceMotion), value: threads.map(\.id))` and `.onAppear { listShown = true }`. On the `ScrollView` add
  ```swift
        // Pull to refresh reloads the line and its threads (and calls, which
        // the Calls segment reads).
        .refreshable {
            async let l: () = state.loadLine(using: LineAPI(client: api))
            async let t: () = state.loadLineThreads(using: LineAPI(client: api))
            async let c: () = state.loadLineCalls(using: LineAPI(client: api))
            _ = await (l, t, c)
        }
  ```

- [ ] **Step 4: Store.** `LineOfferList`: add `@State private var shown = false`; each `LineOfferRow` gets `.riseIn(shown, index: offers.firstIndex(of: offer) ?? 0)`; the `VStack` gets `.onAppear { shown = true }` (a reload replaces the list with the skeleton and back, so the stagger replays). `LineOfferSkeleton`: add `.shimmer()` to the grouped container (`Shimmer` already skips under Reduce Motion). `LineStoreScreen.numbers`: give the three branches `.transition(.opacity)` and add to the section `VStack` `.animation(RMotion.unlessReduced(RMotion.content, reduceMotion), value: state.isLoadingLineNumbers)` so changing country or "Show different numbers" crossfades skeleton ↔ list. `LineOfferRow` already scales to 0.98 on press.

- [ ] **Step 5: Paywall.** In `LineCheckoutScreen` add `@Namespace private var planNS`. In `planRow` replace `.background(theme.elev, in: …)` + `.selectedEmphasis(…)` with:
  ```swift
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                        .fill(theme.elev)
                    if active {
                        // One border that springs between rows (spec §3a).
                        RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                            .strokeBorder(theme.ink, lineWidth: 1)
                            .matchedGeometryEffect(id: "planBorder", in: planNS)
                    }
                }
            }
  ```
  In `select(_:)` use `withAnimation(RMotion.unlessReduced(RMotion.standard, reduceMotion)) { subs.selectedPlan = plan }`. On `priceSentence` add `.contentTransition(.numericText())` and `.animation(RMotion.unlessReduced(RMotion.standard, reduceMotion), value: subs.selectedPlan)`.

- [ ] **Step 6: Thread.** In `ThreadScreen.transcript` add to each `MessageBubble(…)`:
  `.transition(.scale(scale: 0.94, anchor: row.message.isOutbound ? .bottomTrailing : .bottomLeading).combined(with: .opacity))`, and to the `LazyVStack` `.animation(RMotion.unlessReduced(RMotion.standard, reduceMotion), value: messages.count)` (add the environment read to `ThreadScreen`). In `MessageBubble` add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` and `@State private var copyTick = 0`; the chip's `Image` gets `.contentTransition(.symbolEffect(.replace))` and `.symbolEffect(.bounce, value: reduceMotion ? 0 : copyTick)`; its tap does `copyTick += 1` and uses `withAnimation(RMotion.unlessReduced(RMotion.select, reduceMotion))`.

- [ ] **Step 7: Build.** Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Reduce Motion audit (risk 7).**
  ```bash
  grep -nE "withAnimation\(|\.animation\(|repeatForever|symbolEffect|matchedGeometryEffect" \
    VirtualSIM/Components/LineNumberCard.swift VirtualSIM/Components/CapsuleSegmentedControl.swift \
    VirtualSIM/Components/LinePickerRows.swift VirtualSIM/Screens/LineScreen.swift \
    VirtualSIM/Screens/LineStoreScreen.swift VirtualSIM/Screens/LineCheckoutScreen.swift \
    VirtualSIM/Screens/ThreadScreen.swift
  ```
  Every hit added by Tasks 3–5a must either pass through `unlessReduced`, sit behind `!reduceMotion`, or use a `reduceMotion ? 0 : tick` value. Pre-existing untouched animations (e.g. `goodToKnow`'s panel toggle, the thread's scroll-to-bottom) are outside §3a and stay. `repeatForever` may appear only in `LiveDot` and `Shimmer`. Then best effort on the simulator: `xcrun simctl spawn 787A6027-0A86-4AE0-9412-C99DCF4CE992 defaults write com.apple.Accessibility ReduceMotionEnabled -bool true`, capture `lineInbox` and `lineStore`, confirm the frames match the motion-on frames (no offset left behind), then set it back to `false`. If the simulator ignores the setting, record "Reduce Motion: code-verified only" in the commit body.

- [ ] **Step 9: Screenshots.** `zsh …/p2-shots.sh lineInbox lineStore linePaywall thread`. Expected: identical layouts to Tasks 3–5 (motion is not visible in a still; the frames prove nothing regressed and the entrances settle).

- [ ] **Step 10: Checks + commit**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 5
  git diff main --stat -- supabase VirtualSIM/Onboarding
  git add -A VirtualSIM
  git commit -m "my number: motion — card rise and live dot, Switch roll and glow, gliding segments, list stagger, plan border, bubbles"
  ```

---

### Task 6: Thread and compose pushed on the stack; push-notification routing

**Files:**
- Modify: `VirtualSIM/State/AppState.swift` — `FlowStage` (:26–56: remove `thread`, `compose`), `flow.didSet` (:494–530: remove `openThreadId = nil`), `openThreadId` doc (:730), `LineRoute` (+ `thread(String)`, `compose`), new `openLineThread(_:)`
- Modify: `VirtualSIM/Screens/LineScreen.swift` (`lineRouteDestinations`, `LiveLineView` compose button and `ThreadRow.onTap`)
- Modify: `VirtualSIM/Screens/ThreadScreen.swift` (init, `thread`/`messages`, header → toolbar, tasks, `callPeer`, `send`, composer footer)
- Modify: `VirtualSIM/Screens/ComposeScreen.swift` (header → nav title, success → replace the pushed route)
- Modify: `VirtualSIM/Screens/LineRecentsView.swift` (`open(_:)`)
- Modify: `VirtualSIM/ContentView.swift` — push handler (:463–483), `flowContent` (`case .thread`, `case .compose` :743–746 deleted), fixtures `thread`, new `lineInCall`, `linePushThread`
- Modify: `VirtualSIM/Calling/CallController.swift` (DEBUG `screenshotLiveCall(peer:)`)
- Modify: `VirtualSIM/DesignSystem/ScreenshotMode.swift` (cases)

**Interfaces:**
- Produces: `LineRoute.thread(String)`, `LineRoute.compose`; `AppState.openLineThread(_ threadId: String)`; `ThreadScreen(threadId: String)`; `CallController.screenshotLiveCall(peer:)` (DEBUG); fixtures `lineInCall`, `linePushThread`.
- Consumes: `PushManager.pendingLineThreadId`, `AppState.sendLineMessage(using:to:text:)` (unchanged — it still takes the sending line from `openThreadId`), `LineEnv`, `InCallOverlay` (unchanged).
- Removes: `FlowStage.thread`, `FlowStage.compose`.

**How `InCallOverlay` stays on top (telephony.md trap 5).** The root copy renders while `state.flow == nil`; a pushed thread or compose is NOT a flow, so the root overlay (an `.overlay` on the `TabView`) now covers them, tab bar included. Covers (dialer, paywall, provisioning) keep their own copy. Sheets are the gap trap 5 already names: every sheet the tab can raise (peer name, swap) is dismissed on `calls.isLive` (Task 5 and Step 3 below). Step 8 proves the pushed-thread case on the simulator.

- [ ] **Step 1: State.** In `FlowStage` change `case lineCheckout, lineProvisioning, thread, dialer` to `case lineCheckout, lineProvisioning, dialer`, delete `case compose` and its doc, and rewrite the doc above: "The rented line's covers. The thread and compose are PUSHED on the My number stack (`LineRoute`) since 2026-09-24, so the back swipe works and the tab bar stays; the dialer stays a cover." In `flow.didSet` delete `openThreadId = nil` and add in its place: "`openThreadId` is no longer a cover's: `ThreadScreen` sets it on appear and before every send, and clears it on disappear." Change `openThreadId`'s doc to: "The conversation on screen, for `sendLineMessage`'s choice of sending line. Set by `ThreadScreen` (appear and every send), cleared by it on disappear, nil'd by `ComposeScreen` on open." Extend `LineRoute`:
  ```swift
      /// A conversation, by `LineThread.id`.
      case thread(String)
      /// A new conversation.
      case compose
  ```
  Add next to `openCodeStore`:
  ```swift
    /// Open one conversation in the My number tab, from anywhere — a push, a
    /// fixture. Closes any cover first: the thread used to BE a cover
    /// (`flow = .thread`), which replaced whatever was up, and a push tapped
    /// over a checkout must still land on the conversation.
    func openLineThread(_ threadId: String) {
        flow = nil
        tab = .line
        intent = .line
        linePath = [.thread(threadId)]
    }
  ```

- [ ] **Step 2: Destinations and entry points.** In `lineRouteDestinations()` add `case .thread(let id): ThreadScreen(threadId: id)` and `case .compose: ComposeScreen()`. In `LiveLineView.headerAction` replace `state.flow = .compose` with `state.linePath.append(.compose)`; in `messages` replace the `onTap` body with `state.linePath.append(.thread(thread.id))`. In `LineRecentsView.open(_:)` replace the two `state.openThreadId = …; state.flow = .thread` lines with `state.linePath.append(.thread(thread.id))`.

- [ ] **Step 3: `ThreadScreen`.**
  - Replace the property block with `let threadId: String`, `private var thread: LineThread? { state.lineThreads.first { $0.id == threadId } }`, `private var messages: [LineMessage] { state.lineMessages[threadId] ?? [] }`, and add `private var threadLine: Line? { thread.flatMap { t in state.lines.first { $0.id == t.lineId } } ?? state.line }`.
  - Replace the struct doc's first paragraph with: "Pushed on the My number stack (since 2026-09-24): the back swipe works and the tab bar stays. It was a cover because the old custom tab bar would have sat on the composer; the native `TabView` removed that reason."
  - `body`: delete `header` and its `Divider()` from the `VStack` (keep `transcript` and `composer`), and add:
    ```swift
        .navigationTitle(Text(verbatim: peerName ?? PhoneFormat.national(peer)))
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(theme.bg, for: .navigation)
        .toolbar {
            ToolbarItem(placement: .principal) { identity }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Hidden, not disabled, without a voice client.
                if calls.isVoiceAvailable {
                    Button(action: callPeer) { Image(systemName: RIcon.phone) }
                        .accessibilityLabel(Text("Call this number"))
                }
                Button { showActions = true } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(Text("Options"))
            }
        }
        .tint(theme.text)   // toolbar controls are neutral (one green)
        .onAppear { state.openThreadId = threadId }
        .onDisappear { if state.openThreadId == threadId { state.openThreadId = nil } }
        .onChange(of: calls.isLive) { _, live in if live { showNameSheet = false } }
    ```
    and turn the old `header`'s identity `Button` into:
    ```swift
    private var identity: some View {
        Button { showNameSheet = true } label: {
            HStack(spacing: RSpace.sm) {
                PeerAvatar(e164: peer, name: peerName, size: 28, neutral: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: peerName ?? PhoneFormat.national(peer))
                        .font(RFont.text(16, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    // …the existing Blocked / Reported / national-number-under-a-name
                    // lines, unchanged (font sizes 11)…
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Name this number"))
    }
    ```
    Delete the rest of the old `header` (the ✕, the chip buttons).
  - Replace both `.task` modifiers with one:
    ```swift
        .task(id: threadId) {
            await state.loadLineMessages(using: LineAPI(client: api), threadId: threadId)
            await state.markThreadRead(using: LineAPI(client: api), threadId: threadId)
            // A thread left open while the other side replies fills in on its
            // own. `.task` is cancelled when the page is popped or the tab
            // hides it; a cover over it (the dialer) pauses the poll.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                if state.flow == nil {
                    await state.loadLineMessages(using: LineAPI(client: api), threadId: threadId)
                }
            }
        }
    ```
  - `callPeer()` becomes (no cover to dismiss any more):
    ```swift
    private func callPeer() {
        RHaptic.select()
        state.dialerPrefill = peer
        state.flow = .dialer
    }
    ```
  - `send()`: directly before `isSending = true`, add `state.openThreadId = threadId  // the reply leaves from THIS thread's line`.
  - Composer footer: replace `if blockReason == nil, let left = state.line?.smsRemaining {` with `if blockReason == nil, let left = threadLine?.smsRemaining, left <= 10 {` (spec §4.4: only when 10 or fewer remain; the THREAD's line). In `blockReason` replace `guard let line = state.lines.first(where: { $0.id == thread.lineId }) ?? state.line else {` with `guard let line = threadLine else {`.
  - The `.sheet(isPresented: $showNameSheet)` comment: "Presented from here: a page's sheet, with the environment injected explicitly (sheet content does not reliably inherit `@Observable` objects)."

- [ ] **Step 4: `ComposeScreen`.** Add `@Environment(\.dismiss) private var dismiss`. Delete `header`; the `VStack` starts with the `ScrollView`, whose content now begins with
  ```swift
                        if let line = state.line {
                            Text("From \(PhoneFormat.national(line.e164))")
                                .font(RFont.text(13))
                                .foregroundStyle(theme.text2)
                        }
  ```
  Add `.navigationTitle(Text("New message"))`, `.navigationBarTitleDisplayMode(.inline)`, `.containerBackground(theme.bg, for: .navigation)` on the root. Keep `.task { state.openThreadId = nil; focus = .to }` (load-bearing, comment kept). In `send()`'s success branch replace the dismiss-then-raise block with:
  ```swift
                RHaptic.success()
                // `sendLineMessage` set `openThreadId` from the server's
                // response: open that conversation IN PLACE of this page — it
                // is where the delivery receipt, the send's real outcome, lands.
                if let tid = state.openThreadId,
                   let i = state.linePath.lastIndex(of: .compose) {
                    state.linePath[i] = .thread(tid)
                } else {
                    dismiss()
                }
  ```

- [ ] **Step 5: Push routing** (`ContentView`, :463–483). Keep the handler's doc and the 🔴 `initial: true` comment; replace the body's `Task { … }` with:
  ```swift
            Task {
                await state.loadLineThreads(using: LineAPI(client: api))
                // Never open a thread we could not load: `ThreadScreen`
                // resolves its peer from `lineThreads`.
                guard state.lineThreads.contains(where: { $0.id == threadId }) else {
                    state.tab = .line
                    state.intent = .line
                    return
                }
                // Tab `.line`, the thread PUSHED on its stack, any cover closed.
                state.openLineThread(threadId)
            }
  ```
  Update the comment above ("the thread cover renders over whatever tab…") to: "Sets the tab and pushes the conversation on the My number stack (`openLineThread`), closing any cover first."
  In `flowContent` delete `case .thread: ThreadScreen()` and `case .compose: ComposeScreen()`, and in the comment above `case .lineStoreMore` drop "because `ThreadRow` already assigns `flow = .thread`". Update the root `InCallOverlay` comment's list "a thread, a checkout, the dialer itself" on the COVER copy to "a checkout, the dialer itself"; add to the root copy's comment: "A pushed thread or compose is not a flow, so this copy covers them (verified by `-screenshot lineInCall`)."

- [ ] **Step 6: DEBUG live-call hook** (`CallController.swift`, end of file — same file, so `private(set)` setters are reachable):
  ```swift
  #if DEBUG
  extension CallController {
      /// Screenshot harness ONLY: put the controller in an answered call with
      /// no SDK, CallKit or network involved, so a frame can prove where
      /// `InCallOverlay` draws (telephony trap 5). Compiled out of Release.
      func screenshotLiveCall(peer: String) {
          self.peer = peer
          self.startedAt = Date().addingTimeInterval(-42)
          self.phase = .active
      }
  }
  #endif
  ```

- [ ] **Step 7: Fixtures.** `ScreenshotMode.Screen`: add
  ```swift
          case lineInCall      // a live call over a PUSHED thread: the call screen must cover it (trap 5)
          case linePushThread  // a line-SMS push tapped over an open cover: tab .line, thread pushed
  ```
  In `applyScreenshotState` replace the `.thread` case with
  ```swift
          case .thread, .lineInCall, .linePushThread:
              state.lines = [ScreenshotMode.sampleLine]
              state.lineThreads = ScreenshotMode.sampleThreads
              state.lineMessages = ["t1": ScreenshotMode.sampleMessages]
              switch shot {
              case .linePushThread:
                  // Exercise the REAL handler (`onChange(initial: true)`), over
                  // an open cover, from another tab.
                  state.tab = .verify
                  state.flow = .orders
                  push.pendingLineThreadId = "t1"
              case .lineInCall:
                  state.openLineThread("t1")
                  calls.screenshotLiveCall(peer: "+18885550111")
              default:
                  state.openLineThread("t1")
              }
  ```

- [ ] **Step 8: Build + prove the flow cases are gone.**
  ```bash
  grep -rnE "flow (=|==|!=) \.(thread|compose)|case \.thread:|case \.compose:" VirtualSIM || echo CLEAN
  ```
  Expected `CLEAN`, then `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Screenshots (risk 1, Review Focus 2).** `zsh …/p2-shots.sh thread lineInCall linePushThread`. Expected:
  - `thread`: a system nav bar with a back chevron ("My number"), the neutral avatar + `+1 (888) 555-0111` in the principal slot, call and ⋯ on the right in neutral ink; bubbles; the neutral "Copy 123456" chips; the composer; **the tab bar visible** with My number selected; no "texts left" line (142 > 10).
  - `lineInCall`: the in-call screen (avatar, `+1 (888) 555-0111`, `0:42`, mute/keypad/speaker, the red End button) covering the whole frame, **tab bar included** — nothing of the thread visible.
  - `linePushThread`: the Orders cover gone, the My number tab selected, the t1 thread pushed (back chevron, tab bar).
  Then the no-voice edit from Task 5 Step 12 once more (`calls.attach(api: api)`), capture `thread`: no call button in the toolbar, ⋯ still there. Revert (`git diff VirtualSIM/Auth` empty).

- [ ] **Step 10: Checks + commit**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 6
  git diff main --stat -- supabase VirtualSIM/Onboarding
  git add -A VirtualSIM
  git commit -m "my number: thread and compose pushed on the stack; line-SMS push opens the thread in the tab"
  ```

---

### Task 7: Full capture, and CLAUDE.md / telephony.md / ios-client.md

**Files:**
- Modify: `CLAUDE.md`, `.claude/rules/telephony.md`, `.claude/rules/ios-client.md`
- Read only: every fixture frame

**Interfaces:** none (verification and docs).

- [ ] **Step 1: Capture every line fixture, both appearances.**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-shots.sh lineIntro lineStore lineStoreError linePaywall linePaywallYearly linePaywallUS lineInbox lineInboxEmpty lineInboxMulti lineCalls lineNumber lineBanner lineSwapConfirm lineDialer thread lineInCall linePushThread verifyLine credits
  ```
  Expected: every sampling line `ok` (exit 0). Open each PNG and check it against its task's Expected list; in particular count accent elements (at most one per screen: the primary action, plus the selected-plan border and the Switch capsule's hairline), and look for any shadow in light mode and any SF Mono digit.
  Then the long-locale check the English fixtures cannot give: launch `lineStore`, `linePaywall` and `lineInbox` once each with `-AppleLanguages "(de)"` added to the `simctl launch` line (dark only is enough) and confirm nothing truncates mid-word — in particular the country segments (they must fall back to the menu rather than clip), the link row (it must stack), and the Switch capsule.

- [ ] **Step 2: Final gates.**
  ```bash
  zsh /Users/adyl/.claude/jobs/c5c3d119/tmp/p2-loadbearing.sh 7     # every line ok
  git diff main --stat -- supabase VirtualSIM/Onboarding            # prints nothing
  plutil -p /Users/adyl/.claude/jobs/c5c3d119/tmp/dd/Build/Products/Debug-iphonesimulator/VirtualSIM.app/Info.plist | grep -A3 UIBackgroundModes   # still lists audio + voip (no project-file change expected; assert anyway)
  ```

- [ ] **Step 3: `CLAUDE.md`** (state what is true on this branch; keep main's text, marked as main's):
  - In "✅ DECIDED 2026-09-17: KEEP SELLING US/PR AND DISCLOSE IT", after "…so the two screens cannot disagree about who is warned.", insert: "**On branch `design-overhaul` (2026-09-24):** `LineStoreScreen.sendingNotice` and its green Canada line are GONE. The store shows a ✓/✗ ledger (`Components/LineLedger.swift`) whose ✗ row, 'Texts you send to US numbers usually don't arrive.', renders for EVERY country, because the recipient's network enforces 10DLC (CA→US 0 of 8). Checkout's `capabilityNote` stays UNCOLLAPSED on US/PR with its Canada sentence removed; the thread's failed-send copy likewise; the swap sheet's confirm page gains the ✗ row when the target country is US/PR. `LineStoreScreen.unreliableSendingCountries` is still the one list (checkout, thread, swap). The force_block rule below covers the ledger ✗ row and the checkout note on this branch. The rest of this paragraph describes `main`."
  - In the "🔴 It is the RECIPIENT's network…" paragraph, after "…and a Canadian number is NOT a workaround.", add: "(Fixed on branch `design-overhaul`, 2026-09-24: no screen claims Canadian sending works.)"
  - In "Behavioural analytics" (or the nearest analytics note), add: "**Line events on branch `design-overhaul` (2026-09-24):** `line_choose_number_tapped` is RETIRED (the store lists three numbers inline; no button). `line_numbers_shown` now fires whenever the store renders a fresh inline search — every visit that searches — with `source: \"store_inline\"`; on `main` it meant 'opened the picker', so the two series are NOT comparable. `line_swap_open` gains `from` ∈ `home` · `number_segment`. Every other line event keeps its name and props."
  - In "Known-open → Product / listing", add: "⚠️ **No server-sourced allowance exists before purchase** (verified 2026-09-24 on branch `design-overhaul`): `line_country_menu` and `search-line-numbers` carry none, and the paywall's minutes figure is `LineProduct.voiceAllowanceMinutes`, a client mirror of the `phone_lines` schema default. The redesigned store (spec §4.1) therefore shows NO allowance. Showing one needs the owner to decide whether to publish it server-side." and "⚠️ **The My number overhaul (branch `design-overhaul`) is build- and screenshot-verified only.** Tap automation is unavailable; a device walk (store → paywall → Apple sheet, Switch → confirm, thread push from a real notification, a real call over a pushed thread) is required before merge." and "⚠️ **The store names the monthly price again on branch `design-overhaul`** (StoreKit only, hidden until it loads), reversing the 2026-09-09 'no price on the store' decision by the approved 2026-09-24 design."
  - Search CLAUDE.md for "Change number" and "LineSettingsScreen"; for each, add "(on `design-overhaul`: the compact 'Switch' capsule on the number card and the Number segment's 'Switch number…' row; the settings sheet is deleted)" rather than rewriting main's history.

- [ ] **Step 4: `.claude/rules/telephony.md`:**
  - In the "Refocus (2.7, build 48)" paragraph, after "…see 'Swapping a line's number' for the choose-first-pay-last flow and why.", add: "**On branch `design-overhaul` (2026-09-24):** the swap is a compact **'Switch'** capsule on the number card, right of the number (neutral fill, 1 pt accent border, accessibility label 'Switch number'), plus a 'Switch number…' row in the Number segment; both are `LineSwitchNumberButton` and fire `line_swap_open{from: home | number_segment}`. The gear and `LineSettingsScreen` are gone (the Number segment holds usage, Switch number…, Rent another number and the 911 card). The line reload after a swap moved from `LineSwapSheet.perform` to the button's sheet `onDismiss`, so the card's number rolls visibly; `onSwapped` fires at the moment of success."
  - In "Swapping a line's number", after the bullet that begins "- `LineSwitchNumberButton` reads **\"Change number\"**", add a sub-bullet: "On `design-overhaul`: it reads 'Switch' (capsule) / 'Switch number…' (row); still no figure, still hidden when `lineSwapCredits` is nil or the line is not `.active`. The confirm page adds the ledger ✗ row when the target country is US/PR."
  - In "Calling: WIRED AND REACHABLE" (:37–38) and under trap 5's list, add: "On `design-overhaul` the dialer is reached from the Calls segment's keypad button in the header (hidden without a voice client); there is no FAB. The thread and compose are PUSHED on the My number `NavigationStack`, not covers, so the ROOT `InCallOverlay` (scoped to `flow == nil`) covers them; the cover copy still covers the dialer, paywall and provisioning. Verified with `-screenshot lineInCall` (a DEBUG-only `CallController.screenshotLiveCall(peer:)` fakes the answered call)."

- [ ] **Step 5: `.claude/rules/ios-client.md`:**
  - Source layout, `ContentView.swift` entry: add "the My number tab is `LineScreen`, a `NavigationStack(path: $state.linePath)` whose destinations are `LineRoute` (`countries`, `cities`, `thread(id)`, `compose`), registered by `.lineRouteDestinations()`; `AppState.openLineThread(_:)` is how a line-SMS push opens a conversation (closes any cover, selects `.line`, pushes). Covers left on the line: `lineCheckout`, `lineProvisioning`, `dialer`, `lineStoreMore` (→ `LineStoreCover`, its own stack)."
  - Screens entry: add "`LineStoreScreen` (inline store: `CapsuleSegmentedControl` country choice, ✓/✗ `LineLedger`, three inline numbers searched on appear behind a session guard, StoreKit price row) + `LineStorePages` (`LineStoreSearch`, `LineCountriesPage`, `LineCitiesPage`, `LineStoreCover`); `LineNumberSegment` (replaced `LineSettingsScreen`, deleted 2026-09-24)". Components entry: add "`LineNumberCard` (+ `LiveDot`), `LineLedger`, `CapsuleSegmentedControl`; `LineOfferList` in `LinePickerRows`; `PeerAvatar(neutral:)`."
  - DesignSystem entry: add "`RMotion.unlessReduced(_:_:)` — every My number animation goes through it; `riseIn` now honours Reduce Motion app-wide (no offset, no animation)."
  - Add a short section "## The My number tab (branch `design-overhaul`, 2026-09-24)" with the facts not derivable from the code: (1) `openThreadId` is set by `ThreadScreen` on appear and before every send and is no longer cleared by `flow.didSet` — a dialer cover over a thread would otherwise wipe the reply's sending line; (2) the inline store skeleton shows while `lineOffers` is empty AND `lineUnavailableReason` is nil ("not answered yet"), so the error state never flashes before the first search; (3) `line_numbers_shown` changed meaning (see CLAUDE.md); (4) the screenshot fixtures `lineIntro` (loading, no price), `lineStoreError`, `linePaywallUS`, `lineInboxEmpty`, `lineInboxMulti`, `lineCalls`, `lineNumber`, `lineBanner`, `lineSwapConfirm`, `lineDialer`, `lineInCall`, `linePushThread`, and the DEBUG `[analytics]` NSLog echo in screenshot mode (`simctl launch --stderr=`).

- [ ] **Step 6: Commit**
  ```bash
  git diff main --stat -- supabase VirtualSIM/Onboarding
  git add CLAUDE.md .claude/rules/telephony.md .claude/rules/ios-client.md
  git commit -m "docs: My number overhaul — branch notes for the ledger, Switch, pushed thread, retired/changed events, allowance open item"
  ```

---

## Self-review (done while writing)

- **Spec coverage.** §3 rules 1–3 → Task 1 (+ each rebuild keeps them). §3a → Task 5a item by item (card rise, live dot, copy morph, Switch roll + glow, segments, list stagger + insert + pull to refresh, store rows + crossfade + shimmer + press scale, paywall border + price roll, thread bubbles + chip bounce), with the capsule glide born in Task 3. §4.1 → Task 3 (allowance verified absent, recorded in Task 7). §4.2 → Task 4. §4.3 → Task 5. §4.4 → Task 6 (thread, compose, push routing; dialer/paywall/provisioning stay covers; the dialer's accent call button is Task 1; the swap ✗ row is Task 2). §4.5 as revised → Task 5 (compact capsule, wraps below at accessibility sizes, Copy/Share in row 2, a11y "Switch number", the row, `from`, hidden-not-disabled, confirm page untouched). §5 → Task 2. §6 → Tasks 3 (`source`, retirement) and 5 (`from`); CLAUDE.md note in Task 7. §7 → fixtures across Tasks 1–6, full capture in Task 7. §9 risks → Task 6 Step 9 (overlay over a pushed thread), Task 3 (session guard), Task 7 (device walk recorded).
- **Placeholders.** None: every new string has six translations, every new component has code, and every modified large screen names the functions/views and the replacement code.
- **Names used across tasks:** `LineRoute` (`countries`, `cities` in T3; `thread(String)`, `compose` in T6), `AppState.linePath`, `lineRouteDestinations()`, `LineStoreScreen(onOpenSms:onClose:push:)`, `LineStoreCover`, `LineStoreSearch.reload/changePlace/selectCountry`, `LineCountriesPage`, `LineCitiesPage`, `CapsuleSegmentedControl(selection:tags:label:)`, `LineLedger`/`LineLedgerRow(kind:figure:text:detail:)`, `LineOfferList(offers:country:placeFallback:onPick:)`, `LineNumberCard(line:swappedTo:)`, `LiveDot(tint:pulses:)`, `LineSwitchNumberButton(line:style:from:onSwapped:)` + `isOffered(for:state:)`, `LineSwapSheet(line:cost:from:onSwapped:)`, `LineNumberSegment(line:onSwapped:)`, `ThreadScreen(threadId:)`, `AppState.openLineThread(_:)`, `RMotion.unlessReduced(_:_:)`, `CallController.screenshotLiveCall(peer:)`, `PeerAvatar(…neutral:)` — consistent throughout.
- **Known gaps carried forward:** guest mode (the store renders no numbers without a session; the sign-in sheet is a later plan); no device walk possible here; Reduce Motion may be code-verified only if the simulator ignores the defaults write.
