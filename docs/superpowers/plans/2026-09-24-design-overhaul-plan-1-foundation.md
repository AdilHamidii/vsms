# Design Overhaul — Plan 1: Foundation (tokens, splash, tab shell, Verify)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Home + Temp with the Verify tab inside a native four-tab shell (Verify · My number · Activity · Account), add the design tokens every later step uses, refresh the splash, and make cold start able to run without a session.

**Architecture:** `AppTab` becomes `verify, line, activity, account` in a fixed order. `ContentView` hosts a native `TabView`; the custom floating `TabBar` is deleted. Verify owns a `NavigationStack` whose only route in this plan is the existing temp-SMS/e-mail screen (`TempScreen`), reached after a service pick — Plan 2 replaces that route with "Ways to verify". `AppState.coldStart` is split into a catalog part and an account part so a guest (Plan 2) can boot on the catalog alone. No backend change.

**Tech Stack:** SwiftUI (iOS 18 `Tab` API, iOS 26 Liquid Glass via the system tab bar), `@Observable` `AppState`, String Catalog (`Localizable.xcstrings`), Python 3 for the catalog helper.

**Spec:** `docs/superpowers/specs/2026-09-24-design-overhaul-design.md` (sections 4, 5, 6.1, 10 steps 1–2, 11). Consultant reports: `docs/design-overhaul/consultants/`.

**This is plan 1 of several.** Plans 2+ (Ways in / country / checkout / sign-in sheet; waiting / code / recovery; guest mode completion; My number; Activity + Account; fixtures + localisation review) are written after this one lands, against the code as it then is.

## Global Constraints

- Backend untouched: `git diff main -- supabase` prints nothing before every commit.
- Onboarding untouched: `git diff main -- VirtualSIM/Onboarding` prints nothing.
- iOS 18.0 minimum; anything iOS 26-only goes behind `if #available(iOS 26, *)` with a working 18 path.
- The only build check is: `xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10` → must end `** BUILD SUCCEEDED **`. (`swiftc -typecheck` is retired.)
- A worktree build needs `VirtualSIM/Networking/Secrets.swift` (already copied into this worktree).
- Every user-facing string: `Text("literal")` or `String(localized:)`; added to `VirtualSIM/Localizable.xcstrings` in de, es, fr, it, ja, pt-BR **in the same commit**, via `scripts/xcstrings-add.py` (Task 1). Tone per locale follows the catalog: de "Sie", es "tú", fr "vous", it "tu", ja polite, pt-BR "você". No interpolated pluralised nouns.
- Vocabulary: "Free e-mail", "One-time number", "Your own number"; never "number" alone for a product.
- Nothing pre-selected on first run; a tile tap goes through `AppState.commitServicePick` (clears `needsServiceChoice`, never `needsCountryChoice`).
- No supplier named, no delivery promise, no hardcoded server-owned number or StoreKit price.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01G3g3LLutZtZy4JEkaSwpfD
  ```
- Run every command from the worktree root `/Users/adyl/Desktop/IOS_APPS/VirtualSIM/.claude/worktrees/design-overhaul` unless a step says otherwise.

## Review Focus

1. **Catalog not loaded / seed stub.** Verify must degrade: tiles for ids missing from `state.services` are skipped (never a hole), search over an empty catalog shows "No apps match" rather than a blank screen. Pinned in Task 6 Step 5 (fixture with a 2-service catalog).
2. **Subscriber strip flash.** The "Your number" strip renders only when `state.linesLoaded && line.status.isLive`; never a store-then-strip flicker. Pinned in Task 6 Step 5 (`verifyLine` fixture).
3. **Every old `state.tab = .temp/.home` entry point still lands somewhere sensible** — push notifications, `OrdersScreen`'s empty-state button, `OtpScreen`'s line upsell, `LineStoreScreen`'s "one-off code", `EsimDetailScreen`'s back. Pinned in Task 5 Step 7 (grep proves zero `.temp`/`.home` tab writes remain).
4. **An order in flight on any tab.** `ResumeBar` stays visible above the system tab bar on all four tabs and never covers the last row of content. Pinned in Task 5 Step 9 (`waiting`-then-close fixture screenshot on each tab).
5. **Long localized tab labels at large Dynamic Type** (de "Verifizieren", "Meine Nummer"). The native bar must not clip. Pinned in Task 5 Step 9 (de + XXL screenshot).

---

### Task 1: String-catalog helper

**Files:**
- Create: `scripts/xcstrings-add.py`
- Test: run against a scratch copy (Step 2) and against HEAD (Step 4)

**Interfaces:**
- Produces: `python3 scripts/xcstrings-add.py <entries.json>` — adds/updates keys in `VirtualSIM/Localizable.xcstrings`. Input JSON: `{ "<English key>": {"de": "...", "es": "...", "fr": "...", "it": "...", "ja": "...", "pt-BR": "..."} }`. Refuses (exit 1) if a locale is missing or a translation's format-specifier multiset differs from the key's. Re-emits the committed dialect: `json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True) + "\n"`.

- [ ] **Step 1: Write the helper**

```python
#!/usr/bin/env python3
"""Add translated keys to Localizable.xcstrings in the committed JSON dialect.

Usage: python3 scripts/xcstrings-add.py entries.json [--catalog PATH]

entries.json: {"English key": {"de": "...", "es": "...", "fr": "...",
                               "it": "...", "ja": "...", "pt-BR": "..."}}

Refuses the whole batch (exit 1, catalog untouched) when any entry is missing
a locale or a translation's format specifiers differ from the key's. The
catalog is re-emitted exactly as committed: json.dumps(indent=2,
ensure_ascii=False, sort_keys=True) plus a trailing newline — never Xcode's
dialect, which would rewrite ~44,000 lines.
"""
import json
import re
import sys
from collections import Counter

LOCALES = ["de", "es", "fr", "it", "ja", "pt-BR"]
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)")


