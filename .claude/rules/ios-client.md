---
paths:
  - "VirtualSIM/**"
---

# iOS client — layout, rendering traps, and state invariants

Loaded automatically when working under `VirtualSIM/`. Split out of the root
CLAUDE.md on 2026-08-06.

⚠️ Every entry is a bug that shipped. The money-path and provider rules stay in
the root CLAUDE.md deliberately — they must be in context even when no Swift
file is open.

## iOS source layout

```
VirtualSIM/
  VirtualSIMApp.swift            App entry; resizes URLCache (32MB mem / 64MB disk
                                 for brand logos + flag PNGs); installs AppDelegate
  ContentView.swift              native TabView, 4 tabs (verify/line/activity/
                                 account; the order is the Tab declaration
                                 order in ContentView, `AppTab.order` mirrors
                                 it); the temp store (`TempScreen`) is
                                 the Verify tab's NavigationStack ROOT
                                 (`AppState.openCodeStore` selects tab +
                                 mode, pushes nothing); `ResumeBar` rides a
                                 bottom `safeAreaInset` on every tab;
                                 the My number tab is `LineScreen`, a
                                 `NavigationStack(path: $state.linePath)`
                                 whose destinations are `LineRoute`
                                 (`countries`, `cities`, `thread(id)`,
                                 `compose`), registered by
                                 `.lineRouteDestinations()`;
                                 `AppState.openLineThread(_:)` is how a
                                 line-SMS push opens a conversation (closes
                                 any cover, selects `.line`, pushes). Covers
                                 left on the line: `lineCheckout`,
                                 `lineProvisioning`, `dialer`,
                                 `lineStoreMore` (→ `LineStoreCover`, its own
                                 stack)
                                 + fullScreenCover for Checkout/Waiting/OTP
                                 + the parked eSIM flow; EnvBundle
                                 ViewModifier re-injects every @Observable env
                                 object into sheet/cover content (covers don't
                                 inherit reliably)
  Auth/                          AuthGate (3-state: bootstrap/signedOut/signedIn),
                                 SignInScreen, Session (@Observable, Keychain-backed)
  Networking/                    APIClient + per-resource APIs (CatalogAPI, OrdersAPI,
                                 WalletAPI, ProfileAPI, IAPAPI, AccountAPI, PushAPI,
                                 AuthAPI). Secrets.swift is gitignored
  State/AppState.swift           Single @Observable source of truth — services,
                                 countries, routes, orders, prefs (UserDefaults-
                                 backed via didSet), checkout/flow machine
  Models/                        Plain Codable structs mirroring DB column names via
                                 .convertFromSnakeCase (Service, Country, Route,
                                 Order, EsimPlan, EsimOrder, CreditPack,
                                 CountryRank = the PROVIDER's success rate for a
                                 (service, country) — steering input, never a
                                 badge; see the steering section)
  Screens/                       TempScreen (the Temp tab on `main`; on
                                 `design-overhaul` the Verify tab's root,
                                 headed "What do you want to verify?", no
                                 Recent list: temp SMS + temp e-mail,
                                 `emailMode`; the grid `VerifyScreen` /
                                 `VerifyTile` it replaced were deleted
                                 2026-09-24. `HomeScreen` is main's Home tab
                                 — see CLAUDE.md "Home leads the app"),
                                 `LineStoreScreen` (inline store:
                                 `CapsuleSegmentedControl` country choice,
                                 ✓/✗ `LineLedger`, three inline numbers
                                 searched on appear behind a session guard;
                                 no price, no one-off-code link since
                                 2026-09-25) + `LineStorePages`
                                 (`LineStoreSearch`, `LineCountriesPage`,
                                 `LineCitiesPage`, `LineStoreCover`);
                                 `LineNumberSegment` (replaced
                                 `LineSettingsScreen`, deleted 2026-09-24),
                                 Checkout, Waiting (+ WaitingAnimations),
                                 OTP (⚠️ fires NO review prompt — see "The
                                 review prompt" below; it did until 2026-08-19
                                 and must not again), Orders, Account,
                                 + the eSIM flow,
                                 reached from no tab since 2026-09-08
                                 (EsimStore = Store/My eSIMs/Activity segments,
                                 EsimMapView = clustered MapKit country picker,
                                 EsimCountryPlans = duration→size chooser,
                                 EsimActivity = usage metrics + history,
                                 EsimCheckout, EsimDetail = QR + usage),
                                 Recovery (post-failure: retry on a fresh number /
                                 switch country / refund explainer — see the
                                 retry-steering note below), Maintenance (shown
                                 during the nightly operator-sync window),
                                 SplashScreen (cold-launch cover — see below),
                                 EmailWaiting/EmailCode (temp email).
                                 SupportChatScreen (live chat) was DELETED
                                 2026-09-05 — support is an external chat link,
                                 `LegalLinks.supportURL` (server-controlled via
                                 `app_config.support_url`, default @vSMSAPP on
                                 Telegram), from the Temp tab, Account and
                                 `DeliveryInfoSheet`
  Sheets/                        EmailDomainSheet (4 domains, live stock,
                                 Free/1cr), ServiceSheet (search + categories + per-route
                                 price; a service with no route in the SELECTED
                                 country shows where it IS bookable, never a bare
                                 "Unavailable" — see the picker note below),
                                 CountrySheet (sort + per-route price),
                                 CreditsSheet (StoreKit 2), NameSheet (the name
                                 Home greets by — raised from the greeting, the
                                 only place that name is shown; mirrors
                                 `AppState.greetingName`'s rejections and stays
                                 OPEN on a failed write; on `design-overhaul`
                                 Account's headline name presents it, since
                                 `HomeScreen` and its greeting are gone)
  Components/                    Theme primitives + ServiceLogo / FlagImage /
                                 FlagCircle — bundle-first via BundledImageStore,
                                 network cascade (DuckDuckGo/FaviconV2, flagcdn) as
                                 fallback; SuccessBadge renders MEASURED delivery
                                 odds only (grey/amber/red), never seed rates;
                                 BrandWordmark (green `v` + SMS — the logo, and on
                                 the splash also the loading indicator);
                                 CodeFlag (flag from a bare ISO2 — the eSIM
                                 catalog has no `Country`); DataRing/DataBar
                                 (usage gauges, show REMAINING not used);
                                 `LineNumberCard` (+ `LiveDot`), `LineLedger`,
                                 `CapsuleSegmentedControl`; `LineOfferList` in
                                 `LinePickerRows`; `PeerAvatar(neutral:)`
  Push/, IAP/, Onboarding/       Self-explanatory
  DesignSystem/                  Theme, Typography, Icons + **Motion.swift**
                                 (`RMotion`: one animation vocabulary named by
                                 what moves — select/panel/content/value/camera
                                 + `stagger`. Use these, not inline curves;
                                 `RMotion.unlessReduced(_:_:)` — every My
                                 number animation goes through it; `riseIn`
                                 now honours Reduce Motion app-wide (no
                                 offset, no animation))
                                 + **Glass.swift** (`.glassPanel(shape:)` —
                                 Liquid Glass on iOS 26, frosted material below.
                                 See the note below: the availability guard
                                 lives HERE and nowhere else)
  Localizable.xcstrings          String Catalog: en source + ar/de/es/fr/it/ja/pt-BR
  Products.storekit              Local IAP test config (enable via scheme)
  VirtualSIM.entitlements        Sign in with Apple + aps-environment
```

