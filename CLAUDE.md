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

**What Home holds, top to bottom.** A greeting by daypart and name; the
headline ("What do you need?" / "Your number"); the need-cards in
`AppTab.productOrder` (the Number card carries a Calls · Texts · App codes
chip row and a price only StoreKit ever supplies); a **static seven-service
logo grid** plus a More tile; **How it works** until the user has any order,
then **Recent**; and an invite card. Three properties that reading the screen
does not give you:

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
- **The invite card renders `AccountScreen.invite`'s sentence verbatim** so
  both surfaces resolve ONE catalog key and the two credit amounts stay
  derived in one place. Never retype it with the numerals in it.

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

Home's own events are `home_view` (`has_line`, `has_orders`) and
`home_card_tapped` (`card` ∈ sms · email · line · line_messages · line_call ·
credits · more_services · recent_sms · recent_email · invite). A grid tap fires
`service_selected` with `source: "home"` instead — the picker sends `sheet` or
`search` — and `display_name_set` carries `source` `home` (the user typed it)
or `apple` (the parked name, flushed at launch).

⚠️ **`home_view` under-reports `has_orders` for an e-mail-only user.** It fires
in `onAppear`; `loadOrders` runs BEFORE the reveal and `loadEmailOrders` after
it, so a user whose only history is e-mail is logged `has_orders: false` and
then watches the section swap How-it-works → Recent a beat later. Read the prop
as "had SMS history at the first frame", not as "had no history". Deliberate —
history does not earn a place on the boot critical path.

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

✅ **`line.monthly` carries a $3.99 FIRST-MONTH intro offer since 2026-09-10**
(owner: "genuinely the best I can do" — treat $3.99 as the floor). It is a
PAY_AS_YOU_GO offer, `ONE_MONTH × 1`, then the regular $5.99, in all **175**
territories — same numeral where the tier exists (136, incl. USD/EUR/GBP/CAD),
Apple's equalization elsewhere (¥600, ₹399, R$24.9). Created and READ BACK by
`scripts/asc-line-monthly-intro-offer.py` (dry-run by default, idempotent).
A paid intro answers the free-trial objection: the $3.39 net covers the $1
number. It applies at Apple's sheet with no client change; the client renders
it on `LineCheckoutScreen` (plan row, price block, CTA, 3.1.2 sentence) from
2.13 via `SubscriptionStore.monthlyIntroPriceDisplay`. **2.12 and older do
not display it; 2.13 does.** Read it on `line_checkout_view`
/ `line_purchase_result` `props.intro` (true = the first-month price was on
screen) against the pre-09-10 sheet→paid of 3 of 30.

🔴 **`Product.SubscriptionInfo.introductoryOffer` is the offer AS CONFIGURED,
not eligibility.** StoreKit returns it to every user; eligibility is the
separate async `isEligibleForIntroOffer`, and Apple grants ONE intro per
subscription GROUP per Apple ID — so every current and lapsed line subscriber
(including the 2026-08 yearly-trial takers) is ineligible and pays $5.99 at
the sheet. `monthlyIntroOffer` is therefore set in `loadProduct()` only after
the eligibility read returns true, and cleared on a successful purchase.
⚠️ **`trialLabel` and `MailSubscriptionStore.yearlyTrialLabel` still read the
offer's mere presence** — inert for the line (no trial exists) but LIVE for
mail: a user who already used the mail trial is shown "3 days free" and then
charged the year. Same fix as `monthlyIntroOffer`; not done, listed under
Known-open.

**The yearly line plan carried a 3-day free trial from 2026-08-15 to at least
08-24, and it is GONE from ASC** (`GET /v1/subscriptions/6798759539/
introductoryOffers` → empty, 2026-09-10). Its record: 9 takers, 1 call between
them, 0 conversions, a $1 number each — decoded from
`latest_signed_transaction.offerDiscountType = FREE_TRIAL` on
`line_subscriptions`. `trialLabel` (yearly ONLY) therefore renders nothing.
`mail.yearly` DOES still carry a 3-day trial in every territory. Do not
re-add a line trial without the owner.