def specifiers(s: str) -> Counter:
    # Positional (%1$@) and plain (%@) forms are equivalent.
    return Counter(re.sub(r"\d+\$", "", m) for m in SPEC.findall(s))


def main() -> int:
    args = sys.argv[1:]
    catalog_path = "VirtualSIM/Localizable.xcstrings"
    if "--catalog" in args:
        i = args.index("--catalog")
        catalog_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__)
        return 1
    entries = json.load(open(args[0], encoding="utf-8"))
    errors = []
    for key, tr in entries.items():
        missing = [l for l in LOCALES if not tr.get(l)]
        if missing:
            errors.append(f"{key!r}: missing {missing}")
        for l in LOCALES:
            if tr.get(l) and specifiers(tr[l]) != specifiers(key):
                errors.append(f"{key!r} [{l}]: specifiers {dict(specifiers(tr[l]))} != {dict(specifiers(key))}")
    if errors:
        print("\n".join(errors))
        return 1

    catalog = json.load(open(catalog_path, encoding="utf-8"))
    strings = catalog["strings"]
    for key, tr in entries.items():
        entry = strings.setdefault(key, {})
        locs = entry.setdefault("localizations", {})
        for l in LOCALES:
            locs[l] = {"stringUnit": {"state": "translated", "value": tr[l]}}
    with open(catalog_path, "w", encoding="utf-8") as f:
        f.write(json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"added/updated {len(entries)} keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Test it rejects a bad batch and accepts a good one (scratch copy)**

```bash
cp VirtualSIM/Localizable.xcstrings /tmp/xc-scratch.xcstrings
printf '%s' '{"Bad %lld":{"de":"x","es":"x","fr":"x","it":"x","ja":"x","pt-BR":"x"}}' > /tmp/bad.json
python3 scripts/xcstrings-add.py /tmp/bad.json --catalog /tmp/xc-scratch.xcstrings; echo "exit=$?"
printf '%s' '{"Probe key":{"de":"a","es":"b","fr":"c","it":"d","ja":"e","pt-BR":"f"}}' > /tmp/good.json
python3 scripts/xcstrings-add.py /tmp/good.json --catalog /tmp/xc-scratch.xcstrings; echo "exit=$?"
python3 -c "import json;print(json.load(open('/tmp/xc-scratch.xcstrings'))['strings']['Probe key']['localizations']['pt-BR'])"
```
Expected: first run prints six `specifiers ... != {'%lld': 1}` lines and `exit=1`; second prints `added/updated 1 keys` and `exit=0`; last prints `{'stringUnit': {'state': 'translated', 'value': 'f'}}`.

- [ ] **Step 3: Prove the re-emit is byte-identical on an unchanged catalog**

```bash
cp VirtualSIM/Localizable.xcstrings /tmp/xc-rt.xcstrings
printf '{}' > /tmp/empty.json
python3 scripts/xcstrings-add.py /tmp/empty.json --catalog /tmp/xc-rt.xcstrings
cmp /tmp/xc-rt.xcstrings VirtualSIM/Localizable.xcstrings && echo IDENTICAL
```
Expected: `added/updated 0 keys` then `IDENTICAL`.

- [ ] **Step 4: Commit**

```bash
git add scripts/xcstrings-add.py
git commit -m "scripts: xcstrings-add.py — add translated keys in the committed catalog dialect"
```
(append the two attribution lines from Global Constraints to every commit message in this plan)

---

### Task 2: Design-system tokens

**Files:**
- Create: `VirtualSIM/DesignSystem/Spacing.swift`
- Create: `VirtualSIM/DesignSystem/NumberStyle.swift`
- Modify: `VirtualSIM/DesignSystem/Motion.swift` (add `standard`)
- Modify: `VirtualSIM/DesignSystem/Theme.swift` (`RRadius` gains `card`, `group`)

**Interfaces:**
- Produces: `RSpace.xs/sm/md/lg/xl/xxl: CGFloat` (4/8/12/16/24/32); `RMotion.standard: Animation` (spring response 0.35, damping 0.85); `RRadius.card = 20`, `RRadius.group = 14`; `View.numberStyle(size:weight:color:)` (SF Pro, monospaced digits, numeric content transition); `View.selectedEmphasis(_ selected: Bool, radius:)` (1pt accent border only when selected).

- [ ] **Step 1: Create `Spacing.swift`**

```swift
import SwiftUI

/// One spacing scale for the whole app. Before the 2026-09 overhaul every
/// padding was hand-set per call site (borrowing `RRadius` numbers), so two
/// cards that should line up did not. New code uses these; old screens adopt
/// them as they are rebuilt.
enum RSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Horizontal screen gutter.
    static let gutter: CGFloat = 16
}
```

- [ ] **Step 2: Create `NumberStyle.swift`**

```swift
import SwiftUI

extension View {
    /// Prices, balances, codes and phone numbers. SF Pro with monospaced
    /// DIGITS (columns line up, the rest stays proportional) and a numeric
    /// content transition so a changing value rolls instead of popping.
    /// Replaces SF Mono for money and numbers: next to SF Pro it read as
    /// terminal output (consultant report, 2026-09-24).
    func numberStyle(size: CGFloat, weight: Font.Weight = .semibold,
                     color: Color? = nil) -> some View {
        font(.system(size: size, weight: weight, design: .default))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(color ?? .primary)
    }

    /// The overhaul's one emphasis rule: ONLY the selected option carries a
    /// border. Labels on other options ("Our pick", "Best value per credit")
    /// are text tags, so two highlights never compete.
    func selectedEmphasis(_ selected: Bool, radius: CGFloat = RRadius.card,
                          color: Color) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected ? color : .clear, lineWidth: 1)
        }
    }
}
```

- [ ] **Step 3: Add the standard spring to `Motion.swift`** — insert after `static let camera = …`:

```swift
    /// The overhaul's default spring for anything that moves and is not one
    /// of the cases above (response 0.35, damping 0.85 — spec §5).
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
```

- [ ] **Step 4: Add radii to `RRadius` in `Theme.swift`** — inside `enum RRadius { … }` append:

```swift
    /// Overhaul surfaces (spec §5): cards 20pt, grouped rows 14pt.
    static let card: CGFloat = 20
    static let group: CGFloat = 14
```

- [ ] **Step 5: Build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add VirtualSIM/DesignSystem
git commit -m "design: spacing scale, number style, emphasis rule, standard spring"
```

---

### Task 3: Splash refresh

**Files:**
- Modify: `VirtualSIM/Screens/SplashScreen.swift`
- Modify: `VirtualSIM/Assets.xcassets/LaunchBackground.colorset/Contents.json` only if `theme.bg` changes (it does not in this task)

**Interfaces:**
- Consumes: `SplashState` (unchanged), `BrandWordmark` (unchanged), `RSpace`, `RMotion.standard`.
- Produces: same `SplashScreen(state:onRetry:onContinue:)` API — boot logic untouched.

The splash already carries no marketing copy (verified 2026-09-24: its only strings are the slow-connection and failure lines). This task makes it quieter, not different: a centred wordmark, a 2pt hairline progress track under it, status copy in `text3`.

- [ ] **Step 1: Read the whole file first** (`VirtualSIM/Screens/SplashScreen.swift`, 183 lines) and keep: the 1.2s delay before the bar, the 3.5s slow-connection line, the failure state with its two buttons, every `Text` literal.

- [ ] **Step 2: Restyle the progress bar** — replace the bar's view (the `case .progress(let value):` branch and the indeterminate branch) with a hairline track:

```swift
    private func hairline(_ fraction: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule()
                    .fill(theme.ink)
                    .frame(width: geo.size.width * (fraction ?? 0.25))
                    .animation(RMotion.value, value: fraction)
            }
        }
        .frame(width: 120, height: 2)
        .accessibilityHidden(true)
    }