## The My number tab (branch `design-overhaul`, 2026-09-24)

What the code does not tell you. The tab's layout is in the source-layout
block above; its line-product rules (US/PR list, Switch, calling over a
pushed thread) are in `.claude/rules/telephony.md` and CLAUDE.md.

1. **`openThreadId` is set by `ThreadScreen` on appear and before every send,
   and is no longer cleared by `flow.didSet`.** `sendLineMessage` takes the
   sending line from the open thread, and a dialer cover raised over a thread
   would otherwise wipe it, so the reply would go out from the wrong line.
   `ComposeScreen` clears it on appear for the opposite reason: a new message
   must not inherit the last thread's line.
2. **The inline store's skeleton shows while `lineOffers` is empty AND
   `lineUnavailableReason` is nil** ("not answered yet"), so the error state
   never flashes before the first search lands.
3. **`line_numbers_shown` changed meaning** (see CLAUDE.md, "Behavioural
   analytics"): it now fires on every inline search with `source:
   "store_inline"`, so it is not comparable with `main`'s "opened the picker".
4. **The number on `LineNumberCard` is 24 pt beside the Switch capsule and
   28 pt without it** (no Switch offered, or an accessibility text size, where
   the capsule wraps to its own row). This is a deliberate deviation from spec
   §4.3, which said 28: the capsule has to share the row. The size is set
   explicitly (`numberSize`); `minimumScaleFactor(0.7)` is only a safety net.
5. **A line-SMS push loads the line BEFORE it pushes the thread**
   (`ContentView`'s `pendingLineThreadId` handler: `loadLine`, then
   `loadLineThreads`, then `openLineThread`). `LineScreen` empties `linePath`
   whenever the line's liveness changes, so a `my_line` read landing after the
   push would pop the thread just opened. ⚠️ The guard is incomplete: if that
   `loadLine` fails, a later read can still flip liveness and pop the thread.
   A thread id that did not load is never pushed; the tab opens instead.
6. **A cold launch from a line push races `resumeInFlightOrder`'s Waiting
   cover, and whichever finishes last wins** (read from code, not observed).
   `openLineThread` sets `flow = nil`, which closes a Waiting cover raised
   first; `resumeInFlightOrder` raises the cover only while `flow == nil`, so
   it lands over a thread pushed first.
7. **ResumeBar is HIDDEN while ANY page is pushed on `linePath` and the My
   number tab is showing** (`resumeBarInset(yieldsToPushedLinePages:)`, that
   tab only; the hide and return are eased with `RMotion.content`, skipped
   under Reduce Motion). The bar rides the tab root's `safeAreaInset`
   (`TabChrome`), and that inset does not reach a page pushed on the stack:
   measured 2026-09-24, a pushed `ThreadScreen` read `safeAreaInsets.bottom`
   83 with the bar up and without it. So the bar drew over the thread's
   composer, compose's Send button and the store's country / city pages'
   bottom rows. Re-hosting the bar inside each page was rejected because it
   would sit between the composer and the keyboard while typing. Every pushed
   page is one pop from the bar. Proof frames: `threadResume`, and
   `composeResume` (the To field focuses on appear, so that frame also shows
   Send clear of the keyboard).
8. **German-width rules found by the same capture.** The paywall header title
   gets only the width the ✕ and Restore leave, and is DROPPED rather than
   overlapping ("Wiederherstellen"); it stays hidden until Restore has been
   measured, and ONE accessibility header element carries the screen name
   either way. `CapsuleSegmentedControl` reports an ideal width of widest
   label × count (`EqualWidthRow`), so the store's `ViewThatFits` falls back
   to the country menu instead of truncating "Vereinigte Staaten" in an equal
   third. The number card's area code never truncates; the country name gives
   way first.
9. **Screenshot fixtures:** `lineIntro` (loading, no price shim), `lineStore`,
   `lineStoreError`, `linePaywall` / `linePaywallYearly` (a Canadian number:
   `lineCountry = "CA"`, scrolled to the plans), `linePaywallUS` (the top of
   the paywall with the US/PR note), `lineInbox`, `lineInboxEmpty`,
   `lineInboxMulti`, `lineCalls`, `lineNumber`, `lineBanner`,
   `lineSwapConfirm`, `lineDialer`, `thread`, `threadResume` /
   `composeResume` (a pushed thread / compose page with a temp-SMS order in
   flight), `lineInCall` (a DEBUG-only
   `CallController.screenshotLiveCall(peer:)` fakes the answered call),
   `linePushThread` (sets `pendingLineThreadId` from `ContentView`'s `.task`,
   so it exercises the handler's CHANGE path, not the `initial: true`
   cold-launch path), and `lineSwitchGlow` (a DEBUG-only hook in
   `LineNumberCard` lands a Switch 4 s in through the real `swappedTo` path, so
   a still at about 5–6 s catches the card's glow mid-fade; the card keeps the
   old number because the fixture's line does not change). In screenshot mode
   DEBUG builds echo every analytics event to NSLog as `[analytics] <name>
   <props>`; capture it with `simctl launch --stderr=<file>`.

## Cold launch — the splash, and why readiness is not a timer

`AppState` starts from `SeedData` with `routes = []`, so `cost(for:country:)`
returns nil for **every** pair. Before `SplashScreen` existed the launch was:
blank system launch screen → a bare `ProgressView` → a buy-a-code screen
(`TempScreen`, named `HomeScreen` until 2026-09-10) whose primary CTA read
**"Unavailable · Pick another country"** for the whole fetch. The seed
default pair is WhatsApp/United States, which is in `blocked_routes` and never
bookable, so it stayed wrong until `applyStartupSelection()` ran at the END of
the chain. A first-run user met a screen saying the product was unavailable —
expensive here specifically, because activation is a single-session event
(median signup → first order is 2 minutes).

- **`AppState.coldStart(api:)`** owns the sequence and publishes `bootPhase` +
  `bootProgress` from steps that actually completed. **Never fill that bar on a
  timer** — a synthetic bar is the same class of claim as a seeded success rate.
- **Readiness is NOT "the chain finished".** The two eSIM fetches are read only
  by the eSIM screens, so they run *after* `bootPhase = .ready`, behind the
  revealed UI, instead of holding a correct first screen behind them.
- **The e-mail data is PREFETCHED, never awaited** (branch `design-overhaul`,
  2026-09-24). `loadAccount` calls `prefetchEmail` right after `loadOrders`:
  two unstructured main-actor `Task`s (the domain quote for `startupService`,
  and `loadEmailOrders`) that overlap the line reads and the splash fade.
  Nothing on the reveal path awaits them, so boot is not longer. They
  interleave with the chain only at `await`s on the main actor — not the
  `async let` race below — and the quote's staleness guard
  (`AppState.acceptsEmailQuote`: a generation counter plus a service check)
  decides whether a late answer still applies. A quote under
  `emailQuoteDisplayWindow` (10 min) is what makes the E-mail tap instant:
  it renders with the CTA live and refreshes silently; the pending layout
  appears only with no quote held or one past the window. The mail plan's
  StoreKit price warms on
  `bootPhase == .ready` (`mailStore.load(reportingFailure: false)`). Detail
  in CLAUDE.md, "The temp-e-mail product".
- **`loadCatalog` returns `Bool`.** It used to be `-> Void` with a bare
  `catch { /* keep current state */ }`, so an offline launch silently kept the
  30-service seed stub and rendered a full Temp screen on which every service
  read "Unavailable" — indistinguishable from "this product is broken". The
  splash now offers **Try again** / **Continue anyway**. It still keeps existing
  data when a *foreground* refresh fails; only the cold path treats it as failure.
- The splash sits **above** the maintenance overlay but hands off once
  maintenance is known active — that screen is the honest answer and must not
  wait behind five more fetches.
- 🔴 **There is ONE splash per launch, `LaunchCover`, hosted by `AuthGate`**
  (branch `design-overhaul`, 2026-09-24) as an `overlayPreferenceValue` above
  BOTH the session bootstrap and `ContentView`. `ContentView` owns `AppState`,
  so it publishes its half (`launchCoverReport`: `bootPhase` / `bootProgress`,
  maintenance, and the Try again / Continue anyway closures) up through
  `LaunchCoverKey`; while `session.status == .bootstrapping` there is no
  `ContentView` and the cover draws `.indeterminate`. Signed out there is no
  cover, and its state resets for the next sign-in. It replaced TWO instances
  (`AuthGate`'s bootstrap splash and a `ContentView` overlay): the second
  started from scratch, so the wordmark's type-on replayed and the `v`'s spin
  restarted mid-launch. **Do not re-add a splash inside either phase** — the
  view's identity surviving the bootstrap → signed-in swap is the whole fix.
- **The handoff** (on `bootPhase == .ready`, or maintenance): hit-testing goes
  off on the same frame, the background fades over `RMotion.handoff` (ease-out
  0.5 s, `handoffSeconds`), the wordmark glides up 40 pt, and the foreground
  (mark, line, caption) fades faster on `RMotion.content` — at one shared
  opacity the glyphs ghosted over the store's cards while the background had
  already vanished into the identical colour behind it (seen in a recording).
  `LaunchCover` unmounts exactly `handoffSeconds` later and keeps drawing the
  last COVERING state meanwhile — its retry / continue closures latched with
  it, because `ContentView` stops sending them once `bootPhase` leaves
  `.failed` and the footer's `if let` buttons would otherwise vanish on the
  first fade frame (the footer collapsed and the mark dropped ~130 pt) — so
  "Continue anyway" fades the failure footer out whole (code-verified only). Under Reduce Motion: no glide, no
  breath, a plain crossfade (the store's `riseIn` is already off there) —
  ⚠️ code-verified only; simctl has no Reduce Motion switch.
- **Remount and churn.** If the cover has handed off onto MAINTENANCE and
  maintenance ends mid-load, it fades back in (`.transition(.opacity)` +
  `withAnimation(RMotion.handoff)`; code-verified only). A handoff onto a
  READY app is `settled` (`bootPhase == .ready` never goes back), and
  `LaunchCover.onFinished` latches `AuthGate.launchCoverDone` (the handoff
  task is keyed on `revealed` AND `settled`, so maintenance → ready while
  maintenance is still on still latches), so the cover
  never renders again that session; it resets on sign-out. `ContentView`
  sends the retry / continue closures ONLY in the failure state: a fresh
  closure per body made every report differ, so the overlay re-ran on every
  `ContentView` update. Measured 2026-09-25 with a temporary log in the
  overlay closure over a 15 s `splashHandoff` launch: 5 runs in total, the
  last being the latch.
- **`TempScreen`'s `riseIn` stagger starts on the reveal**, not on mount: its
  `appeared` flips on `bootPhase == .ready` (or at once in `.task` if the app
  is already up). It mounts under the cover, so an entrance started in `.task`
  finished unseen.
- ⚠️ **A splash `.task` timer must `do`/`return` on a cancelled sleep, never
  `try?`**: a cancelled `Task.sleep` throws at once and `try?` falls through,
  which showed the line and the caption the instant the task was replaced.
- Fixtures: `splash` (the mark alone, not breathing, so a still never catches
  it mid-breath), `splashSlow` (line at 60% + caption), `splashFailed` (the
  failure footer, inert buttons; its pin leaves breathing to the STATE, so it
  proves the failure state is what stops the breath), and `splashHandoff`
  (for a screen RECORDING: the real unpinned cover lifted by a real
  `bootPhase` flip 2.5 s in — every other fixture is ready before the system's
  launch animation ends, so its handoff is never on screen). Verified
  2026-09-24 from `splashHandoff` recordings (dark + light) and fixture stills;
  a real signed-in cold launch was NOT recorded (the simulator has no
  session), and Reduce Motion is code-verified only. The failure-state stop
  is FRAME-verified (2026-09-25): 8 `splashFailed` stills ~0.8 s apart (5.6 s, longer than one 3.2 s breath), dark
  and light, are pixel-identical outside the status bar, and the glyphs sample
  at full opacity (light `v` `#279400`, `S` `#17181A`; dark `S` `#F8F7F4`).
  The same `S` pixel on a breathing splash read 83 / 78 / 27 / 37 across
  stills (full ink 23, the 0.72 exhale ≈ 85).
- Measured 2026-07-30: catalog = 18,492 routes, **3.48 MB raw / 179 KB gzipped**,
  ~0.8–1.5s, and it is one of **six sequential round-trips** (~3s total).
  Overlapping them would genuinely help, but `AppState` is a plain `@Observable`
  with no actor isolation, so `async let` over methods that all mutate `self` is
  a data race, not a speed-up. Doing it safely means making the API calls return
  values instead of mutating — a separate change.

**The logo is `BrandWordmark`: a green `v` + `SMS`.** The old lockup was a
`bolt.fill` in a rounded-rect tile — a generic badge that said nothing about the
product. The `v` takes `theme.ink` (the user-selectable accent) and **not**
`theme.live`, which is the semantic success green; spending that colour on
branding is the conflation `AccentColor` documents as forbidden. On the splash
the mark is fully drawn on the first frame and BREATHES (`BrandWordmark(breathes:)`,
opacity 1 ↔ 0.72, 1.6 s each way, cosine ease-in-out) as the loading
indicator, which is why there is no spinner; it is still in the failure state
and under Reduce Motion. 🔴 **The breath is a function of time in its own
child view (`BreathingMark`, a `TimelineView`), NOT a `repeatForever`
animation.** A running `repeatForever` can only be stopped by a second
animation overriding it on the same property, and timing-curve animations do
not reliably replace one another — the first version relied on exactly that.
Now stopping removes the child: the static branch draws opacity 1, exactly,
and a restart begins at 1 because the child's clock starts when it is created. (It typed on and then spun the `v` until 2026-09-24;
nothing else ever used that, and onboarding / sign-in draw the static mark,
one `Text` per letter, unchanged.) The progress line fades in only after
1.5 s and the slow-connection caption after 3.5 s, both counted from the
cover's first frame, so a healthy launch shows neither.

