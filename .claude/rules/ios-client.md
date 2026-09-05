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
  ContentView.swift              4-tab routing (home/esim/orders/account) +
                                 fullScreenCover for Checkout/Waiting/OTP + eSIM
                                 flow (esimCheckout/esimDetail); EnvBundle
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
  Screens/                       Home, Checkout, Waiting (+ WaitingAnimations),
                                 OTP (fires native review prompt on code
                                 delivery), Orders, Account, + eSIM flow
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
                                 2026-09-05 — support is a `wa.me` link to
                                 the owner's WhatsApp Business
                                 (`LegalLinks.supportWhatsApp`), from Home and
                                 Account
  Sheets/                        EmailDomainSheet (4 domains, live stock,
                                 Free/1cr), ServiceSheet (search + categories + per-route
                                 price; a service with no route in the SELECTED
                                 country shows where it IS bookable, never a bare
                                 "Unavailable" — see the picker note below),
                                 CountrySheet (sort + per-route price),
                                 CreditsSheet (StoreKit 2)
  Components/                    Theme primitives + ServiceLogo / FlagImage /
                                 FlagCircle — bundle-first via BundledImageStore,
                                 network cascade (DuckDuckGo/FaviconV2, flagcdn) as
                                 fallback; SuccessBadge renders MEASURED delivery
                                 odds only (grey/amber/red), never seed rates;
                                 BrandWordmark (green `v` + SMS — the logo, and on
                                 the splash also the loading indicator);
                                 CodeFlag (flag from a bare ISO2 — the eSIM
                                 catalog has no `Country`); DataRing/DataBar
                                 (usage gauges, show REMAINING not used)
  Push/, IAP/, Onboarding/       Self-explanatory
  DesignSystem/                  Theme, Typography, Icons + **Motion.swift**
                                 (`RMotion`: one animation vocabulary named by
                                 what moves — select/panel/content/value/camera
                                 + `stagger`. Use these, not inline curves)
                                 + **Glass.swift** (`.glassPanel(shape:)` —
                                 Liquid Glass on iOS 26, frosted material below.
                                 See the note below: the availability guard
                                 lives HERE and nowhere else)
  Localizable.xcstrings          String Catalog: en source + de/es/fr/it/ja/pt-BR
  Products.storekit              Local IAP test config (enable via scheme)
  VirtualSIM.entitlements        Sign in with Apple + aps-environment
```

## Cold launch — the splash, and why readiness is not a timer

`AppState` starts from `SeedData` with `routes = []`, so `cost(for:country:)`
returns nil for **every** pair. Before `SplashScreen` existed the launch was:
blank system launch screen → a bare `ProgressView` → a Home screen whose primary
CTA read **"Unavailable · Pick another country"** for the whole fetch. The seed
default pair is WhatsApp/United States, which is in `blocked_routes` and never
bookable, so it stayed wrong until `applyStartupSelection()` ran at the END of
the chain. A first-run user met a screen saying the product was unavailable —
expensive here specifically, because activation is a single-session event
(median signup → first order is 2 minutes).

- **`AppState.coldStart(api:)`** owns the sequence and publishes `bootPhase` +
  `bootProgress` from steps that actually completed. **Never fill that bar on a
  timer** — a synthetic bar is the same class of claim as a seeded success rate.
- **Readiness is NOT "the chain finished".** The two eSIM fetches are read only
  by the eSIM tab, so they run *after* `bootPhase = .ready`, behind the revealed
  UI, instead of holding a correct Home screen behind them.
- **`loadCatalog` returns `Bool`.** It used to be `-> Void` with a bare
  `catch { /* keep current state */ }`, so an offline launch silently kept the
  30-service seed stub and rendered a full Home screen on which every service
  read "Unavailable" — indistinguishable from "this product is broken". The
  splash now offers **Try again** / **Continue anyway**. It still keeps existing
  data when a *foreground* refresh fails; only the cold path treats it as failure.
- The splash sits **above** the maintenance overlay but is suppressed once
  maintenance is known active — that screen is the honest answer and must not
  wait behind five more fetches.
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
the letters type on and then the `v` rotates as the loading indicator, which is
why there is no spinner. The progress bar appears only after 1.2s and the
slow-connection line after 3.5s, so a healthy launch shows neither.

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
strand the user on a Home screen whose only button is a disabled "Unavailable".
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

Light `bg` is warm paper **`#F8F7F4`** (was iOS's cool `#F2F2F7`) with `elev`
left pure white, so cards read as genuinely raised. Dark mode is unchanged. The
warm background is kept independently of the accent.

Three things that must move together, each a real trap:
- **The `AccentColor` default is declared in FOUR places** — `Theme.light(_:)`,
  `Theme.dark(_:)`, `AuthGate`'s `@AppStorage` *and* its own
  `?? .green` fallback, plus `AppState`'s init fallback. Missing one is not
  hypothetical: the blue experiment changed three and left `AuthGate:28` on
  green, so an unreadable preference would have resolved to a different colour
  depending on which screen asked. Grep for all of them together.
- **`Assets.xcassets/LaunchBackground.colorset` must match `theme.bg`.** It is
  the static launch screen, so a mismatch is a visible colour flash on every
  cold launch before SwiftUI has drawn anything.
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

Applied ONLY to chrome that floats over content: the tab bar, `ResumeBar`, and
the eSIM map's selection card / globe button / warning pill. Not to inline
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
rebuilt a dictionary — twice per `HomeScreen` redraw, once per `EsimStoreScreen`
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