```
Use `hairline(value)` for `.progress(value)` and `hairline(nil)` for `.indeterminate`; keep the existing 1.2s appearance delay around it.

- [ ] **Step 3: Spacing and type** — wordmark centred; `RSpace.xl` between wordmark and hairline; status lines `RFont.text(13)` in `theme.text3`, centred, `RSpace.lg` below the hairline; failure buttons unchanged in behaviour, restyled to 56pt capsules (`PrimaryButton` / its secondary style from `Components/Buttons.swift`).

- [ ] **Step 4: Build**, then capture: `xcrun simctl launch 787A6027-0A86-4AE0-9412-C99DCF4CE992 com.anthersystems.VirtualSIM` right after install and `xcrun simctl io 787A6027-0A86-4AE0-9412-C99DCF4CE992 screenshot /tmp/splash.png` within 1s. Expected: wordmark centred on `theme.bg`, no copy.

- [ ] **Step 5: Commit**

```bash
git add VirtualSIM/Screens/SplashScreen.swift
git commit -m "splash: quieter — wordmark and a hairline progress track"
```

---

### Task 4: Split cold start into catalog + account phases

**Files:**
- Modify: `VirtualSIM/State/AppState.swift` (`coldStart(api:)` at ~line 1320)
- Modify: `VirtualSIM/ContentView.swift` (the two `coldStart` call sites: the `.task` at ~line 229 and the splash `onRetry` at ~line 201)

**Interfaces:**
- Produces:
  - `func coldStart(api: APIClient, signedIn: Bool = true) async` — same `bootPhase`/`bootProgress` contract. With `signedIn == false` it runs maintenance + catalog + `resumeInFlightOrder`/`applyStartupSelection`, sets `linesLoaded = true`, reveals, then `refreshAppStatus` and `Analytics.shared.track("app_open")` only.
  - `func loadAccount(api: APIClient) async` — the session-dependent reads, in today's order: `loadCountryRanks`, `refreshWallet`, `refreshProfile`, `loadOrders`, `loadLine`, `loadLineThreads` (if a line). Plan 2 calls it after a guest signs in.
- Behaviour when signed in: byte-for-byte the same sequence and progress steps as today.

- [ ] **Step 1: Refactor** — replace the body of `coldStart` with:

```swift
    func coldStart(api: APIClient, signedIn: Bool = true) async {
        bootPhase = .loading
        bootProgress = 0

        // Guests have no account reads, so their bar has 2 real steps, not 6.
        let total = signedIn ? 6.0 : 2.0
        var done = 0.0
        func step() {
            done += 1
            bootProgress = min(1, done / total)
        }

        await refreshMaintenance(using: MaintenanceAPI(client: api))
        step()

        guard await loadCatalog(using: CatalogAPI(client: api)) else {
            bootPhase = .failed
            return
        }
        step()

        if signedIn {
            await loadAccount(api: api, progress: step)
        } else {
            // No line can exist without an account; say so, so nothing waits
            // on a read that will never run.
            linesLoaded = true
        }

        resumeInFlightOrder()
        applyStartupSelection()
        bootPhase = .ready

        await refreshAppStatus(using: AppStatusAPI(client: api))
        if signedIn {
            if let userId = profile?.userId {
                await applyPendingDisplayName(userId: userId, using: ProfileAPI(client: api))
            }
            await loadEsimCatalog(using: EsimPlansAPI(client: api))
            await loadEsimOrders(using: EsimOrdersAPI(client: api))
            await loadEmailOrders(using: EmailAPI(client: api))
            await submitAttributionIfNeeded(api: api)
        }
        Analytics.shared.track("app_open")
    }

    /// Everything that needs a session, in the order cold start has always
    /// run it. `progress` is called after each of the four steps that count
    /// towards the splash bar (wallet, profile, orders, line) so a signed-in
    /// cold start reports exactly what it did before the split.
    func loadAccount(api: APIClient, progress: () -> Void = {}) async {
        await loadCountryRanks(using: CatalogAPI(client: api))
        await refreshWallet(using: WalletAPI(client: api));   progress()
        await refreshProfile(using: ProfileAPI(client: api)); progress()
        await loadOrders(using: OrdersAPI(client: api));      progress()
        await loadLine(using: LineAPI(client: api))
        if line != nil { await loadLineThreads(using: LineAPI(client: api)) }
        progress()
    }