**Appearance is `AppearanceMode` — System / Light / Dark, defaulting to System.**
It replaced a `pref.isDark` Bool that defaulted to **false**, so the app and the
splash rendered LIGHT on a dark-mode phone until the user found the toggle, and
there was no way to say "follow my device" at all. `colorScheme` is
`ColorScheme?` on purpose: **nil is what actually lets the device decide**, which
a Bool cannot express. Migration keys on *explicitly set vs never touched* —
`defaults.bool(forKey:)` returns false for both, which is exactly how "never
chose" became "wants light" for everyone — so `object(forKey:)` decides, and the
legacy key is deliberately not rewritten so a downgrade to 1.4/1.5 still works.
`ContentView` reads the ambient `colorScheme` **above** its own
`.preferredColorScheme`, because that modifier pushes a scheme *down* to children
and `.system` must resolve against the device's.

## The service picker says where a service IS bookable

`ServiceSheet` fixes the COUNTRY and varies the service — the mirror of
`CountrySheet` — so a service with no route in the selected country used to
render a bare **"Unavailable"** with nothing on the row naming that country.
Measured 2026-07-30: **all visible services (265 then, 254 now) are bookable in at least one
country**, so the word was wrong every single time it appeared. It read as "not
at all" for a median of **79 services per country** (Turkey: 165 of 265 — 62% of
the catalog looked dead), and the services hidden on a Turkey selection are
available in **68 of the 69 countries**.