⚠️ **`isFreeTrial` in `_shared/iap.ts` no longer treats `offerType === 1` as
"free"**: since the paid intro, an introductory period can carry a price, so
a legacy payload with no `offerDiscountType` is a trial only at `price 0`.
`linePlanLabel` renders "· intro price" for the $3.99 period so ops never
reads it as a $5.99 renewal. `telegram-notify`'s trial test is `price_milli
= 0` and stays correct on its own.

### What the line can and cannot do

Every ✅ below is proven by a real transaction, not inferred. The ❌ is what the
app must never sell.

| capability | state |
|---|---|
| **outbound calling** | ✅ proven at volume |
| **inbound calling** | ✅ proven 2026-09-08 on a device, app open AND closed |
| **inbound SMS** | ✅ works |
| **outbound SMS, NANP → NANP** | ✅ proven off-net 2026-09-08 |
| **outbound SMS outside NANP** | ❌ **genuinely blocked** — settled by experiment |

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

There are **49** function directories besides `_shared` (re-count with
`ls supabase/functions | grep -v _shared | wc -l`). Two groups:

```bash
# JWT-verified (26)
supabase functions deploy create-order check-order cancel-order register-push iap-verify delete-account \
  create-esim-order check-esim-usage redeem-referral \
  create-email-order check-email-order email-domains support-send \
  search-line-numbers reserve-line-number verify-line-subscription rent-line-credits \
  send-line-message line-thread-action mint-line-token begin-line-call report-line-call \
  record-attribution verify-email-subscription swap-line-number record-events

# Cron-gated / webhooks (22) — MUST ship --no-verify-jwt: their pg_cron relays
# send only x-cron-secret, no Authorization header. `winback` lived in the JWT
# group until 2026-07-21 and silently 401'd on every run — zero nudges ever
# sent, invisible because pg_net purges response history within hours.
supabase functions deploy poll-active-orders sync-prices sync-5sim sync-herosms \
  rescue-unprovisioned-lines \
  sync-esim-plans sync-smspva-operators sync-smspva-conversions winback \
  telegram-notify telegram-webhook daily-credit telegram-setup goodwill-credit \
  broadcast-push telnyx-webhook apple-notifications release-lines sync-telnyx-cdr \
  sync-line-voice probe-telnyx-connection sync-line-countries \
  --no-verify-jwt
```

✅ **Verified exhaustive 2026-09-09**: 26 + 22 = 48 against 49 on disk. The one
omission is **`probe-5sim`**, deliberately outside both lists — it is a
diagnostic, not on a normal cadence, but it DOES carry a `config.toml`
`verify_jwt = false` entry and must be deployed `--no-verify-jwt` by hand when
`_shared/cors.ts` changes. **Re-run the count rather than trusting this line:
a function in neither list is a function nobody redeploys, which is exactly how
a stale bundle survives a fix.**

`supabase/config.toml` carries a `verify_jwt = false` entry for all 22 plus
`probe-5sim` (23 total).

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

### Cron schedule (23 jobs, all active — re-verified 2026-09-09)

```
relay-poll-active-orders  * * * * *     relay-telegram-notify   * * * * *
watchdog                  */10 * * * *  relay-sync-prices       17 * * * *
relay-sync-5sim           7 * * * *     (PRIMARY pricing sync, ~71s/run)
relay-sync-herosms        37 * * * *    (offset from sync-prices on purpose)
relay-sync-esim-plans     0 2 * * *     relay-winback           0 15 * * *  (4 nudge cohorts, below)
expire-esim-orders        */15 * * * *  expire-email-orders     */5 * * * *
purge-job-run-details     7 3 * * *     telegram-events-prune   30 4 * * *
app-events-prune          50 3 * * *
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
- `supabase/functions/_shared/` — **26 files** (`ls supabase/functions/_shared |
  wc -l`; count, do not trust a list). The ones worth knowing:
  `providers.ts` (the unified router — order/poll functions call this, never a
  provider), `pricing.ts` (the ONE definition of SMS retail), `fivesim.ts`,
  `herosms.ts`, `heromail.ts` (the temp-EMAIL line), `smspva.ts`, `smspool.ts`
  (eSIM + balance ONLY), `esimaccess.ts`, `iap.ts` (Apple receipt chain
  verification), `apns.ts`, `telnyx.ts` (the rented-line adapter),
  `lineCatalog.ts` (the fail-closed sellability gate every line seller calls),
  `lineProvision.ts` (the ONE order→poll→messaging→voice→activate sequence —
  it was written out three times, which is how voice provisioning ended up in
  one path and not another), `nanp.ts`, `phone.ts`, `emailStatus.ts`,
  `cors.ts`, `telegram.ts`, `tgCommands.ts`, `tgHandlers.ts`, `tgFormat.ts`,
  `tgAlert.ts`, `opsFormat.ts`, `supabaseAdmin.ts`, `lines.ts`, `lineVoice.ts`
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
4.1.2, WebRTC 139.0.0, Starscream 4.0.8) and **138** Swift sources — re-count
with `find VirtualSIM -name '*.swift' | wc -l`; this said 116 for a month.

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
- **The RUNWAY check is separate and untouched** (`balance ÷ 7-day burn < 5
  days`). Neither subsumes the other: at $0.20/day of burn, $2.00 reads as a
  10-day runway and pages nothing while a single $1.50 route is unfundable.