```
Keep every existing comment from the old body next to the line it described (move them, do not delete them).

- [ ] **Step 2: Build.** Expected `** BUILD SUCCEEDED **` (call sites still compile via the default argument).

- [ ] **Step 3: Regression check — signed-in boot unchanged.** Install the Debug build on the simulator (`xcrun simctl install 787A6027-0A86-4AE0-9412-C99DCF4CE992 <DerivedData>/Build/Products/Debug-iphonesimulator/VirtualSIM.app`), launch with `-screenshot homeRouter`, screenshot after 6s. Expected: identical to `/Users/adyl/.claude/jobs/c5c3d119/tmp/shots/homeRouter.png` (same cards, same credit pill).

- [ ] **Step 4: Commit**

```bash
git add VirtualSIM/State/AppState.swift
git commit -m "state: split coldStart into catalog and account phases (guest-ready)"
```

---

### Task 5: Native four-tab shell

**Files:**
- Modify: `VirtualSIM/State/AppState.swift` (`AppTab`, `tab` default, the two `tab == .line` intent reads at ~587 and ~1079, the `launchTab` storing at ~534)
- Modify: `VirtualSIM/ContentView.swift` (body tab switch + bottom stack; every `state.tab = …`; screenshot cases)
- Modify: `VirtualSIM/Screens/OrdersScreen.swift:238`, `VirtualSIM/Screens/OtpScreen.swift:466`, `VirtualSIM/Screens/EsimDetailScreen.swift:83`, `VirtualSIM/Screens/LineScreen.swift` (its `onOpenSms` consumers)
- Delete: `VirtualSIM/Components/TabBar.swift`
- Modify: `CLAUDE.md` ("Home leads the app" section), `.claude/rules/ios-client.md` (source layout)
- Create: `/tmp/p1-tabs.json` (catalog entries)

**Interfaces:**
- Consumes: `RMotion.standard`.
- Produces:
  - `enum AppTab: String, Hashable, CaseIterable { case verify, line, activity, account }` with `static let order: [AppTab] = [.verify, .line, .activity, .account]`.
  - `enum VerifyRoute: Hashable { case store }` and `var verifyPath: [VerifyRoute]` on `AppState`.
  - `func openCodeStore(email: Bool = false)` on `AppState`: sets `emailMode = email`, `tab = .verify`, `verifyPath = [.store]`. Every former `state.tab = .temp` becomes `state.openCodeStore()`; every former `state.tab = .home` becomes `state.tab = .verify; state.verifyPath = []`.

- [ ] **Step 1: Replace `AppTab`** (AppState.swift, the whole enum incl. `launchOrder`, `defaultOrder`, `productOrder`, `currentOrder`) with:

```swift
/// The four tabs, in their one fixed order (design overhaul, 2026-09-24):
/// Verify · My number · Activity · Account. Verify opens on every launch.
///
/// ⚠️ `app_config.launch_tab` (`/tabs number|temp`) no longer orders anything
/// in this build: Home and Temp are gone, so there is nothing for it to
/// reorder. The key is still read and stored by `refreshAppStatus` so older
/// builds keep honouring it.
enum AppTab: String, Hashable, CaseIterable {
    case verify, line, activity, account

    static let order: [AppTab] = [.verify, .line, .activity, .account]
}

/// Destinations pushed inside the Verify tab. Plan 1 has one: the existing
/// temp-SMS / temp-e-mail screen, reached after a service pick. Plan 2
/// replaces it with "Ways to verify".
enum VerifyRoute: Hashable {
    case store
}
```

- [ ] **Step 2: State** — change `var tab: AppTab = AppTab.currentOrder.first ?? .home` to `var tab: AppTab = .verify`; add below it:

```swift
    /// Navigation inside the Verify tab. Not persisted.
    var verifyPath: [VerifyRoute] = []

    /// Open the temp code store (SMS, or e-mail when `email`), from anywhere.
    /// The ONE replacement for the old `tab = .temp`, so every entry point —
    /// push notifications, the order list, upsell cards — lands the same way.
    func openCodeStore(email: Bool = false) {
        emailMode = email
        tab = .verify
        verifyPath = [.store]
    }
```
Leave the two `intent = tab == .line ? .line : .sms` lines as they are (they still compile and mean the same).

- [ ] **Step 3: ContentView body** — replace the `ZStack(alignment: .bottom) { … }` block that holds the tab `switch`, `ResumeBar` and `TabBar` (lines ~78–131) with:

```swift
        TabView(selection: $state.tab) {
            Tab("Verify", systemImage: "checkmark.shield", value: AppTab.verify) {
                NavigationStack(path: $state.verifyPath) {
                    VerifyScreen(openCredits: { sheet = .credits },
                                 openServices: { sheet = .services })
                        .navigationDestination(for: VerifyRoute.self) { route in
                            switch route {
                            case .store: codeStore
                            }
                        }
                }
                .resumeBarInset()
            }
            Tab("My number", systemImage: "phone", value: AppTab.line) {
                LineScreen(onOpenSms: { state.openCodeStore() })
                    .resumeBarInset()
            }
            .badge(state.lineUnreadCount)
            Tab("Activity", systemImage: "clock.arrow.circlepath", value: AppTab.activity) {
                OrdersScreen(openCredits: { sheet = .credits })
                    .resumeBarInset()
            }
            Tab("Account", systemImage: "person.crop.circle", value: AppTab.account) {
                AccountScreen(openCredits: { sheet = .credits })
                    .resumeBarInset()
            }
        }
        .tint(theme.ink)
        .background(theme.bg.ignoresSafeArea())