Worse, the row was dimmed to look disabled but stayed tappable and the tap
WORKED — the handler already relocated via `bestCountry`. The label was steering
users away from taps that would have succeeded.

**`AppState.pickDestination(for:)` is the single shared definition** used by both
the picker row and the tap handler, so the row cannot promise a country the tap
does not deliver. A row promising Romania while the tap lands in Colombia would
be a worse lie than the one it replaced. "Unavailable" now survives only for
bookable-nowhere — the one case where it is true — and that case is `disabled`,
because the tap would otherwise set the service without moving the country and
strand the user on a Temp screen whose only button is a disabled "Unavailable".
The badge is scored against the DESTINATION route, and the Affordable filter
judges by the price the row shows (it used to test `cost(for:country:)` alone and
silently drop every service without a route here).

## Palette + Liquid Glass (2026-07-30)

**The brand accent is GREEN `#279400`** (owner decision, 2026-07-30). It was
briefly switched to blue `#0057FF` and switched back; the blue remains available
as the retuned `.blue` accent option.

**Known and accepted: white on `#279400` measures 3.95:1**, below WCAG AA's
4.5:1 for normal text, so primary buttons do not pass AA. On the background the
accent measures 3.68:1. This is a deliberate brand choice, not an oversight —
do not "fix" it by silently changing the hex. If it is ever revisited,
`#1F7A00` is the same green a few steps darker and measures **5.47:1** against
white while still reading as the brand.

Light `bg` is warm paper **`#F6F5F2`** (was iOS's cool `#F2F2F7`; this line
said `#F8F7F4`, which is the DARK theme's text colour) with `elev` left pure
white, so cards read as genuinely raised. Dark `bg` is **`#0A0A0C`**. Read
both from `Theme.light` / `Theme.dark`, not from here. The warm background is
kept independently of the accent.

Three things that must move together, each a real trap:
- **The `AccentColor` default is declared in FOUR places** — `Theme.light(_:)`,
  `Theme.dark(_:)`, `AuthGate`'s `@AppStorage` *and* its own
  `?? .green` fallback, plus `AppState`'s init fallback. Missing one is not
  hypothetical: the blue experiment changed three and left `AuthGate:28` on
  green, so an unreadable preference would have resolved to a different colour
  depending on which screen asked. Grep for all of them together.
- **`Assets.xcassets/LaunchBackground.colorset` must match `theme.bg`** (light
  `#F6F5F2`, dark `#0A0A0C`). It is the static launch screen, so a mismatch is
  a visible colour step on every cold launch before SwiftUI has drawn
  anything. 🔴 **And it must actually be WIRED.** Until 2026-09-24 it was
  neither: the colorset read `#F8F7F4` / `#000000`, and it was never used at
  all: `INFOPLIST_KEY_UILaunchScreen_BackgroundColor = LaunchBackground` sat
  in the build settings, but the built plist's `UILaunchScreen` was an EMPTY
  dict (read with `plutil`; the likeliest cause is the same generator/merge
  trap as `UIBackgroundModes`, not proven), so the launch screen drew the
  system's white / black. That dead setting was DELETED from
  `project.pbxproj` on 2026-09-25 because it made the colour look wired;
  do not re-add it. `UILaunchScreen.UIColorName = LaunchBackground` now
  lives in `VirtualSIM-Info.plist`; assert with
  `plutil -p "$APP/Info.plist" | grep -A2 UILaunchScreen`. Recorded after the
  fix with the simulator AND the app in light: launch screen → splash → store
  with no step (the dark-on-dark case is the same mechanism, not recorded). An explicit in-app Light/Dark that differs from the
  device still steps, because the launch screen can only follow the device.
- **`live`/`warn`/`fail` are untouched and must stay that way.** Green still
  means "your code arrived" / "your credits came back". Now that the accent is
  no longer green, that separation is *stronger* than before — but it also means
  green appearing anywhere is a semantic claim, not decoration.

**Liquid Glass is `.glassPanel(_:interactive:)` in `DesignSystem/Glass.swift`,
and the `#available(iOS 26)` guard lives there and nowhere else.** The
deployment target is **18.0**, so the majority of devices only ever render the
fallback (near-opaque fill over `.ultraThinMaterial` with a hairline border) —
which is precisely why scattering the guard would let one surface drift without
anyone noticing.

Applied ONLY to chrome that floats over content: `ResumeBar` and
the eSIM map's selection card / globe button / warning pill. (The custom
`TabBar` was glass too until 2026-09-24; the native `TabView` draws its own.) Not to inline
cards — Apple's guidance is that glass belongs to the navigation layer, and on
ordinary cards it puts text over unpredictable backgrounds while destroying the
elevation hierarchy `theme.elev` already expresses.