- An order refused for insufficient float pages separately
  (`create-order`'s `alertLowBalanceBlock`) and carries the **shortfall** — a
  route may need $60 of float while the balance page does not fire until $5.

### `app_config` is RLS-restricted to an explicit key WHITELIST

**EIGHT keys** (verified live 2026-09-09): `maintenance`, `announcement`,
`esim_paused`, `lines_paused`, `line_swap_credits`, `delivery_metrics_hidden`,
`email_sub_daily_cap`, `launch_tab`.

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

5/$2.99 · 8/$3.99 · 12/$5.49 · 30/$12.99 · 60/$24.99 · 150/$59.99, asserted by
`assertLadderImproves()`.

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

⚠️ **Does the rate predict OUR delivery? STILL UNVERIFIED, and this is the test
that justifies the whole feature.** Against HeroSMS orders it correlated
*negatively* (r = −0.51, n = 16). The ranking is monotone against our own
outcomes, which is a positive read on the steering; the LEVEL is ~2× our
realised delivery. `orders.pool_rate_pct` and `pool_pinned` are stamped at
reservation for exactly this. **If the correlation is not positive, the number
must come off the row.** Two mandatory filters: split on 2026-08-05, and
**exclude default-landed orders** or you measure our own steering.

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
app must not advertise that it resells someone else's inventory. But this data
still has to be visibly **not our own measurement**, so the wording carries
"network-wide" plus an explicit "not our own delivery record". Dropping the
attribution entirely to solve the naming problem would turn a third party's
aggregate into an implied claim of our own. ("Carrier" is fine and is not the
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

Temp mailboxes on **outlook.com and hotmail.com, both FREE**. There is no paid
tier on sale.

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

**E-mail exists to acquire users, not to earn.** The subscription, not a
per-address price, is its monetization.

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
gets unlimited free-domain addresses under `email_sub_daily_cap` (25) — a stated
hard stop, not a throttle, because the free pool is scarce and shared and one
looping subscriber could drain it for everyone.

`verify-email-subscription` deliberately **accepts Sandbox**, unlike
`iap-verify`. There is no equivalent exposure: the entitlement grants addresses
on domains that cost nothing and is still bounded by the daily cap. Refusing
Sandbox would mean the App Store reviewer subscribes, gets nothing, and rejects
the build.

⚠️ **A subscriber's "unlimited" addresses still depend on free-domain stock that
runs dry, and there is now NO paid fallback at all.** A subscriber who hits a dry
domain gets the same `domain_unavailable` refusal a non-subscriber gets.

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

`run_watchdog()` (pg_cron `*/10`) checks job freshness and any non-2xx row in
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
- 🔴 **`/revenue` and `/profit` still omit BOTH subscription lines.** They count
  credit packs only, so every subscription dollar is invisible. Open.

### Behavioural analytics

`app_events` is written ONLY by the `record-events` edge function. **RLS is on
with NO client policies — a client that can insert directly can poison every
funnel read; keep it that way.** 90-day retention. Analytics only, never
accounting: money stays in the money tables. The client fires-and-forgets, and
the server never surfaces analytics failures to the app — measuring the product
must never degrade it.

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

### Support is WhatsApp, not in-app

🔴 **The in-app chat is GONE from the client (2.9).** Support is a `wa.me` deep
link to `LegalLinks.supportWhatsAppE164` (`+14375243093` — the owner's own
rented vSMS line). The prefilled message carries the build and the first 8 chars
of the user id.

**Everything server-side stays deployed** — `support_threads`,
`support-send`, the Telegram relay, `/support` — because 2.8 and older still
send through it. Do not tear it down until 2.9 is fully adopted. Why it changed:
the Telegram path was answered late or not at all (a refund request sat 11 days
unanswered).

⚠️ **The bot has no way to CLOSE a support thread** — only `open → assigned` —
so answered threads sit in `/support` reading as live work. A `/close` command
is the missing piece.

## Non-obvious gotchas (real bugs, do not re-introduce)

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

- **iOS**: `MARKETING_VERSION 2.13`, `CURRENT_PROJECT_VERSION 62`.
  **2.13 (build 62) SUBMITTED 2026-09-10 17:39Z by the owner** — submission
  `42c648b1-…`, version `WAITING_FOR_REVIEW`, release notes in all 13
  locales, screenshots added by the owner in the ASC web UI. It carries the
  Home tab, the $3.99 first-month intro display, and the signup grant at 0.
  ⚠️ **Read ASC, never this line** — `python3 scripts/asc-release.py status
  2.13`.
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
- **Backend**: 49 edge function dirs besides `_shared`, 229 migration files, 26
  files in `_shared`, 138 Swift sources (re-counted 2026-09-10), 23 active
  cron jobs.
- **Catalog**: 9,364 active routes (5sim 8,074 / HeroSMS 1,290), 468 services,
  0 active eSIM plans (line parked). `active_sms_provider()` = `5sim`.
  Evidence: 53 routes `measured`, 23 `seeded`.
- **Lines**: 10 unreleased `phone_lines`; 19 line subscriptions all-time (8
  active, 1 grace, 9 expired, 1 revoked); 13 e-mail subscriptions (4 active, 3
  grace, 4 billing_retry, 2 expired).
- **Config**: signup grant **0** (owner decision 2026-09-10 — see the grant
  section above; `app_config.signup_bonus_credits`), free e-mail cap
  **1**/user/day, swap **8**
  credits, `launch_tab` = `line` (order behind Home; Home always first from
  2.13), mail subscription **enforced**, eSIM **paused**, lines **not**
  paused, daily credit **disabled**.
- **Balances** — re-query, these move hourly:
  `select key, value->>'balance_usd' from app_config where key like '%_health';`
  5sim $8.29, HeroSMS $14.85, Telnyx $12.87, eSIM Access $86.69
  (re-read 2026-09-11 08:14Z).

🔴 **ONE WATCHDOG CHECK IS FIRING:**
- **`5sim-float` — $8.29 covers ~3.5 days of reservations** ($2.38/day gross;
  the runway check, not the $5 floor). 5sim is the PRIMARY SMS provider, so an
  empty float fails every temp-SMS order as `provider_unreachable`.
  **Owner action: fund 5sim.**
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

## Known-open

Genuinely open items only. Resolved history is in `docs/decisions-archive.md`.

**Money / owner action**

- 🔴 **Fund 5sim.** $8.29, ~3.5 days of runway, and the only watchdog check
  currently failing. (Telnyx fell to $2.87 on the morning of 2026-09-11 and
  the owner funded it to $12.87. Re-query both, never quote either.)
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
- ⚠️ **`/revenue` and `/profit` understate by every subscription dollar.** They
  read `iap_receipts` only; neither `line_subscriptions` nor
  `email_subscriptions` is included.
- ⚠️ **`orders`, `esim_orders` and `email_orders` still expose per-order
  wholesale** to a self-reading user. Smaller than the cost-book leak that was
  closed (RLS is self-read, so a user leaks only their own), and **the adoption
  gate is NOT met**: `select=*` still arrives on `/email_orders` (84 distinct
  IPs) and `/orders` (34) in a 24h window. Re-run that edge-log query before
  revoking; revoking today breaks those clients.

**Unproven claims**

- ⚠️ **The second-code resend window has never delivered a second code.** The
  pool list is 5sim's claim. Proof is the first `resend_promoted` log line.
- ⚠️ **`pool_rate_pct` has never been shown to predict OUR delivery.** The test
  that justifies the whole feature. Two mandatory filters (split on 2026-08-05,
  exclude default-landed). **If the correlation is not positive, the number must
  come off the row.**
- ⚠️ **The VoIP/`physicalCount` hypothesis is untested, not falsified.**
  `orders.operator_used` is the control arm; it needs volume.
- ⚠️ **The tail 5× pricing experiment has not been read out.**
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
- ⚠️ **`MailSubscriptionStore.yearlyTrialLabel` promises "3 days free" to
  Apple IDs that are NOT eligible** (it reads the offer's presence, not
  `isEligibleForIntroOffer`), so a repeat mail subscriber is shown a trial and
  charged the year. The line's `monthlyIntroOffer` has the correct gate; copy
  it. Unfixed as of 2026-09-10.

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
  read as live work.

**Correctness / hygiene**

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
- ⚠️ **`probe-telnyx-connection` has 17 modes, not the 16 documented** — the
  undocumented one is `messaging_profile` (it reads back the messaging profile,
  including `daily_spend_limit`, currently $20.00/day account-wide).
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

The live name is `vSMS: Second Number & Temp SMS` / subtitle **`USA Phone Line
& Verification`**, in all 13 locales — localized, so de-DE is `USA-Nummer &
SMS-Code`, fr-FR `Ligne USA & SMS temporaire`, it `Linea USA e SMS temporanei`.
The USA token shipped with **2.10 (2026-09-06)** and is the app's ONLY
US-intent metadata: ⚠️ **the 100-char keyword field still carries no `usa` in
any locale** (checked 2026-09-10 on live 2.11 and on 2.13 in review; the `it`
field's `usaegetta` is Italian for *usa e getta*, "disposable", and is one
token).

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