```
and add, in `ContentView`, the old `.temp` case's `TempScreen(...)` call moved verbatim into:

```swift
    /// The temp-SMS / temp-e-mail store, pushed inside Verify (Plan 1
    /// interim; Plan 2 replaces it with "Ways to verify").
    private var codeStore: some View {
        TempScreen(
            openServices: { sheet = .services },
            openCountries: { sheet = .country },
            openEmailDomains: { sheet = .emailDomain },
            openCredits: { sheet = .credits },
            onStart: { state.startCheckout() },
            onStartEmail: { startEmailOrder() },
            onStartEmailPaid: { startEmailOrder(payCredits: true) },
            onTapOrder: { o in
                if o.status == .waiting {
                    state.activeOrder = o
                    state.flow = .waiting
                } else if o.otp != nil {
                    state.activeOrder = o
                    state.flow = .otp
                } else {
                    state.buyAgain(o)
                }
            },
            onSeeAllOrders: { state.tab = .activity }
        )
    }
```
and at file scope:

```swift
private extension View {
    /// `ResumeBar` above the system tab bar, on every tab. `safeAreaInset`
    /// rather than iOS 26's `tabViewBottomAccessory`: the accessory is not yet
    /// verified to disappear when nothing is in flight (spec §4), and an empty
    /// glass capsule on every screen would be worse than no accessory.
    func resumeBarInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            ResumeBar()
                .padding(.horizontal, RSpace.gutter)
                .padding(.bottom, RSpace.sm)
        }
    }
}
```
Keep every modifier that followed the old ZStack (`.environment(\.theme, theme)`, overlays, sheets, covers, `.task`s) attached to the `TabView` in the same order.

- [ ] **Step 4: Tab labels in the catalog** — write `/tmp/p1-tabs.json`:

```json
{
  "Verify": {"de": "Verifizieren", "es": "Verificar", "fr": "Vérifier", "it": "Verifica", "ja": "認証", "pt-BR": "Verificar"},
  "My number": {"de": "Meine Nummer", "es": "Mi número", "fr": "Mon numéro", "it": "Il mio numero", "ja": "マイ番号", "pt-BR": "Meu número"},
  "Activity": {"de": "Aktivität", "es": "Actividad", "fr": "Activité", "it": "Attività", "ja": "アクティビティ", "pt-BR": "Atividade"}
}
```
Run `python3 scripts/xcstrings-add.py /tmp/p1-tabs.json`. Expected `added/updated 3 keys`. ("Account" already exists.)

- [ ] **Step 5: Replace every old tab write.** Exact replacements:
  - `ContentView.swift`: `state.tab = .temp` → `state.openCodeStore()` (all sites incl. `LineStoreScreen(onOpenSms: { state.flow = nil; state.tab = .temp }` → `{ state.flow = nil; state.openCodeStore() }`); `state.tab = .home` → `state.tab = .verify; state.verifyPath = []`; `case .orders:` in the old tab switch is gone with Step 3; `if tab == .line` (~371) unchanged.
  - `OrdersScreen.swift:238` `action: { state.tab = .temp }` → `action: { state.openCodeStore() }`.
  - `EsimDetailScreen.swift:83` `state.flow = nil; state.tab = .temp` → `state.flow = nil; state.openCodeStore()`.
  - `OtpScreen.swift:466` (`state.tab = .line`) unchanged.
  - In the screenshot switch (`applyScreenshotState`), `.home, .deliveryInfo` and the other `.temp` sites become `state.openCodeStore()` (with `emailMode` set as each case sets it today, AFTER the call).

- [ ] **Step 6: Delete the custom tab bar**: `git rm VirtualSIM/Components/TabBar.swift`.

- [ ] **Step 7: Prove no stale tab writes remain**

```bash
grep -rnE "\.tab = \.(temp|home|orders)|AppTab\.(currentOrder|launchOrder|productOrder|defaultOrder)|case \.temp:|TabBar\(" VirtualSIM || echo CLEAN
```
Expected: `CLEAN`. (`HomeScreen.swift` still references `.temp`/`productOrder` — it is deleted in Task 6; if this grep only hits `HomeScreen.swift`, that is expected at this step. Note it and continue.)

- [ ] **Step 8: Build.** If `HomeScreen.swift` blocks the build on removed symbols, replace its `state.tab = .temp` with `state.openCodeStore()` and its `AppTab.productOrder` loop with `[AppTab.line]` — a stopgap Task 6 deletes. Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Screenshots** — for each of `homeLine`, `lineInbox`, `orders`, `code`: launch with `-screenshot <name>`, screenshot. Then relaunch with `-AppleLanguages "(de)" -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXL -screenshot lineInbox`. Expected: system tab bar with four labelled tabs on every frame, My number badge where the fixture has unread; German labels not clipped; `ResumeBar` above the bar when an order is waiting (`waiting` fixture, then tap ✕ is not automatable — instead set `state.flow = nil` in the `waiting` fixture's copy `waitingClosed` if needed, added in Task 7).

- [ ] **Step 10: Docs** — in `CLAUDE.md` replace the "### Home leads the app (2026-09-10)" section's first paragraph with a dated note: "**Superseded on branch `design-overhaul` (2026-09-24):** tabs are Verify · My number · Activity · Account in a fixed order; `/tabs` no longer orders anything in builds from this branch. The text below describes `main`." Update `.claude/rules/ios-client.md`'s layout line for `ContentView.swift` to "native TabView, 4 tabs (verify/line/activity/account, `AppTab.order`)" and remove `TabBar` from Components.

- [ ] **Step 11: Checks + commit**

```bash
git diff main --stat -- supabase VirtualSIM/Onboarding   # must print nothing
git add -A VirtualSIM CLAUDE.md .claude/rules/ios-client.md
git commit -m "shell: native four-tab TabView (Verify · My number · Activity · Account)"
```

---

### Task 6: Verify screen

**Files:**
- Create: `VirtualSIM/Screens/VerifyScreen.swift`
- Create: `VirtualSIM/Components/VerifyTile.swift`
- Delete: `VirtualSIM/Screens/HomeScreen.swift`
- Modify: `VirtualSIM/ContentView.swift` (screenshot cases `homeRouter`/`homeLine` → Task 7)
- Create: `/tmp/p1-verify.json`

**Interfaces:**
- Consumes: `AppState.services`, `.orders`, `.line`, `.linesLoaded`, `.balance`, `.visibleAnnouncement`, `.dismissAnnouncement()`, `.commitServicePick(_:)`, `.openCodeStore(email:)`, `ServiceLogo(service:size:radius:)`, `AnnouncementBanner(announcement:onDismiss:)`, `RHaptic.select()`, `.pressable()`, `Analytics.shared.track(_:_:)`, `RSpace`, `RRadius.card`.
- Produces: `VerifyScreen(openCredits: () -> Void, openServices: () -> Void)`; `VerifyTile(label: Text, action: () -> Void, icon: () -> Icon)`; event `verify_view {guest: Bool, has_line: Bool, lines_loaded: Bool}`; `service_selected {service, source: "verify" | "verify_search" | "verify_recent"}`.

- [ ] **Step 1: `VerifyTile.swift`** — the old `HomeScreen.GridTile`, restyled to overhaul tokens:

```swift
import SwiftUI

/// One app tile on Verify. Kept as the only tile body so every cell in the
/// grid is the same height.
struct VerifyTile<Icon: View>: View {
    @Environment(\.theme) private var theme
    let label: Text
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: RSpace.sm) {
                icon
                label
                    .font(RFont.text(12, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, RSpace.md)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                    .strokeBorder(theme.sep, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: RRadius.group))
        }
        .pressable()
    }
}
```

- [ ] **Step 2: `VerifyScreen.swift`**

```swift
import SwiftUI