**`.glassEffect` RENDERS but is not HIT-TESTABLE — `GlassPanel` therefore always
appends `.contentShape(shape)`, and that line is load-bearing.** The filled
`.background(Capsule())` it replaced did contribute a touch surface; glass does
not. So every gap the glass appeared to cover — the tab bar's 6pt padding, the
4pt between its buttons — went transparent to touch and the tap fell through to
whatever was behind. On the eSIM tab that is a full-bleed MapKit view which
`.ignoresSafeArea(edges: .bottom)` extends *under* the tab bar, so a slightly
misplaced tab tap silently panned the map instead. Reported as "the click
registers behind it". Never apply `glassEffect` directly; go through
`.glassPanel`.

**`interactive` is only for glass that IS the control** (a single icon button).
On a container that holds its own buttons — tab bar, resume bar — touch-reactive
glass competes with the children for the gesture and reads as lag on first taps.

**Glass over a saturated background is the failure case, and the eSIM tab is
exactly that** (a full-bleed map, the default view). Inactive tab-bar icons are
at their weakest over bright ocean. The map's cluster bubbles also need an
**opaque** ring in `theme.elev`: the original translucent-white ring let a
bubble blend into whatever was under it — invisible as blue-on-ocean, and
nearly as bad as green-on-Europe, since the landmass is green too.

## Localization: `Text("literal")` is localized, a `String` return is NOT

`Text("Preparing")` picks up the catalog automatically because the literal
becomes a `LocalizedStringKey`. A computed property returning a plain `String`
does not — it never enters `Localizable.xcstrings` at all, so it cannot even be
*seen* as missing by an audit of the file. The whole eSIM tab passed a
file-level "0 untranslated" check while still rendering **"14 MB/day"** in
French, and that was only caught by screenshotting a non-English locale.

Anything user-facing returned as `String` needs `String(localized:)`:
`EsimStatus.label`, `EsimPlan.validityLabel`, `perDayLabel`,
`dataRemainingLabel`, and the expiry line in `EsimActivityScreen` all needed it.
**`Metric(label:)` takes a plain `String`** and does `Text(label.uppercased())`,
so every call site must pass `String(localized:)` itself.

Two more rules, both learned here:
- **Never interpolate a pluralised noun into a sentence.** `"Show %lld more %@"`
  with `%@` = "plan"/"plans" cannot be translated — German and the Romance
  languages inflect the adjective to agree. Ship four complete sentences instead.
- **Verify format specifiers mechanically.** A dropped or reordered `%lld`/`%@`
  is a runtime crash and is invisible in review. Compare the multiset of
  specifiers in every translation against its key, and normalise positional
  form (`%1$@`) first — it is equivalent, and a translation may legitimately
  *omit* a later argument (Italian and Japanese do exactly that for the English
  plural-`s` fragment in "You're %lld credit%@ short…").

🔴 **The committed `Localizable.xcstrings` is NOT in Xcode's JSON dialect, and
re-normalising it is part of any extraction.** On disk it is Python-normalized —
`json.dumps(catalog, indent=2, ensure_ascii=False)` plus a trailing newline, keys
in plain `sorted()` order. Xcode writes `"key" : value` (space before the colon)
in its own key order, so **`xcodebuild -exportLocalizations`, or any Xcode build
that extracts, rewrites all ~44,000 lines** — the keys it adds are correct and the
rest is a no-op reformat. Re-emit the file in the committed style before
committing (round-trip `HEAD`'s copy first to confirm the recipe still matches
byte-for-byte). The reason this is a rule and not a preference: the same edit is
either 802 reviewable lines or a 29,539-line diff, and a junk diff that size makes
the next real catalog change unreviewable — nobody will find a changed translation
inside it.

### Arabic is the one right-to-left language (added 2026-09-25)

SwiftUI mirrors every `HStack` under `ar`, which is right for layout and WRONG
for any row of characters that must read left to right. Two were caught from
Arabic screenshots, neither by reading the code: `OtpScreen`'s code boxes
rendered 123456 as **6 5 4 3 2 1** (a user would paste the code backwards), and
`Dialpad` rendered 3 2 1 on top. Both now pin
`.environment(\.layoutDirection, .leftToRight)`. **Any new view that lays out
digits or characters ONE PER VIEW needs the same pin**; a single `Text` of a
number or phone number renders correctly without it. Under `ar_SA` numbers
format with Arabic-Indic digits (٤٢), which is the locale's convention, while
phone numbers and codes stay Western because they are plain strings.
⚠️ Only the screens in the App Store screenshot set were looked at in Arabic
(verify, code, e-mail, number store, inbox, thread, calls, dialer); the rest are
build-verified only. The translations are machine-made and unreviewed by a
native speaker. Fixture data (sample messages, service and country names from
the catalog) stays English in Arabic screenshots, as in every other language.

## The map's camera callback fires EVERY FRAME

`.onMapCameraChange(frequency: .continuous)` fires per frame of a pan or pinch.
`EsimMapView` derives `clusters` from `span`, so assigning `span` on every
callback invalidated the computed property, re-bucketed all 66 pins, and made
SwiftUI tear down and rebuild **every annotation — each containing a
`CodeFlag` — at 60–120 fps**. That is a per-frame rebuild of the whole
annotation set, and it is why the map felt slow and its taps unreliable while
being dragged.

`commit(_:)` now adopts a new span only when it differs by >15%, which is well
below the ~1.6× step needed for the grid cell to regroup anything — so clusters
still merge and split visibly during a pinch, while a pan (which does not change
the span at all) rebuilds nothing. If you add anything else derived from the
live camera, throttle it the same way.

**Derived catalog data must be STORED, not computed.** `AppState` is
`@Observable`, so a computed property is re-evaluated on every body evaluation
of every view that reads it. `esimCountries` walked all **1,081** plans and
rebuilt a dictionary — twice per `TempScreen` redraw (`HomeScreen` at the
time), once per `EsimStoreScreen`
redraw, continuously while the map was being dragged — and returned a
freshly-allocated array each time, so SwiftUI saw new `ForEach` data and rebuilt
every annotation. Same for `esimPlans(forCountry:)`, a filter+sort over 1,081
called ~4× per body on the plans screen. Both are now derived once inside
`loadEsimCatalog` (`esimCountries`, `esimPlansByCountry`), and
`EsimMapView.clusters` is `@State` refreshed on change rather than computed.