/// The Verify tab (spec §6.1): one question, the apps people verify most, a
/// search, and category chips. Nothing is pre-selected: a tap is the user's
/// own pick through `commitServicePick`, which clears `needsServiceChoice`
/// and leaves `needsCountryChoice` set.
struct VerifyScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    var openCredits: () -> Void
    var openServices: () -> Void

    @State private var query = ""
    @State private var category: String? = nil
    @State private var tracked = false

    /// Ordered by order volume (the old Home grid's seven + Snapchat as the
    /// eighth, reviewed 2026-09-24). A missing id is skipped, never a hole.
    static let featuredIds = [
        "whatsapp", "telegram", "instagram", "google",
        "tiktok", "discord", "tinder", "snapchat",
    ]

    /// Chips map 1:1 to real `Service.category` values (spec §6.1). Never
    /// Gambling.
    static let chipCategories = ["Messaging", "Social", "Dating", "Commerce", "Finance", "Delivery"]

    private var hasLiveLine: Bool {
        state.linesLoaded && (state.line?.status.isLive ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let announcement = state.visibleAnnouncement {
                    AnnouncementBanner(announcement: announcement) {
                        state.dismissAnnouncement()
                    }
                    .padding(.top, RSpace.lg)
                }
                if hasLiveLine, let line = state.line {
                    lineStrip(line).padding(.top, RSpace.lg)
                }
                searchField.padding(.top, RSpace.xl)
                if isSearching {
                    results.padding(.top, RSpace.md)
                } else {
                    if !recentServices.isEmpty {
                        recentRow.padding(.top, RSpace.xl)
                    }
                    grid.padding(.top, RSpace.xl)
                    chips.padding(.top, RSpace.lg)
                }
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.bottom, RSpace.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard !tracked else { return }
            tracked = true
            Analytics.shared.track("verify_view", [
                "guest": .bool(false),   // Plan 2 wires the real guest flag
                "has_line": .bool(hasLiveLine),
                "lines_loaded": .bool(state.linesLoaded),
            ])
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                Text("What do you want to verify?")
                    .displayType(30)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Get a code for an app. No code? Your credits come back.")
                    .font(RFont.text(15))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: RSpace.md)
            Button(action: openCredits) {
                HStack(spacing: 6) {
                    CoinIcon(size: 14)
                    Text("\(state.balance)").numberStyle(size: 15, color: theme.text)
                }
                .padding(.horizontal, RSpace.md)
                .padding(.vertical, RSpace.sm)
                .background(theme.chipBg, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Credits: \(state.balance)"))
        }
        .padding(.top, RSpace.lg)
    }

    private func lineStrip(_ line: Line) -> some View {
        HStack(spacing: RSpace.md) {
            Image(systemName: "phone.fill").foregroundStyle(theme.live)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your number").font(RFont.text(12, weight: .semibold)).foregroundStyle(theme.text3)
                Text(verbatim: line.e164).numberStyle(size: 17, color: theme.text)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = line.e164
                RHaptic.select()
            } label: {
                Text("Copy").font(RFont.text(14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(theme.ink)
        }
        .padding(RSpace.lg)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
    }

    // MARK: Search

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || category != nil
    }

    private var searchField: some View {
        HStack(spacing: RSpace.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.text3)
            TextField(String(localized: "Search \(state.services.count) apps"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if isSearching {
                Button {
                    query = ""
                    category = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.text3)
                }
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, RSpace.md)
        .frame(height: 44)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }

    private var matches: [Service] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return state.services.filter { s in
            (category == nil || s.category == category)
                && (q.isEmpty || s.name.lowercased().contains(q))
        }
    }

    @ViewBuilder
    private var results: some View {
        let list = matches
        if list.isEmpty {
            Text("No apps match")
                .font(RFont.text(15))
                .foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, RSpace.xxl)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(list) { service in
                    Button { pick(service, source: "verify_search") } label: {
                        HStack(spacing: RSpace.md) {
                            ServiceLogo(service: service, size: 32, radius: 8)
                            Text(verbatim: service.name)
                                .font(RFont.text(16))
                                .foregroundStyle(theme.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.text3)
                        }
                        .padding(.vertical, RSpace.md)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(theme.sep)
                }
            }
        }
    }

    // MARK: Recent, grid, chips

    private var recentServices: [Service] {
        var seen = Set<String>()
        var out: [Service] = []
        for order in state.orders where !seen.contains(order.service.id) {
            seen.insert(order.service.id)
            out.append(order.service)
            if out.count == 3 { break }
        }
        return out
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: RSpace.sm) {
            Text("Recent").font(RFont.text(13, weight: .semibold)).foregroundStyle(theme.text3)
            HStack(spacing: RSpace.sm) {
                ForEach(recentServices) { service in
                    Button { pick(service, source: "verify_recent") } label: {
                        HStack(spacing: RSpace.sm) {
                            ServiceLogo(service: service, size: 22, radius: 6)
                            Text(verbatim: Self.tileLabel(service))
                                .font(RFont.text(14, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, RSpace.md)
                        .padding(.vertical, RSpace.sm)
                        .background(theme.elev, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var featured: [Service] {
        let wanted = Set(Self.featuredIds)
        var found: [String: Service] = [:]
        for s in state.services where wanted.contains(s.id) { found[s.id] = s }
        return Self.featuredIds.compactMap { found[$0] }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: RSpace.sm), count: 4),
                  spacing: RSpace.sm) {
            ForEach(featured) { service in
                VerifyTile(label: Text(verbatim: Self.tileLabel(service))) {
                    pick(service, source: "verify")
                } icon: {
                    ServiceLogo(service: service, size: 38, radius: 11)
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RSpace.sm) {
                ForEach(Self.chipCategories, id: \.self) { c in
                    Button {
                        RHaptic.select()
                        category = (category == c) ? nil : c
                    } label: {
                        Text(LocalizedStringKey(c))
                            .font(RFont.text(14, weight: .semibold))
                            .foregroundStyle(category == c ? theme.onInk : theme.text)
                            .padding(.horizontal, RSpace.md)
                            .padding(.vertical, RSpace.sm)
                            .background(category == c ? theme.ink : theme.chipBg, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Actions

    private func pick(_ service: Service, source: String) {
        RHaptic.select()
        Analytics.shared.track("service_selected", [
            "service": .string(service.id),
            "source": .string(source),
        ])
        state.commitServicePick(service)
        state.openCodeStore()
    }

    /// One product word per tile ("Google / YouTube / Gmail" → "Google").
    static func tileLabel(_ service: Service) -> String {
        let head = service.name.split(separator: "/", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return head.isEmpty ? service.name : head
    }
}
```
Before building, confirm three names by grep and adapt the code to what exists (do not invent): `CoinIcon` initializer (`grep -n "struct CoinIcon" -A6 VirtualSIM/DesignSystem/Icons.swift`), `LineStatus.isLive` (`grep -n "isLive" VirtualSIM/Models/LineModels.swift`), and that `"snapchat"` is a real service id (`supabase db query --linked "select id from services where id='snapchat';"` — if absent, drop it and leave seven tiles).

- [ ] **Step 3: Catalog entries** — `/tmp/p1-verify.json`:

```json
{
  "What do you want to verify?": {"de": "Was möchten Sie verifizieren?", "es": "¿Qué quieres verificar?", "fr": "Que voulez-vous vérifier ?", "it": "Cosa vuoi verificare?", "ja": "何を認証しますか？", "pt-BR": "O que você quer verificar?"},
  "Get a code for an app. No code? Your credits come back.": {"de": "Holen Sie sich einen Code für eine App. Kein Code? Ihre Credits kommen zurück.", "es": "Consigue un código para una app. ¿Sin código? Recuperas tus créditos.", "fr": "Obtenez un code pour une app. Pas de code ? Vos crédits vous sont rendus.", "it": "Ricevi un codice per un'app. Nessun codice? I crediti tornano a te.", "ja": "アプリの認証コードを受け取れます。コードが届かなければクレジットは戻ります。", "pt-BR": "Receba um código para um app. Sem código? Seus créditos voltam."},
  "Your number": {"de": "Ihre Nummer", "es": "Tu número", "fr": "Votre numéro", "it": "Il tuo numero", "ja": "あなたの番号", "pt-BR": "Seu número"},
  "Copy": {"de": "Kopieren", "es": "Copiar", "fr": "Copier", "it": "Copia", "ja": "コピー", "pt-BR": "Copiar"},
  "Search %lld apps": {"de": "%lld Apps durchsuchen", "es": "Buscar en %lld apps", "fr": "Rechercher parmi %lld apps", "it": "Cerca tra %lld app", "ja": "%lld件のアプリを検索", "pt-BR": "Buscar em %lld apps"},
  "Clear search": {"de": "Suche löschen", "es": "Borrar búsqueda", "fr": "Effacer la recherche", "it": "Cancella ricerca", "ja": "検索をクリア", "pt-BR": "Limpar busca"},
  "No apps match": {"de": "Keine passenden Apps", "es": "Ninguna app coincide", "fr": "Aucune app ne correspond", "it": "Nessuna app corrispondente", "ja": "一致するアプリはありません", "pt-BR": "Nenhum app encontrado"},
  "Recent": {"de": "Zuletzt", "es": "Recientes", "fr": "Récents", "it": "Recenti", "ja": "最近", "pt-BR": "Recentes"},
  "Credits: %lld": {"de": "Credits: %lld", "es": "Créditos: %lld", "fr": "Crédits : %lld", "it": "Crediti: %lld", "ja": "クレジット：%lld", "pt-BR": "Créditos: %lld"},
  "Messaging": {"de": "Messenger", "es": "Mensajería", "fr": "Messagerie", "it": "Messaggistica", "ja": "メッセージ", "pt-BR": "Mensagens"},
  "Social": {"de": "Soziale Netzwerke", "es": "Redes sociales", "fr": "Réseaux sociaux", "it": "Social", "ja": "SNS", "pt-BR": "Redes sociais"},
  "Dating": {"de": "Dating", "es": "Citas", "fr": "Rencontres", "it": "Incontri", "ja": "出会い", "pt-BR": "Encontros"},
  "Commerce": {"de": "Shopping", "es": "Compras", "fr": "Achats", "it": "Acquisti", "ja": "ショッピング", "pt-BR": "Compras"},
  "Finance": {"de": "Finanzen", "es": "Finanzas", "fr": "Finance", "it": "Finanza", "ja": "金融", "pt-BR": "Finanças"},
  "Delivery": {"de": "Lieferdienste", "es": "Reparto", "fr": "Livraison", "it": "Consegne", "ja": "デリバリー", "pt-BR": "Entregas"}
}
```
Keys that already exist (check with `python3 -c "import json;s=json.load(open('VirtualSIM/Localizable.xcstrings'))['strings'];print([k for k in json.load(open('/tmp/p1-verify.json')) if k in s])"`) must be removed from the JSON first, so existing translations are not overwritten. Then run `python3 scripts/xcstrings-add.py /tmp/p1-verify.json`.

- [ ] **Step 4: Delete Home** — `git rm VirtualSIM/Screens/HomeScreen.swift`. Its `home_view` / `home_card_tapped` events retire with it (spec §8). `NameSheet.swift` stays (Account adopts it in a later plan).

- [ ] **Step 5: Build + screenshots** — build; then capture `-screenshot homeRouter` and `-screenshot homeLine` (their fixtures still set `tab = .verify` after Task 5; renamed in Task 7). Expected: title + subtitle, search, 7–8 tiles, chips; `homeLine` also shows the "Your number" strip with the sample e164. Also capture the Review Focus 1 case: temporarily run the `homeRouter` fixture with `state.services = Array(state.services.prefix(2))` (local edit, not committed) and confirm no holes and "No apps match" on a nonsense query typed via `xcrun simctl io … ` is not automatable — instead set `query` default to `"zzzz"` in the local edit. Revert the local edit.

- [ ] **Step 6: Consultant review** — send both consultants the two PNG paths with: "Plan 1 Verify screen, first cut. Name the three changes you would make first, with the spec section." Apply fixes that stay inside §6.1; record the rest for Plan 2.

- [ ] **Step 7: Commit**

```bash
git diff main --stat -- supabase VirtualSIM/Onboarding   # must print nothing
git add -A VirtualSIM
git commit -m "verify: the Verify tab replaces Home — one question, apps, search, categories"
```

---

### Task 7: Screenshot fixtures for the new shell

**Files:**
- Modify: `VirtualSIM/DesignSystem/ScreenshotMode.swift` (`Screen` cases)
- Modify: `VirtualSIM/ContentView.swift` (`applyScreenshotState`)
- Modify: `scripts/screenshots/capture-frames.sh`, `scripts/screenshots/make-set.py`

**Interfaces:**
- Produces: `ScreenshotMode.Screen` cases `verify` (was `homeRouter`), `verifyLine` (was `homeLine`), `activity` (new: Activity tab with the sample orders), `waitingClosed` (new: an order waiting, flow closed, Verify tab — shows `ResumeBar`). `home` keeps its name (temp store; renamed when Plan 2 replaces the store).

- [ ] **Step 1: Rename the enum cases** `homeRouter` → `verify`, `homeLine` → `verifyLine`; add `activity`, `waitingClosed` with one-line comments like their neighbours.

- [ ] **Step 2: Fixtures** — in `applyScreenshotState`: rename the two cases; they set `state.tab = .verify; state.verifyPath = []` and whatever sample data they set today. Add:

```swift
        case .activity:
            // Same sample orders as `.orders`, shown in the Activity TAB.
            state.orders = ScreenshotMode.sampleOrders
            state.tab = .activity
        case .waitingClosed:
            // An order in flight with its screen closed: ResumeBar above the
            // system tab bar (Review Focus 4).
            state.orders = ScreenshotMode.sampleOrders
            state.flow = nil
            state.tab = .verify
```
Check the real sample-data names first (`grep -n "static let sample" VirtualSIM/DesignSystem/ScreenshotMode.swift`) and use them; ensure `sampleOrders` contains a `.waiting` order for `waitingClosed` (add one if not).

- [ ] **Step 3: Scripts** — in `capture-frames.sh` and `make-set.py` replace `homeRouter` with `verify`.

- [ ] **Step 4: Build + capture every fixture** — `for s in verify verifyLine activity waitingClosed home email lineStore lineInbox linePaywall credits orders waiting code mailPaywall deliveryInfo; do …; done` (same loop as `/Users/adyl/.claude/jobs/c5c3d119/tmp/shots.sh`). Expected: every frame renders, four labelled tabs on every tab-level frame, `ResumeBar` visible in `waitingClosed`.

- [ ] **Step 5: Commit**

```bash
git diff main --stat -- supabase VirtualSIM/Onboarding   # must print nothing
git add VirtualSIM/DesignSystem/ScreenshotMode.swift VirtualSIM/ContentView.swift scripts/screenshots
git commit -m "fixtures: verify / verifyLine / activity / waitingClosed for the new shell"
```

---

## Self-review (done while writing)

- Spec coverage for Plan 1's scope: §5 tokens (Task 2), splash (Task 3), §4 tabs + removals + ResumeBar (Task 5), §6.1 Verify (Task 6), §10 step 2 guest-safe cold start (Task 4), §9 fixtures for the touched screens (Task 7), §11 checks (every task). Out of scope and deferred by design: §6.2–6.12, sign-in sheet, analytics queue flush (already gated in `Analytics`), `tabViewBottomAccessory`.
- Known gap carried to Plan 2: `verify_view.guest` is hardcoded `false` until the guest flag exists.
- Names used across tasks: `AppTab.order`, `VerifyRoute.store`, `AppState.verifyPath`, `AppState.openCodeStore(email:)`, `AppState.loadAccount(api:progress:)`, `RSpace`, `RMotion.standard`, `RRadius.card/group`, `numberStyle`, `selectedEmphasis`, `VerifyTile`, `VerifyScreen` — consistent throughout.