**Do not put `.animation(_:value:)` on a container holding the `Map`.** It
applies to every descendant, so an unrelated state change animates MapKit's own
layout. `SegmentedTabs` and the browse toggle already wrap their state changes
in `withAnimation`, which the branch `.transition`s pick up.

## The eSIM store — why it shows FEWER plans than the catalog has

The store used to render every active plan for a country in one price-ascending
list. Measured against the live catalog on 2026-07-30, that list is unusable for
two independent reasons, and neither is fixable with a nicer row design:

- **382 of 1,081 active plans (35.3%) are DOMINATED** — another plan in the same
  country gives *at least as much data, for at least as many days, at the same
  price or less*. Japan sells 490 MB/1 day for **6** credits and 490 MB/**7
  days** for **5** — cheaper *and* longer. Sorting by price ascending puts the
  strictly worse plan first.
- **187 (country, data, days) triples have more than one plan.** Japan lists
  "1 GB · 1 day" **four** times at 9/10/11/12 credits with nothing on the row to
  tell them apart — because there *is* nothing; the extra 3 credits buy nothing.

`EsimPlanRanking.frontier()` keeps only the Pareto frontier over
(data ↑, days ↑, price ↓), collapsing exact three-axis ties to one row. Japan's
7-day view goes 5 rows → 3. Two rules in it are load-bearing:

- **Plans missing data/validity/price are never dropped.** They cannot be
  compared, and hiding a row because a provider column was NULL would let a
  catalog gap decide what the user may see.
- **The filter is never silent.** A "Show N more plans" control states exactly
  how many rows are held back. It is a default, not a decision made for them.

Duration is the FIRST axis, not a filter. It is the only one the traveller
already knows before opening the app. The catalog is clean here — 1/7/15/30/180
days cover 1,078 of 1,081 plans — and the chips are derived from the data, so a
new duration appears without a code change. The default is **the duration
closest to 7 days**: 1-day plans are 496 of 1,081 purely because the provider
lists many, so defaulting to the modal duration would open every country on
single-day plans.

`credits/GB` is shown because it is the one number that makes different sizes
comparable, and it is arithmetic on **our own retail price** — not a provider
quality signal. There is deliberately no speed/coverage/reliability score on
these screens: we do not measure any of that, and the standing rule is to show
nothing rather than a plausible-looking guess.

**The map is `EsimMapView` (MapKit) and it clusters — that is not optional.**
35 of the 66 countries are European, so one pin per country is a solid blob over
Europe at world zoom. Pins are grid-bucketed against the live camera span
(`onMapCameraChange`), so bubbles become flags as you pinch. Two things learned
the hard way:

- **MapKit aspect-FILLS a requested region, it does not fit it.** On a 0.46-aspect
  phone the whole world is simply not reachable in flat mode: `MKMapRect.world`
  matched the view's *height* and cropped longitude to ~140°, and a 120°×150°
  region cropped to ~60° over Africa. The opening camera therefore centres on the
  densest part of the catalog instead of pretending to show everything.
- **A price badge and a cluster count are the same glyph.** Cameroon's "33"
  (credits) was indistinguishable from a green "13" (a 13-country cluster) — same
  size, same badge. The price chip now always carries its unit ("33 cr") and a
  distinct light treatment.

`CountryGeo` is a static ISO2→centroid table, not geocoding (CLGeocoder is a
rate-limited network round-trip per country, which would make the map's contents
depend on connectivity). `CountryGeo.missingCodes(in:)` exists so a catalog
country with no pin is *assertable* — the map renders a "N not on map" note
rather than silently dropping a country it can sell. Currently 66/66 are placed.

## The review prompt — derived, dwelled, and instrumented (2026-09-11)

**Ratings cap App Store search position and search is this app's entire
acquisition channel**, so this path is growth infrastructure, not a nicety.

🔴 **The app had 8 ratings against 215 users who had received a code, and 6 of
the 7 written reviews are people the owner knows.** Cause, found 2026-09-11:
from `1fa0838` (2026-08-19) the prompt was gated on a UserDefaults stamp whose
only writers were the newly-arrived-code diffs inside `loadOrders` /
`loadEmailOrders` — **and no real delivery ever reached those.** Every code is
written into the arrays FIRST by a single-order poll that stamped nothing
(`apply(server:for:wallet:)`, `refreshEmailOrder`, and the "the cancel came
back delivered" branches in `cancelWaiting` / `rerollNumber`), so the diff was
always empty. Cold launch could not rescue it: `ContentView` exists only inside
`AuthGate`'s `.signedIn` arm, constructed after `session.bootstrap()` has
awaited a Keychain read and a token refresh, **so its `.onChange(of: scenePhase)`
never fires at launch** — and both loaders skipped their first population by
design. The one surviving path was a race, and *winning* it landed the sheet a
second after the user returned to read a code they were about to paste.

**How it works now.** `AppState.reviewPromptBlocker()` is a **pure** predicate —
no persistence, no network, no side effects — returning `nil` when the moment
qualifies and a `ReviewBlock` case naming the gate otherwise. Eligibility is
**derived** from state the client already holds: `Order.arrivedAt` (server-
stamped, selected by `OrdersAPI.columns`, populated 88/88 on delivered orders),
`ServerEmailOrder.createdAtDate`, and `Line.lastSuccessAt`.
`ContentView.scheduleReviewPrompt()` is
the single call site, reached from **two** arms — the cold-launch `.task` after
`coldStart`, and the `scenePhase` foreground — and it fires only after
`AppState.reviewDwellSeconds` of uninterrupted calm.

🔴 **ALL THREE PRODUCTS ARE IN, AND THE LINE ARM WAS MISSING UNTIL
2026-09-14.** The predicate guarded on `lastCodeArrival` — temp SMS + temp
e-mail only — so a **line subscriber could never be asked, ever**. That was not
a small gap: the two audiences have never overlapped (of 19 line subscribers,
ONE ever placed a temp order and NONE ever received a code), so the count of
subscribers who had ever been eligible was exactly **zero**, while
subscriptions became the larger and faster-growing half of the revenue and the
only cohort paying monthly. The cohort that COULD be asked was temp SMS, which
fails ~78% of the time per order. `AppState.lastSuccessMoment` is now the
single eligibility input — `max(lastCodeArrival, lastLineSuccess)` — and
`lastCodeSurface` resolves to `sms` · `email` · `line` so the three can be read
apart on every review event.

- **The line's success signal is SERVER-computed, in `my_line.last_success_at`**
  (migration `20260914194532`): the max of an inbound `line_messages.received_at`
  and a `line_calls` leg that answered and ran **≥ 10s in EITHER direction**.
  Do not re-derive it on the client — `lineMessages` load per-thread and
  `lineCalls` only on the Number tab, so a client-side version would be silently
  empty at cold launch, which is the arm that matters. `lines` IS loaded in
  `coldStart` before the reveal, so the column is there on the first frame at
  no boot cost.
- ⚠️ **Outbound calls count, deliberately** (owner, 2026-09-14). Outbound is the
  proven, heavily-used half of the line — 235 calls in September — so an
  inbound-only signal would have excluded most subscribers. The 10s floor drops
  misdials and voicemail blips.
- **A lapsed subscriber is never asked**, with no extra gate: a released line
  keeps its `last_success_at`, but `reviewPromptBlocker`'s other rules and the
  120-day cooldown apply unchanged, and `lines` only holds what the view
  returns.
- 🔴 **`ScreenshotMode.sampleLine.lastSuccessAt` is `nil` and must stay nil.** A
  sample line that "worked 11 days ago" clears the calm floor, and the review
  sheet would fire **into a store screenshot**.

Five properties that reading the code does not give you:

- 🔴 **The old gate was a 30-minute CEILING; it is now an hours-scale FLOOR
  (`reviewCalmFloorHours`), and that inversion is the point.** Making the stamp
  reachable while leaving the ceiling in place would have been WORSE than the
  bug: the sheet would fire on the user's next foreground, i.e. on their return
  from pasting the code — the rushed moment, delivered at full volume instead
  of to nobody. **Never reintroduce a delivery stamp.**
- 🔴 **The dwell is the design, not a politeness delay.** At the instant of a
  launch nothing is in flight *yet*, and the likeliest reason to reopen this app
  is to buy another number in a hurry — such a user is inside a flow a second
  later. The post-sleep re-evaluation IS the cancellation, and it beats an
  explicit hook because it reports *why* through `review_prompt_blocked`.
- 🔴 **Ask first, consume second.** `markReviewPromptRequested()` runs only
  after `requestReview()` has been attempted. The gate used to be spent inside
  the eligibility check, one second and one uncancelled `Task` hop before the
  call — against a 120-day cooldown that ordering turns a silent no-op into a
  120-day lockout.
- 🔴 **Nothing may claim the sheet was DISPLAYED.** `requestReview()` has no
  callback and iOS silently drops it (quota spent, the user's "In-App Ratings &
  Reviews" switch off, scene not active). Hence `review_prompt_requested`, never
  `_shown`, and `scene_active` on it — the one silent-drop cause observable
  from here.
- **All four paywalls set `suppressReviewThisSession`.** `TempScreen`,
  `EmailDomainSheet` and `EmailCodeScreen` present the mail paywall from their
  OWN `@State` (the root sheet is unreachable under a cover), which bypassed
  `AppState.showMailPaywall`'s didSet entirely — so the mail paywall's primary
  entry point never suppressed. `CreditsSheet` never did either, and it is the
  bigger of the two. ⚠️ Do **not** "fix" the flag's one-per-process lifetime;
  `AppState` documents it as deliberate.

🔴 **A SUCCESSFUL credit purchase LIFTS the suppression again (2026-09-16), and
without that exception the prompt could barely fire at all.** The rule assumes
"saw a paywall" means "was refused something". That stopped being true when the
signup grant went to **0** on 2026-09-10: every user now opens `CreditsSheet`
before they can receive their first code, so a launch-wide suppression set there
covered essentially every SUCCESSFUL session. Measured over the 30 days to
2026-09-16 — `paywall_session` **73 of 114 blocks**, `review_prompt_requested`
**1, ever**, 8 lifetime ratings unchanged since the 09-11 baseline.

Three properties of the exception, none derivable from reading it:

- **A CANCELLED purchase still suppresses.** That user really was told they have
  to pay and said no; "bought credits → ordered → code arrived" is the opposite,
  and the happiest moment the product has.
- **Only the surface that SET the flag may lift it.** `CreditsSheet` captures
  `suppressionWasOurs = !state.suppressReviewThisSession` before setting it, so
  a mail-subscription paywall earlier in the same launch keeps its suppression.
  The three mail sites above still suppress unconditionally.
- 🔴 **`cooldown` must stay ahead of `paywallSession` in `reviewPromptBlocker`.**
  The flag can now clear mid-launch, so the persisted `lastReviewPromptAt` — the
  cooldown's input — is the ONLY thing preventing a second ask in one launch.
  Reordering those two checks reintroduces that silently.

⚠️ **Unread.** This ships in the next release; judge it on
`review_prompt_requested` per week and on the `app-ratings.py` SLOPE, never on a
single total. It cannot raise the rating count on its own — it only stops the
gate from swallowing the ask.

⚠️ **`reviewDwellSeconds` (8) and `reviewCooldownDays` (120) are JUDGEMENT
CALLS, not measurements**, and are labelled as such at the declaration. Nothing
in the data picks them. Read `review_prompt_blocked{stage: dwell, reason:
flow_active}` against `review_prompt_requested` before moving either.

🔴 **`reviewCalmFloorHours` IS 0 — the floor is OFF (owner decision
2026-09-16), and the 8-second dwell is now the only timing gate.** It was 2,
and its own doc comment asked for `too_soon` against `requested` before moving
it; that read-out arrived and said the floor was the expensive gate — **22
blocks across 4 of the 6 users ever evaluated, against 1 request, ever.**

**A floor in HOURS required a return visit, and the product is disposable by
design**: 20 of the 185 users who received a code in the 30 days to 2026-09-16
came back at all. Shrinking the number would not have fixed the shape.

This is not a return to the "rushed moment" the 2026-09-11 rewrite inverted away
from, and the reason is the arms: `scheduleReviewPrompt` is reached ONLY from
cold launch and background→foreground, so it cannot fire while someone watches a
code land. At 0 the ask lands on the user's NEXT return to the app — for a code
that worked, the moment they come back from pasting it. A user whose code FAILED
returns to order another number, is inside a flow within a second or two, and
the post-dwell re-check blocks on `.flowActive`. **The dwell separates those two;
the floor never did.**

⚠️ **Residual risk, accepted knowingly:** a code ARRIVING is not the verification
SUCCEEDING, so someone will be asked shortly before learning the service refused
the number. The reversal is a floor of 10 or 30 MINUTES, never 2 hours again —
and the trigger for it is `app-ratings.py` showing the AVERAGE fall, not the
count fail to rise.

⚠️ **Apple gives NO attribution for a rating.** ASC's `customerReviews` returns
only *written* reviews, so a silent star is invisible there. The only read-out
is the `userRatingCount` time series from `scripts/app-ratings.py`, and it is
only a read-out if the series starts BEFORE a change ships.

## Checkout steers BEFORE the charge, and it is an offer (2026-09-11)

`CheckoutScreen.betterOddsCard` offers a better-rated country while the user can
still act on it for free. It resolves through `AppState.bestPoolRatedCountry` —
the same helper `RecoveryScreen` uses AFTER a failure — so there is one
definition of "a pool worth steering to".

Five properties that reading the view does not give you:

- 🔴 **It may never swap the selection.** Routes the user names themselves
  delivered 35.1% against 2.5% for routes the app named (45 days to
  2026-09-09), which is why `applyStartupSelection` computes no starter pair at
  all. The receipt above the card keeps reading the user's own country until
  they tap it, and the copy says staying put is fine. **If this ever
  pre-selects, it has become the `from_default` bug wearing a better name.**
- **It is silent when the CHOSEN route publishes no rate.** There is then
  nothing to compare against, and "no information" must not render as "bad" —
  the same asymmetry `rankedUntestedKey` encodes by sorting a published 0%
  below unrated. `poolRate` here is `displayedPoolRate`, which is already nil
  while the owner has the metric off, so both that flag and the `showMetrics`
  pref are covered.
- **`AppState.checkoutSteerMinGain` (15 points) is a judgement call, not a
  measurement**, and says so at its declaration. `bestPoolRatedCountry` already
  requires the HIGH band (> 60); this only stops a 59-against-61 crossing
  drawing a card. Read `checkout_steer_shown` against `checkout_steer_taken`
  before moving it.
- **Tapping it goes through `AppState.commitCountryPick`**, which is now the ONE
  country-commit path — the body used to live in `CountrySheet`'s `onPick`
  closure. Two copies would be two places for the `checkoutPremium` reset and
  the `needsCountryChoice` clear to drift, which is the `PurchaseIntent` bug
  class this repo has hit three times.
- **The rate renders as a colour-banded WORD via `NetworkRateMeter`, never the
  percentage**, with the standing "not our own record" sentence beside it. It is
  a third party's network-wide aggregate over traffic that is not ours.

Why it exists: of 411 numbered SMS orders in the 30 days to 2026-09-11, 211
expired with no code and 111 were cancelled against 89 delivered, and the only
route steer in the product fired after that had already happened.
⚠️ Build-verified only — never walked on a device.

## Order-state honesty (client) — the reconcile invariant

**`check-order` is NOT the authority on whether an order ended.** It polls the
live SMS provider and returns HTTP 502 `provider_unreachable` whenever that
throws, so the one moment you most need an answer (provider is sick) is exactly
when it can't give one. `pollActiveOrder` used to `catch { /* transient */ }`
and keep waiting — so with a flaky provider the 60s cron would expire AND refund
an order while the screen sat on a frozen "Waiting / 00:00" indefinitely. The
user has been made whole and has no idea; this is the state that generates
refund requests and 1-star reviews.

The invariant now, in `AppState` (2026-07-25):
- **`OrdersAPI.fetch(orderId:)`** reads the order row straight from PostgREST.
  No provider in the path — the cron has already written `expired`/`canceled`
  plus the refund. This is the authority. Anything asking "did it end?" uses it.
- **`pollActiveOrder`** falls back to that read after 2 consecutive check
  failures, or immediately once past `expiresAt` + grace.
- ~~**`checkNow`** (the "Check now" button)~~ — **both are GONE as of
  2026-08-18.** The button was removed from `WaitingScreen` deliberately (it
  "did nothing the 4-second poll wasn't already doing" and competed with Copy
  for visual weight), which left `AppState.checkNow` with no caller, and it has
  now been deleted too. The invariant it carried still matters if an explicit
  "check" control ever comes back: a user-initiated check must fall through to
  the authoritative row read rather than dead-ending on a swallowed 502.
- **`WaitingScreen`** independently reconciles every 3s once past expiry, and
  renders "Closing…" instead of a stopped `00:00`. Never show a dead countdown
  as a live one.
- **One `apply()`** handles every terminal status. `canceled` used to fall into
  `default: break` and strand the UI even on a *successful* poll — never write a
  status switch here without covering all cases.
- `reconcileActiveOrder` swallows its own failure **on purpose**: if we truly
  can't reach the DB we assert nothing, because inventing a terminal state is
  its own lie.
- **Reroll and cancel hold `isPlacingOrder`** while they mutate the row.
  Without it the background reconcile reads the intermediate `canceled` and
  bounces the user to recovery mid-reroll.

Refunds must be **visible twice**: at the moment (`RecoveryContext.refundedCredits`
→ "+N credits refunded" on the recovery card) and **durably** (`Order.isRefunded`
→ "+N cr refunded" on the history row). "Expired" with no money line reads as
"I paid and got nothing" even though the refund landed. Both terminal paths
refund unconditionally server-side, so status alone is a sound signal.

**The ✕ on the waiting screen LEAVES — it no longer cancels (changed
2026-07-30).** This file previously said the opposite, and the opposite was the
bug. The glyph reads as "back", and the user *has* to leave to paste the number
into another app, so coming back is the NORMAL path rather than an edge case.
Making it destructive — first instantly, later behind a confirmation dialog —
meant the ordinary action of stepping away was the same button that threw away a
paid, in-flight order.

Now: ✕ sets `flow = nil`, the order keeps running, and **`Components/ResumeBar.swift`**
sits above the tab bar on every tab whenever something is waiting. That bar is
what makes non-destructive close honest: without a way back, a live order simply
vanishes from view and the user reasonably assumes it died. It reads the waiting
order from the LIST, not from `activeOrder` — that is cleared when the flow
closes, which is exactly the moment the bar must appear.

Cancelling is still available and still refunds, as an explicit labelled
**"Cancel & refund N cr"** lower down the screen, still gated by the minimum hold (now 90s).
A named destructive action does not need a confirmation dialog the way a ✕ did.

## Quote p90, never p50, next to a running clock

The waiting screen printed *"Codes usually arrive in about 59s"* — the **median**,
i.e. wrong for half of all codes by definition — beside a live timer and (at the
time) a ✕ that destroyed a paid order. Live band is p50 59s / **p90 161s**.
The ✕ is no longer destructive — see the waiting-screen note below — but the
quoting rule stands on its own.

Measured 2026-07-28, every user's first order that got a number: **28 of 37 were
cancelled and NOT ONE ever produced a code**; the 9 who let the window run
delivered 33%. Median first-timer bail: **104s** — past our stated number, well
short of the real one. `Service.typicalWaitSentence` now quotes p90 rounded
**up** ("Most codes arrive within 3 min"). That used to coincide exactly with the
180s minimum hold; **since the hold dropped to 90s the two no longer agree**, so
the screen now quotes a wait roughly 2× the window in which cancelling is
blocked. That is the honest ordering (quote the real p90, don't trap the user),
but do not "tidy" one number into the other — they answer different questions.
`typicalWaitShort` keeps p50 for browse/compare surfaces, where there is no
clock and no destructive button.

This is the seed-`etaSeconds` bug one layer up (28s promised against 53s actual):
that fix corrected the data source and kept the framing.
