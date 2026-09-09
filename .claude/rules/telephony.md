---
paths:
  - "supabase/functions/_shared/telnyx.ts"
  - "supabase/functions/_shared/lineProvision.ts"
  - "supabase/functions/_shared/lineCatalog.ts"
  - "supabase/functions/_shared/nanp.ts"
  - "supabase/functions/*line*/**"
  - "supabase/functions/telnyx-webhook/**"
  - "supabase/functions/probe-telnyx-connection/**"
  - "supabase/functions/apple-notifications/**"
  - "VirtualSIM/Calling/**"
---

# The rented line — Telnyx, calling, messaging, swaps, country catalog

Loaded automatically when working on the fourth product line. Split out of the
root CLAUDE.md on 2026-09-09; the text is byte-identical to what was there.

⚠️ What stayed in the root file, deliberately, because it must be in context
even with no line file open: the line NEVER touches the credit wallet, one live
line per user, `line_subscriptions` has no FK to `auth.users`, clients read the
`my_line` view, and the rule that the device must never settle money.

### Calling: WIRED AND REACHABLE as of 2026-08-06 — never placed a real call

**Owner decision, 2026-08-06: add `TelnyxRTC` and wire the dialer.** Done in one
commit, as the previous version of this section demanded: the SDK, the entry
point, and the calling copy on five surfaces all landed together.

**Resolved:** `TelnyxRTC 4.1.2`, and transitively **WebRTC 139.0.0** and
**Starscream 4.0.8**. ⚠️ The SwiftPM *library product* is named
**`telnyx-webrtc-ios`** while the *module* you import is **`TelnyxRTC`** — the
project file needs the former, the Swift file the latter. `Package.resolved` is
committed; keep it that way or builds stop being reproducible.

What is live: **CallKit** (`CallController.swift`), **`TelnyxVoiceClient`**
(the real adapter), **the dialer** (reached from a "Make a call" button in the
Number tab's Calls segment), **call history**, the **allowance gate**
(`begin-line-call`), **session reporting** (`report-line-call`) and **CDR
settlement** (`sync-telnyx-cdr`, on cron).

✅ **SUPERSEDED 2026-09-07: OUTBOUND CALLING IS PROVEN AT VOLUME.** Read
from `line_calls` that morning: **131 completed outbound calls settled from
Telnyx detail records** (`hangup_cause = 'NORMAL_CLEARING'`, `billed_seconds`
up to 249, last one 2026-09-06 18:37Z), against 21 `missed`. A 249-second
CDR-settled call is not "connected but silent"; audio is inferred from the
durations, not from a device report, but the two paragraphs below describe
the state BEFORE 2026-08-19 and are kept as history only. Re-derive:
`select direction, status, hangup_cause, count(*), max(billed_seconds) from
line_calls group by 1,2,3;`. 🔴 **INBOUND is still ZERO rows** — no
`direction='inbound'` call has ever been recorded on any build (see
Known-open). "The numbers receive calls" has no evidence yet; do not sell it.

🟠 **CALLS CONNECT; AUDIO PROBABLY DID NOT — corrected 2026-08-19.** Three
calls to France (`+33`, 6s / 2s / 23s) and one attempt to Poland connected on
2026-08-18, every row carrying a `provider_call_session_id`, i.e. the leg
reached Telnyx. The provisioning fix below is what changed; nothing on the
device did.

⚠️ **"and media flowed" was an INFERENCE from the session id, and it does not
follow.** A session id says the signalling leg reached Telnyx, not that the
audio unit was running — and trap 6 below is a mechanism by which it was not,
on every outbound call, until 2026-08-19. Durations of 6s / 2s / 23s are what
"connected but silent" looks like. Nobody has reported hearing audio; treat
that as untested, not working.

✅ **PROVIDER-EVIDENCE SETTLEMENT WORKS AS OF 2026-08-26 — six calls settled
from real detail records the same day the fix landed.** For the twenty days
before that, NOTHING had ever settled from provider evidence: the heartbeat
read `{records: 0, settled: 0}` while every `line_calls` row closed
`no_cdr` / `no_cdr_full` via the 6h backstop. The query had been wrong
**three** times over (window filter, id field names, duration field names),
which is the whole lesson: **assume another cause before assuming provider
lag, and probe rather than re-read the docs** — the documented window filter
turned out to be dead too. See the ✅ three-defects block below.

**The 11 mis-billed historical rows were corrected on 2026-08-26** through the
production settlement path, not hand-written UPDATEs: `allowance_settled` was
cleared on all 11 and `sync-telnyx-cdr` invoked with its new
**`lookback_hours`** body param (cron-gated, clamped 1–720, default 24 — the
standing recovery tool for re-settling re-opened rows the 24h pending window
cannot see). Six matched real CDRs and re-settled — the 248s call went
`billed_seconds` 120 → **249** / cost **$0.035** / `NORMAL_CLEARING`; four ~1s
calls went 120 → 1–2s; the 18s call 120 → 18 — and the allowance meters moved
by exactly the sum of the deltas (verified: 1200 → 854, 120 → 18). The other
five carry session ids but **Telnyx holds no CDR for them** (dials that never
truly connected); the hourly stale backstop re-closes those at the flat
reservation, which is the documented over-bill-rather-than-under-bill policy
and unchanged. This exercise also proved `mergeCallRecords` +
`settle_call_claim` end to end in production. `cdr-never-matched` cleared the
moment the first row settled, exactly as designed.

**The watchdog now catches this, and it did not before** — the pre-existing
`sync-telnyx-cdr` check only tests the heartbeat's `updated_at`, so a sweep
that runs forever and matches nothing stayed green forever. `cdr-never-matched`
(migration `20260826140000`, in the companion `watchdog_delivery_checks()`)
pages while provider-reached calls exist in the last 30 days and NO call in all
history has ever been settled from a detail record. Its recovery signal is our
own rows, not the heartbeat: the heartbeat is per-run and overwritten every ten
minutes, whereas a CDR-settled call is exactly one that does NOT carry a
`no_cdr%` hangup cause, since those three values are written only by the
backstop.

**`probe-telnyx-connection` gained a second mode for diagnosing it** (it now
has SIXTEEN — five added 2026-09-08 for the outbound-SMS question: `messaging` (10DLC brands/campaigns, the messaging profile, and every number's `messaging_product` / `messaging_campaign_id` / `features.sms`, → `app_config.telnyx_messaging_probe`) is READ-ONLY; `send_test`, `order_test_number`, `attach_messaging` and `release_number` WRITE. 🔴 `send_test` verifies BOTH endpoints against Telnyx's own inventory before sending, so it can never text a handset we do not own — that is a safety property, not a convenience, since the cron secret alone must not reach a stranger's phone. `release_number` refuses a number a live line holds. The rest: `connection_id=`, `cdr`, `coverage`, `numbers` — the owned-number
reconciliation, see the orphan-sweep note above — and, since 2026-09-07,
`push_credentials` (every `mobile_push_credential` + the configured one read
back, public cert PEM included, → `app_config.telnyx_push_credentials_probe`)
and `inbound_cdr` (every detail record in the window, filtered CLIENT-SIDE to
`direction=inbound` / `cld` ∈ our numbers, joined to `line_calls` →
`app_config.telnyx_inbound_probe`; client-side because an unknown filter key
on this endpoint returns 200-with-zero-rows), plus, since 2026-09-08,
`line_voice` (one line's credential + number + number/voice + connection,
secrets redacted, AND `/sip_registration_status` for BOTH addresses of record
— the read that found the inbound cause; → `app_config.telnyx_line_voice_probe`)
plus THREE writing modes — every other mode is read-only and must stay that
way. `set_translated_number` (`line_id` + `value`, `""` reverts; the
DISPROVED experiment, see Known-open), `call_control_ring` (create the
account-wide Call Control application, enable SIP-URI calling, place one
~$0.01 call straight at the client's SIP URI), `route_inbound` (point one
number's inbound at that application and pin its ANI; `value: "restore"`
reverses it), and `ring_number` (`to` + `from`, both E.164 — a REAL PSTN call
between two numbers we own, the only test that exercises the number, the
application, the webhook and the transfer together, and the one that removes
the confound of dialing from the handset that is meant to ring).
⚠️ Three shapes on `/sip_registration_status`, all learned from its own 400s
rather than any fetchable doc: the param is **`username`**, NOT
`filter[sip_username]`; **`credential_type`** accepts only
`uac_external_credential` | `telephony_credential` | `sip_credential_connection`;
and the reply is a **BARE object**, so the shared `get()` helper's `.data`
unwrap stores null on a 200 — that mode keeps the raw text instead.
⚠️ Mode-1 reads in PARALLEL take 429 — one at a time.):
`POST {"probe":"cdr","session_ids":[…],"days":30}` (same cron-secret gate,
still read-only, writes nothing). It sweeps every window-filter shape × every
plausible `record_type`, looks each session id up under five filter keys in
both cases, asks Telnyx to 400 on an invalid record type, and — the part the
heartbeat cannot give — reports **`raw_rows` alongside `normalised`** per cell.
`normaliseCallRecord` returns null for a row carrying none of
`call_session_id`/`session_id`/`call_leg_id`/`leg_id`, and the caller drops
those silently, so `records: 0` cannot today distinguish "Telnyx returned
nothing" from "Telnyx returned rows whose id fields we do not read".

✅ **THE CAUSE IS KNOWN, MEASURED AND FIXED (2026-08-26).** The probe was run
against the live account and answered all five candidates at once. **THREE
independent defects**, each alone sufficient to settle nothing, none of which
threw, all now fixed in `_shared/telnyx.ts` + `sync-telnyx-cdr`:

1. 🔴 **THE WINDOW FILTER WAS DEAD, AND THE LADDER THAT CHOSE IT IS THE REAL
   BUG.** Measured over 30 days of real calls:

   | shape | HTTP | rows |
   |---|---|---|
   | `filter[date_range]=last_30_days` | 200 | **43 webrtc / 50 sip-trunking** |
   | no window at all | 200 | **43 / 50** |
   | `filter[start_time][gte]/[lte]` ← what we sent | 200 | **0, every type** |
   | `filter[created_at][gte]/[lt]` (the spec's own) | 200 | **0, every type** |
   | `filter[date_range][start_time]/[end_time]` | 400 | `No FilterType with name end_time` |

   The ladder accepted a **200 as proof a shape works** and cached the index in
   `app_config.telnyx_cdr_shape`. It locked onto `filter[start_time]` on
   2026-08-06 and asked a dead filter for twenty days. **The ladder and the
   cache are deleted**; the window is the single proven `last_30_days`.
   ⚠️ Note the SPEC-documented `filter[created_at]` is *also* dead here — so
   "read the docs harder" would have produced the same outage a third time.
   **On this API a 200 is not evidence. Only rows are.** Fourth instance of
   this exact silent-no-op-on-200 in this adapter.
2. 🔴 **WE MATCHED ON THE WRONG UUID.** A `webrtc` record carries BOTH
   `session_id` (`5ea3db0a-…`, the SDK's own) and **`telnyx_session_id`**
   (`475d4f74-…`, the one `line_calls` stores). `normaliseCallRecord` read
   `call_session_id ?? session_id`, so it normalised 43 of 43 webrtc rows onto
   an id that can never match, and dropped all 50 `sip-trunking` rows (they
   carry no `session_id` at all). Now reads `telnyx_session_id` /
   `telnyx_leg_id` first, old keys as fallbacks.
3. 🔴 **THE DURATION FIELD NAMES WERE ALL WRONG TOO.** The real fields are
   `call_sec` and `billed_sec`; not one of the four documented names
   (`billed_duration_secs`, `billed_seconds`, `duration_secs`,
   `duration_millis`) exists on a live record — so even a correctly matched
   record would have had `billedSeconds: null` and been skipped as unmatched.

**Two behaviours that follow, both decisions rather than mechanics:**
- 🔴 **ONE CALL WRITES TWO RECORDS AND THEY COST DIFFERENT AMOUNTS.** The
  2026-08-24 call: `webrtc` 249s/$0.010 and `sip-trunking` 249s/$0.025, same
  `telnyx_session_id`. Both are real charges, so wholesale is **$0.035** and
  taking either alone understates it by 29% or 71%. `mergeCallRecords` joins
  them per session, **sums the costs**, and prefers the `sip-trunking` record
  for everything else — it is the only one carrying `hangup_cause` and
  `answered_at`. Without the merge the same call would settle twice.
- **WE SETTLE ON `call_sec` (249s), NOT `billed_sec` (300s).** Telnyx bills in
  60-second increments; we sell 100 minutes of *talking*. Rounding a user's
  meter up to the provider's billing granularity would charge them 51 seconds
  they did not use — their rounding is their cost model, not our product.
  Their figure is kept as `providerBilledSeconds` for margin work.

⚠️ **`page[size]` is capped at 50 in the spec and we sent 250.** Tolerated in
practice (the probe got the same 43 rows either way), now clamped anyway.

⚠️ **THE FIRST RUN AFTER THE FIX WILL SETTLE NOTHING, AND THAT IS NOT A
FAILURE.** The 11 historical calls were already written off by the backstop, so
`allowance_settled = true` hides them from the pending query. Proof of the fix
is `raw_rows > 0` **and** `records > 0` in `telnyx_cdr_heartbeat` plus a
`telnyx_cdr_probe.parsed.sessionId` that exists in `line_calls`; real
settlement needs a new call. Assertions are in
`scripts/verify-cdr-email-watchdog.sql`. The heartbeat now reports **`raw_rows`
alongside `records`**, because "Telnyx returned nothing" and "we discarded
everything Telnyx returned" were indistinguishable for twenty days.

⚠️ **This is the open defect underneath the call-billing rules — treat the
6-hour `settle_stale_calls` backstop as the ONLY settlement path, because it
is.** `20260818140000` argued its full-reservation bill was safe on the premise
that the backstop is rare. It is not rare; it is universal, so that rule
silently became the billing rule for 100% of calls. **When you change anything
about call billing, check that heartbeat first** — the premise you are reasoning
from is probably about a path that never runs.

**Billing for a call with no CDR (`20260820110000`), and the reasoning is not
derivable from the code:**
- **No `provider_call_session_id` AND no `provider_call_leg_id` ⇒ the leg never
  reached Telnyx ⇒ bill NOTHING** (`hangup_cause = 'no_cdr_unreached'`). Before
  this, a never-connected international call was charged its entire credit
  block, and a 17-second domestic call ate 120 s of a 6,000 s allowance.
- **Either id present ⇒ bill the FULL reservation** (`no_cdr_full`). Knowingly
  over-bills a short connected call; the only other number available is the
  device's, and that must never decide money.
- 🔴 **THE GATE IS DELIBERATELY NOT ON `status`, AND MUST NOT BE MOVED THERE.**
  A `p_status in ('missed','busy','failed','canceled')` guard inside
  `settle_call_claim` looks like the obvious fix and even makes that function's
  own comment true — but `status` is written straight from `report-line-call`'s
  request body, so that guard **is** the exploit `20260818140000` closed: set
  one string, talk for an hour, pay nothing. `settle_call_claim` is left
  byte-identical so nobody "restores" it. The gate is an on/off test only, never
  an input to the amount.
- The exploit's real bound is Telnyx's per-line `daily_spend_limit`, not our
  settlement. The full-reservation bill was ~2 credits (~$0.80) against ~$36 of
  wholesale on a 10-minute premium call — a rounding error on the attack, and a
  certain recurring over-charge on every honest missed call.
- Behavioural checks: `scripts/verify-call-settlement.sql` (3 assertions in a
  rolled-back transaction, including that a client-reported `canceled` on a
  reached call still bills the full block).

*Kept because it is how this was diagnosed — the state until 2026-08-17:* seven
attempts across two users, every row `provider_call_session_id = NULL`, so no
call reached Telnyx at all.

The probe cleared the server:

- `mint-line-token` **succeeded** — no new entry in `app_config.telnyx_voice_faults`
- the destination priced correctly (France, `iso=FR`, 0.75 cr/min, 2 credits reserved)
- `allowance_settled = false`, i.e. the settle fix is holding

~~**So the failure is on the DEVICE, after the token is issued.**~~ 🔴 **NO.
THIS WAS WRONG FOR TWELVE DAYS. THE FAILURE WAS ON THE SERVER, AND IT IS FIXED
(2026-08-18).**

`attachOutboundProfile` in `_shared/telnyx.ts` PATCHed
`outbound_voice_profile_id` at the TOP LEVEL of the credential connection. The
docs put it under `outbound: {}`. Telnyx returned **200 and attached nothing**
— its documented silent-no-op on a misplaced field, the THIRD time this
adapter has hit that pattern (after `messaging_profile_id` and
`features.sms.international_inbound`). So every connection was recorded
`provider_voice_attached = true` in OUR database while Telnyx held **no
profile at all**, and — as the comment two lines above the function said —
"Telnyx requires a profile on the connection to place an outbound call." Every
INVITE was refused before a session existed. That IS "music ducks then
returns": CallKit activated audio, the dial was rejected, the session tore
down. It read exactly like an SDK failure from the phone.

**Found by a Sonnet agent re-reading the Telnyx docs, then VERIFIED, not
inferred**: `probe-telnyx-connection` (new, cron-gated, read-only — the API key
never leaves the platform) read connection `3028594732042290885` back and
`outbound.outbound_voice_profile_id` was **`null`** on a line we had marked
attached. After the fix + one `sync-line-voice` run: **`3028594742351890119`**
— the exact profile id our row holds — and `attached_verified: 6`.

Three things changed:
- `attachOutboundProfile` sends the nested shape **and reads the connection
  back**, returning a fault unless the profile is genuinely held. A 200 is not
  evidence on this API; the read-back is.
- `lineVoice.ts` step 2b: a line whose profile id is already persisted is
  verified-and-repaired on every run, not skipped.
- `sync-line-voice` runs that verify on every line with a profile, hourly,
  and reports `attached_verified` / `attach_faults`.

**The lesson is the one this file already states and this bug then broke:
"the first real use IS the probe" — but only if you READ BACK. Our own
`provider_voice_attached = true` was a record of a 200, and a 200 here means
nothing.** Anything that PATCHes Telnyx must read the field back before
recording success. `providers.md`'s standing rule ("read the value back; do
not trust the 200") applied to this function and was not followed.

⚠️ **The four inbound-calling client bugs in Known-open are still real and
still unfixed** — inbound has never been tried, and they are device-side. But
outbound was never a device bug. **The next step is a real outbound call from
a device with the 2.1 build** — the server half is now, for the first time,
actually able to place one.

⚠️ *Historical, kept because it was half-right:* provisioning WAS a separate
bug (five of six lines had no connection at all until 08-17, provisioned
lazily in `mint-line-token`). Fixing that was necessary. It could not have
been sufficient, because the thing it provisioned was then attached to
nothing.

**`isVoiceAvailable` still gates `case .dialer`**, and the "Make a call" button
is *hidden* rather than disabled when no client is attached. Keep that: a
disabled button still advertises the feature. The standing rule that produced
the removed copy is unchanged — **sell what ships** — and it now cuts the other
way, so anything added to the paywall must ship with its capability.

**Four traps, three of which are already handled in code.** They were in the
plan file (`~/.claude/plans/binary-humming-moonbeam.md`) which lives outside the
repo, so they are kept here — losing them costs a device-only debugging session:

1. 🔴 **Every `.voIP` push callback must call `CXProvider.reportNewIncomingCall`
   SYNCHRONOUSLY inside that callback** — before any `await`, any network call,
   before handing to the SDK. iOS terminates the app otherwise and, on repeat
   offences, permanently stops delivering VoIP pushes to it. Report from the
   payload metadata first, then hand to `TxClient`.
2. 🔴 **Never call `AVAudioSession.setActive(true)` yourself.** CallKit
   activates it and hands it over in `provider(_:didActivate:)`. Doing it
   manually is the classic "no audio on the first call" bug.
3. 🔴 **`INFOPLIST_KEY_UIBackgroundModes = "audio voip"` DOES NOT WORK, and
   this file told you to do it.** The setting is accepted, appears in
   `xcodebuild -showBuildSettings`, and is then **silently dropped** — Xcode's
   Info.plist generator honours only an allowlist of `INFOPLIST_KEY_*` names
   and `UIBackgroundModes` is not on it. No warning anywhere. The build
   succeeds and VoIP pushes are simply never delivered, so an incoming call
   never rings and nothing logs a reason. Caught 2026-08-06 only by dumping the
   built plist.

   The fix is **`VirtualSIM-Info.plist` at the REPO ROOT** plus
   `INFOPLIST_FILE`, with `GENERATE_INFOPLIST_FILE` left **YES** so Xcode
   merges its generated keys into it (verified: `CFBundleDisplayName` and the
   version still land). It must NOT live under `VirtualSIM/` — that folder is a
   `PBXFileSystemSynchronizedRootGroup`, so it would also be copied as a
   resource and fail with *"Multiple commands produce …/VirtualSIM.app/
   Info.plist"*.

   `INFOPLIST_KEY_NSMicrophoneUsageDescription` **does** work and is set in
   both Debug and Release. Also shipped: `VirtualSIM/InfoPlist.xcstrings` (the
   mic string is NOT covered by `Localizable.xcstrings`; verified compiling to
   `fr.lproj/InfoPlist.strings`) and `PrivacyInfo.xcprivacy` with
   `NSPrivacyCollectedDataTypePhoneNumber` + `…OtherUserContent`.

   **Assert it after ANY project-file change** — a green build proves nothing:
   ```bash
   plutil -p "$APP/Info.plist" | grep -A3 UIBackgroundModes   # must list audio + voip
   ```
5. 🔴 **THE IN-CALL SCREEN IS A ROOT `.overlay`, AND A ROOT OVERLAY RENDERS
   BELOW EVERY `fullScreenCover`.** The dialer IS a cover, so pressing call
   left the keypad on screen with the live call underneath it — invisible, and
   with no way to end it from inside the app. Reported from a real call to
   France, 2026-08-18. `InCallOverlay` is now duplicated into the cover's
   content (the shape `ErrorBanner` already had), the root copy is scoped to
   `state.flow == nil` so exactly one instance ever renders, the dialer
   dismisses itself once the call is committed, and any open sheet is
   dismissed — sheets are detented, so a call screen hosted in one would draw
   at sheet height. **In this app, "above everything" cannot be a root
   overlay.**

7. 🔴 **LONG-PRESSING 0 TYPED `+0` THROUGH TWO SHIPPED FIXES (1725a73,
   7a65606 — both in 2.7 build 48, and the owner's phone still did it).**
   Both relied on a flag handed between two `.simultaneousGesture`
   recognisers; how SwiftUI sequences them on hardware is not ours to
   assume. Since 2026-09-03 `DialKey` is ONE `DragGesture(minimumDistance:
   0)` plus a `Task` hold timer, all on the main actor, so a press emits
   exactly one key by construction; `Dialpad.onKey` returns Bool so a
   refused non-leading `+` lets the `0` through on release (the second fix
   typed nothing there). The in-call DTMF pad refuses `+` the same way.
   ⚠️ Unverified on a device as of the commit — the simulator harness has no
   touch injection and the dialer sits behind a live line. **Press it on the
   phone before believing it**; the last two passed reading and failed there.

4. ⚠️ **`UUID.uuidString` is UPPERCASE and Telnyx's detail records are
   lowercase.** `sync-telnyx-cdr` matches with an exact-string lookup, so
   `providerSessionId` lowercases both ids. Uppercase would settle nothing and
   look exactly like a provider that never reported the call.

6. 🔴 **FULFILLING `CXStartCallAction` BEFORE DIALLING MAKES AN OUTBOUND CALL
   SILENT BOTH WAYS — fixed 2026-08-19, and a green build proves nothing about
   it.** Creating a call makes the SDK build a `Peer`, and `Peer.init` runs
   `configureAudioSession()`, which sets `useManualAudio = true` and
   **`isAudioEnabled = false`** (TelnyxRTC 4.1.2, `Peer.swift:267-268`). The
   ONLY thing in a healthy call path that sets it back is the app's own
   `enableAudioSession` (`TxClient.swift:253-255`) — the other re-enable
   (`Peer.swift:829`) fires only on an ICE restart / network change.

   Telnyx's sample places the call INSIDE `provider(_:perform: CXStartCallAction)`
   and fulfills afterwards, so the disable always precedes CallKit's activate.
   We fulfill first — the allowance gate must be able to refuse a call before
   CallKit hears about it — so our order was reversed: activate → enable →
   `dial` → **disable**, and nothing ever re-enabled it. The call connected, the
   timer ran, a `provider_call_session_id` was issued, and neither side heard
   anything. That is the shape of the three France calls (6s / 2s / 23s) and of
   `+14377832487`, who cancelled four minutes after five dead calls.

   The fix keeps our ordering and re-asserts the enable once the peer exists:
   `VoiceClient.reassertAudioSession()` (→ `isAudioDeviceEnabled = true`, NOT
   `enableAudioSession`, which would re-apply the category and `setActive` on a
   session CallKit already owns), called from `CallController` after `dial`
   returns AND again on `.ACTIVE` in `mediaConnected()` — the SDK does that
   configuration on its own queue, so a single call site is a race. It is gated
   on `audioSessionActive`, tracked from `didActivate`/`didDeactivate`, because
   claiming the session before CallKit hands it over is the same bug mirrored.

   ⚠️ **Still unverified on a device as of 2026-08-19** — read from the app and
   the resolved SDK source, not from a call anyone heard.

**Two costs, both now paid and both accepted by the owner:**
`swiftc -typecheck` no longer works and `xcodebuild` is the only check (done —
see `Common commands`), and **voice can only be tested on a physical device**;
the simulator cannot receive a PushKit push, so an outbound call appearing to
work there is not evidence.

**Two behaviours worth knowing before debugging a first call:**
- **`provider(_:didActivate:)` no longer marks the call connected.** It hands
  the session to the SDK — without which there is **no audio at all** — while
  the SDK's own `.ACTIVE` state drives `mediaConnected()`. CallKit activates
  audio moments after an outbound call *starts*, so the old wiring began the
  billing clock and the on-screen timer on a phone that was still ringing.
- **`mint-line-token` had NO Swift caller until now**, so `VoiceClient.connect`
  was unreachable by construction — the same shape as the six
  `line_subscriptions` updaters that shipped with no INSERT. `LineAPI
  .mintVoiceToken()` is it. **A deployed endpoint is not a reached endpoint;
  grep for a caller.**

⚠️ **The voice adapters in `_shared/telnyx.ts` are the one block written from
DOCS rather than probed**, and the detail-records block beside them was wrong
TWICE for exactly that reason. `mint-line-token` records every fault to
`app_config.telnyx_voice_faults`, so **the first real call is the probe** —
read that key after it.

✅ **ASSN IS PROVEN, not assumed.** Apple's own test-notification endpoint
(`POST /inApps/v1/notifications/test`) returned **`sendAttemptResult:
SUCCESS`**, and the row landed in `line_notifications` with `processed_at` set
and no error. That is the check the P-384 incident demands — verification that
passes locally and throws `NotSupportedError` in the hosted runtime looks
identical until a real request arrives. ASSN URLs are set for **both**
environments.

⚠️ **The ASC URL and the Server API do not agree instantly.** After
`PATCH /v1/apps/{id}` accepted the URL and read it back correctly,
`notifications/test` still returned **404 `4040007` "No App Store Server
Notification URL found"** for several minutes. That 404 is propagation, not a
broken key — a 401 is the auth failure. Poll rather than concluding anything.

⚠️ **The original migration shipped `line_subscriptions` with SIX updaters and
no INSERT.** The first subscribe had nowhere to write its row, every later
UPDATE would have matched zero rows, and the whole lapse state machine would
have run against a permanently empty table — silently, because an UPDATE
matching nothing is not an error. Fixed by `20260805190000_record_line_
subscription.sql`. Likewise `line_threads.blocked` shipped with no writer at
all (`20260805200000_line_thread_actions.sql`). **When a migration adds a
column or a table, grep for something that WRITES it.**

⚠️ **`settle_outbound_message_claim` keys on the MESSAGE UUID, not the provider
id** — `where id = p_message for update` is what makes it a claim. A delivery
receipt carries only Telnyx's id, so `telnyx-webhook` resolves the row first.
Passing the provider id there matches nothing and fails silently.

⚠️ **The voice adapters in `_shared/telnyx.ts` are written from the DOCS, not
probed** — the only block in that file that is. Every other function was probed
live first, which is why the traps in it are documented rather than guessed.
`mint-line-token` records each fault to `app_config.telnyx_voice_faults` so the
first real call doubles as the probe. Re-verify before trusting the shapes.

⚠️ **The Telnyx API key passed through a chat transcript on 2026-08-05 and
should be rotated** — same category as the HeroSMS key noted below. It lives
only as the `TELNYX_API_KEY` Supabase secret and is in no commit.

**What it is:** a phone number the user KEEPS — rented monthly, with two-way
SMS and two-way voice in-app. Owner decisions, all settled, do not re-litigate:
**rent-only** (no "buy outright" — a CPaaS rents from carriers forever, so a
one-time sale is an unbounded liability), **SMS + voice in one release**,
**auto-renewable StoreKit subscription** (the app's first), **Telnyx**,
**launch US/CA toll-free while pursuing 10DLC**, and a **hard-stop allowance**
with a visible meter rather than credit overage.

**Four properties that differ from the other three lines. Every one is load-bearing.**

**1. It NEVER touches the credit wallet.** Hard-stop billing means no
per-message charge and no refund path — so no `wallet_*` calls, no ledger FK,
and no new `wallet_reason`. That deletes the surface this repo has got wrong
more than any other ("a claim and its refund must be ONE transaction", which
seven paths violated). Money here is 100% Apple's. **Keep it that way.** If
overage credits are ever added they need a ledger FK plus a partial unique
index on `reason='refund'`, exactly like email and eSIM.

**2. ONE live line per user**, enforced by `phone_lines_one_live_per_user`, a
partial unique index — not by convention. Apple allows one active subscription
per group with no quantity on iOS, so **the subscription IS the line**. More
lines later means **TIERS inside the same group**, never a second group.

**3. `line_subscriptions` has NO foreign key to `auth.users`.** Same class as
the three credit-grant tombstones, but worse: without it, delete-account →
re-signin re-provisions a **second** Telnyx number while the first bills us
forever with no row pointing at it. Recurring, and invisible until the invoice.
`begin_line_rental` returns `subscription_bound` on that replay.

**4. Clients read the `my_line` VIEW, never `phone_lines`.** RLS is row-level
and cannot restrict columns, and the table holds `monthly_cost_cents` plus
every Telnyx id. SELECT is revoked outright from `anon` and `authenticated`.
This is the fix `routes` and `esim_plans` still need — consider back-porting.
⚠️ The view is deliberately **not** `security_invoker`: an invoker-rights view
would need the caller to hold SELECT on the base table, which is exactly what
was revoked. Its `where user_id = (select auth.uid())` IS the security
boundary. Do not "fix" it.

**🔴 `ON CONFLICT` CANNOT USE A PARTIAL UNIQUE INDEX unless the clause repeats
the index predicate.** Both idempotency guards — `line_messages_provider_key`
and `line_calls_session_key` — raised `42P10 no unique or exclusion constraint
matching the ON CONFLICT specification` until `where provider_message_id is not
null` was added to the statement. The indexes existed; they were simply not
reachable from the code depending on them, and every inbound webhook would have
500'd (which Telnyx retries). **A structural check cannot catch this** — the
index is present and correct. Only a behavioural test found it. The email line
uses the same partial-index pattern and never hit this because it never uses
`ON CONFLICT` against it.

**Every Swift enum mirroring these PG enums needs an `unknown` fallback in
`init(from:)`, in the first client commit.** iOS `OrderStatus` is a plain
String enum with no unknown case, which is why `begin_order` had to write a
semantically wrong `'waiting'`. Six lines each, and it permanently removes the
client-first-schema-second ordering constraint for this line.

**The subscription EXISTS in App Store Connect (created 2026-08-05 via the ASC
API, headlessly):**

| | |
|---|---|
| group | **`22289428`** "Second Number" (+ en-US localization) |
| product | **`6798378879`** `com.anthersystems.VirtualSIM.line.monthly` |
| period | `ONE_MONTH`, not family-shareable |
| price | **$5.99 USD from 2026-09-02** (was $9.99 → proceeds $8.49 until then; base territory **USA**). Yearly `6798759539` **$59.99** from the same date (was $99.99). See the 🔴 reprice block below this table. |
| availability | 175 territories, `availableInNewTerritories: true` (re-measured 2026-08-19; this said 32 for two weeks) |
| grace period | **DISABLED 2026-08-28 (owner decision)** — was 16 days, ALL_RENEWALS. App-level in ASC, so this covers the mail products too. A failed renewal now lapses instead of keeping the entitlement (and our Telnyx rent) alive free for 16 days; at the time of the change 5 line + 3 mail subs sat in grace with auto-renew on, all billing-declined. Cost: the `GRACE_PERIOD` branch of the lapse machine can no longer be exercised in Sandbox — it stays in code for the subs already in grace. |
| state | `MISSING_METADATA` |

🔴 **REPRICED 2026-09-01 (owner decision) — $5.99/mo and $59.99/yr, in all
175 territories, EFFECTIVE 2026-09-02, and the line was REFOCUSED on
receiving verification codes the same day.** `scripts/asc-reprice-line-
subscriptions.py` (dry-run by default, `--apply` to write, reads every price
back). Three facts it encodes:
- **An APPROVED subscription cannot take a price without a `startDate`** —
  every POST is 409 *"Initial price cannot be created again after
  subscription is approved"* — and `startDate = today` is 409 *"Invalid
  startDate"*. The earliest Apple accepts is **tomorrow**. A reprice is
  therefore always a scheduled change landing at 00:00 the next day; the
  first attempt without a date wrote 1 of 175 and read back the OLD price
  everywhere. `preserveCurrentPrice = false` — it is a decrease, so existing
  subscribers pay the new price at their next renewal.
- **Same-numeral rule, as for the mail products:** 136 of 175 territories
  take the identical numeral (USD, EUR, GBP, CAD…), 39 equalize (JPY ¥1000 /
  ¥10000, AUD 9.99).
- 🔴 **`line.yearly` WAS AVAILABLE IN ONE TERRITORY (USA) UNTIL 2026-09-01.**
  Its `subscriptionAvailability` had never been re-POSTed with the full set
  — the exact base-territory trap recorded for the mail products below —
  so no one outside the US could ever buy the yearly. Re-POSTed with the
  monthly's 175 the same day (read back: 1 → 175).
Refocus (2.7, build 48): the Number tab sells "a real US/Canada number that
receives your verification codes" — names ONLY services proven on a rented
line (WhatsApp, TikTok, DoorDash — each has a real code in `line_messages`),
states that some platforms refuse virtual numbers, and sells the switch
(`line_swap_credits`, live) as the remedy with a full-width button directly
under the number. **Every plan / renewal / manage-subscription affordance is
GONE from the Number tab**; Apple's manage-subscriptions sheet is reachable
from **Account → Support** only. Calling stays, demoted to one secondary row.
`LineSwitchNumberButton` is the single entry point; since 2026-09-05 it reads
**"Change number"** with NO price and opens `LineSwapSheet` — see "Swapping a
line's number" for the choose-first-pay-last flow and why.

### International calling — credits, not minutes (2026-08-17)

The $9.99 plan sells **100 DOMESTIC (NANP) minutes**, hard stop. Anything else
is priced from `public.voice_rates` at 5× wholesale and paid in **credits**,
because a minute-denominated bucket cannot tell a $0.005/min call from a
$3.62/min one — which is the whole reason this exists.

**TWO GATES, IN TWO SYSTEMS, AND ENABLING EITHER ALONE IS A BUG:**

| gate | where | enforced by |
|---|---|---|
| **price** | `voice_rates.enabled` | `begin_intl_call_claim` |
| **permission** | `whitelisted_destinations` on the line's Telnyx outbound voice profile | the carrier |

`begin_intl_call_claim` refuses an un-`enabled` row with `destination_unavailable`
**before charging** — *a price is not permission*. Both halves now derive from
one SQL function, `voice_dial_destinations()`, and `sync-line-voice` (hourly,
`:11`) patches every existing profile so a widening reaches lines already sold.
Profiles are **per line** (`vsms-<line id>`), each with its own
`daily_spend_limit`, so one abused line cannot ground another.

🔴 **THE NANP ROW IS NOT "US".** `voice_rates` carries ONE row for +1 labelled
"United States & Canada" with `iso2 = 'US'`. Deriving Telnyx destinations from
`iso2` alone yields a list with **no CA in it** — and every number sold is
Canadian, whose owners call Canada. `voice_dial_destinations()` expands it to
US/CA/PR/VI (matching `_shared/phone.ts`), giving **53** destinations from 50
rows. Verify with `select public.voice_dial_destinations();` before touching it.

🔴 **LONGEST-PREFIX MATCHING MEANS A COUNTRY ROW ANSWERS FOR ITS PREMIUM
RANGES.** Until 2026-08-17 the override mechanism the table documented had been
used **zero** times, so `+1900`/`+1976` (US premium, $1–5/min) resolved to the
+1 row as **`covered_by_allowance = true`** — billed against the free minute
allowance, with the dialer saying *"Included in your minutes"* — and `+4470`
(UK personal numbering, a classic IRSF target) billed at the UK landline rate.
The Caribbean NANP countries did the same. There are now **49 `enabled = false`
rows** covering those ranges; a disabled row is a REFUSAL, not a missing price.

⚠️ **A prefix table looks right in review and is wrong against real numbering
plans.** The first attempt used `3519` for "Portugal premium" — Portuguese
MOBILES are 91/92/93/96, so it would have refused most of Portugal. Premium is
760/761/762, shared-cost 707/808. **Query `voice_rate_for()` on real numbers
after any change**, both a number that must be refused and one that must not.

⚠️ Rates are **provisional**, written from public price lists — Telnyx has no
pricing API. Nine destinations (CH, JP, NZ, SI, HR, FI, SK, AT, LV/EE) sit close
enough to plausible mobile termination that a single expensive MNO range inside
them could go negative. Replace them from the real rate deck before volume.


### Swapping a line's number — 8 credits (2026-08-21, repriced 2026-08-23, picker 2026-09-05)

`swap-line-number` replaces a rented line's phone number with one the **user
chooses** — country → city → number, the store's own picker — charging
`app_config.line_swap_credits` — **8** as of 2026-08-23 (was 5 at launch;
`line_swap_cooldown_days` is **0**, i.e. no cooldown).

🔴 **CHOOSE FIRST, PAY LAST (owner decision 2026-09-05), and the button never
names the price.** Until 2.8 the button read "Switch number · 8 credits", its
confirm bought the first free number in the OLD area code, and `canSwap`
never read the wallet — so a user with 6 credits was invited to tap an
8-credit button and got 402 `insufficient_credits`. That was the first real
swap complaint ("changing my number doesn't work", user `d580…`, 03:15Z; the
swap then succeeded at 03:17Z after they freed 2 credits). Now:
- `LineSwitchNumberButton` reads **"Change number"** (no figure; still hidden
  when `lineSwapCredits` is nil — a sheet that cannot quote a price cannot ask
  for money) and opens **`LineSwapSheet`**.
- The sheet walks country → city → number using the SAME rows as the store
  (`Components/LinePickerRows.swift` — `LineCountryRow`, `LineCityRow`,
  `LineCountryWideRow`, `LineOfferRow`, skeletons, `LineUnavailableCopy`,
  `AppState.linePlaceLabel`; extracted from `LineStoreScreen` so there is one
  definition of a picker row). It reuses the Number tab's search state via
  `AppState.loadLineNumbers` / `loadLineCountries`; the presenter calls
  `clearLineDraft()` on dismiss so the store never inherits a swap's place.
- The LAST page shows old → new, **price and balance**, the "given up for
  good" warning, and ONE of two CTAs: **Switch** when `balance ≥ cost`, or
  **"Top up · N more credits"** opening `CreditsSheet(needed: shortfall)` when
  not. Nothing is ever offered that `begin_line_swap` would refuse for money.
  Errors render INLINE (`state.showError` drives the root banner, which draws
  under a sheet); `number_taken` bounces back to a fresh list.
- **The server has TWO modes.** `phone_number` present ⇒ CHOSEN: re-quoted
  through the same area-code/locality walk `rent-line-credits` uses, `number_taken`
  if it is gone, all before the charge. Absent ⇒ LEGACY same-area-code
  reroll, kept byte-for-byte because shipped 2.8 sends `{line_id}` alone.
- **A country change is allowed in chosen mode and is gated as a NEW SALE**
  (`sellableCountry()`, fails closed, `country_not_sellable`); a same-country
  pick keeps the retention rule and is NOT gated (`searchProfileFor`). A
  `requirement-info-pending` on a moved country self-heals the catalog
  (`order_rejected`) exactly as the rental path does.
- **`complete_line_swap` is now 8-arg** (`20260905100000`): `p_country`,
  `p_number_type`, `p_locality`, `p_monthly_cost_cents`, all default null so
  the old 4-arg bundle still resolves (DROP + CREATE, never `or replace` —
  an overload makes PostgREST refuse the RPC). With a country it REPLACES
  `locality` (null for country-wide) rather than coalescing — the old city
  under a new flag is what the next swap would search on. The cost written
  is the re-quote we PAY, and only when Telnyx quoted one (`costKnown`).
- Funnel events: `line_swap_open`, `line_swap_numbers_shown`,
  `line_swap_number_picked`, `line_swap_confirm_view{affordable,
  changed_country}`, `line_swap_topup_shown{shortfall}`,
  `line_swap_result{outcome, changed_country}`.
- `LineEnv` now carries `IAPStore` (the settings sheet hosts the same button,
  and `CreditsSheet` reads it from the environment — a crash without it).
Client-side, so it ships with the next build; 2.8 users keep the blind
same-area-code reroll and its 402. Owner rule: **≥ 3× margin on the swap.** Cost basis is Telnyx's
flat **$1.00 upfront** per number (the new number's $1/month replaces the
old one's); at the measured $0.40 net per credit, 8 credits nets $3.20 =
3.2×. The old number's unused remainder of the month is sunk and not in
that basis — if that ever matters, 10 credits is 4× / 2× against the $2
worst case. Available to monthly AND yearly lines alike (`canSwap` keys on
`status == .active`, not on the product). Built as **refund defence, not
revenue**: a yearly subscriber is locked in for a year, so a number that
gets spam-flagged leaves them with $99.99 of dead product and one move —
`reportaproblem.apple.com`, which we cannot decline.

**⚠️ It is NOT a retention fix, and the data says so.** Measured 2026-08-21
across 13 subscriptions: **8 inbound messages lifetime, on 5 of 13 lines**.
Nobody has worn a number out — they are not using them at all. Do not cite
this feature as an answer to churn.

🔴 **THE ROW IS MUTATED IN PLACE, and it has to be.**
`phone_lines_one_apple_line_per_user` is a partial unique index covering
`provisioning|active|grace|past_due|suspended|releasing`, so for an
Apple-billed user there is NO window in which a second row can exist:
insert-then-release is rejected by the index, and release-then-insert leaves
the user with no line at all if the insert fails. Mutating `e164` /
`provider_number_id` also preserves the line id — the Telnyx connection,
outbound profile and credential are all named `vsms-<line id>`, so they
survive the swap untouched.

**`status` never changes during a swap.** Adding a `'swapping'` value to
`line_status` would need the client shipped first, and it would be a lie: the
OLD number keeps receiving right up to the cutover. In-flight state lives in
`line_number_swaps`, where a partial unique index (`state='claimed'`) makes a
double-tap impossible without touching the enum.

**`complete_line_swap` sets `provider_voice_attached = false` deliberately.**
That flag is what `provisionLineVoice` keys its attach step on; leaving it
true would mean the new number never rings and nothing would ever notice —
the exact shape of the twelve-day outbound-voice outage.

**The old number's release is tracked in `line_number_swaps`, not
`phone_lines`.** Because the row is mutated, the old number stops being
referenced by any line the instant the cutover lands, so the swap row is the
only record it is still ours. `release-lines` drains
`swaps_pending_release()`; that drain is deliberately NOT behind
`line_orphan_release_enabled`, because an orphan is a number we cannot prove
is unused while a swap row names exactly which number was replaced.

Verified by `scripts/verify-line-swap.sql` — 11 behavioural groups in a
rolled-back transaction, including double-cutover, double-refund,
cross-user, refuse-without-charge, a legacy cutover leaving country/locality
untouched, and a chosen cutover moving them. ⚠️ **It reads the LIVE price
from `app_config`** — it was pinned to the launch literal 5 and had been
failing on its first assertion since the 08-23 reprice (found 2026-09-05; run
it, don't trust the "verified" here). ✅ **The Telnyx order/release half HAS
now run live: two real swaps on 2026-09-05** (`d580…` +19295430380 →
+19293090076, and the owner's credits line +14375243048 → +14375243093),
both `done` in ~6s with the old number released. *(Historical: it was
written from `reserve-line-number`'s proven shapes and untested until then;
the note below is kept for that reason.)* The call shapes are copied verbatim from
`reserve-line-number`, which is proven. **The first real swap is the probe.**

### Line country catalog — data-driven sellability (2026-08-27)

The rented-line store is no longer a hardcoded 7-Canadian-city list. Which
countries sell is decided by **`line_country_catalog`** (PK country_code ×
number_type), written only by `sync-line-countries` (cron `relay-sync-line-
countries`, 03:40 daily) from live Telnyx reads: `GET /v2/country_coverage`
(per-type capability flags) and `GET /v2/requirements?filter[action]=ordering`
(the document gate). Cities/area codes live in **`line_localities`** (seeded
with the exact 7 CA cities the old CITIES maps carried — the maps are deleted
from all three functions). Clients read the **views** `line_country_menu` /
`line_locality_menu` only; the base tables are the cost book and compliance
record and are service-role-only. Bootstrapped 2026-08-26: 125 rows, 3
sellable (US, CA, PR — all $1.00/mo except PR $3.00), GB/DE/FR/NL/PL/AU
blocked `documents_required` (3–6 docs each).

🔴 **THE STORE WAS DARK IN EVERY COUNTRY FOR ~5 OF THE FIRST 9 DAYS, AND
NOTHING PAGED (found 2026-09-05 when the owner hit it by hand).**
`sellableCountry()` fails closed when `coverage_checked_at` or (no approved
group) `requirements_checked_at` is older than
`line_country_catalog_max_age_hours` = **48**; `sync-line-countries`
re-probed requirements every **7 days**. Two constants in two files, never
reconciled: every sellable country went "We don't sell numbers here yet"
48h after its probe and stayed there until the weekly sweep came round.
Measured from function logs (`line_catalog_stale`): **89 refusals on 08-30,
97 on 09-01, 53 on 09-02**, and 03:40–06:51Z on 09-05. ⚠️ **That is the
whole window in which 2.7's store was measured at "162 views / 0
subscriptions" and redesigned on that evidence** — the redesign may still be
right, but the measurement was of a store answering "not sold here" to
everyone. The watchdog stayed green because `line-country-catalog-stale`
tests the sync HEARTBEAT, and the sync was running fine; it just was not
touching the rows that mattered. Fixed the same day:
- `sync-line-countries` now re-probes every `sellable` row whose
  requirements stamp is older than **half the gate** (`SELLABLE_REPROBE_
  FRACTION = 0.5`, reading `loadLineCatalogConfig().maxAgeHours`), FIRST in
  each run, before the priority list and the weekly rotation. The two
  constants are now tied in one place.
- `watchdog_line_catalog_checks()` gained **`line-country-sellable-stale`**
  (`20260905110000`): a STATE check mirroring `sellableCountry()`'s exact
  predicate over the sellable rows. It fired on the live state before the
  re-probe and cleared after — verified, not assumed. Copy in `tgAlert.ts`.
- Rule for the future: **a freshness gate and the job that keeps it fresh
  must reference the same number.** Check the state, not just the heartbeat.

Rules that are load-bearing:
- **A country sells ⇔ probed AND (zero ordering documents OR an APPROVED
  requirement group)**, computed by `refresh_line_country_sellability()`.
  NULL fails closed everywhere: never-probed ⇒ blocked. There is deliberately
  **NO `force_sell` override** — the only override is `force_block`. Filing a
  requirement group in Telnyx (owner action, manual) and recording its id on
  the row turns a documented country green with no deploy.
- **Every seller calls `_shared/lineCatalog.ts::sellableCountry()` and fails
  CLOSED** (`country_not_sellable` / `catalog_stale` / `catalog_unreadable`).
  Consequence: **an empty or stale catalog takes the WHOLE line store down,
  Canada included** — the watchdog checks `line-country-catalog-stale`,
  `line-country-none-sellable` and `line-country-order-rejected` exist for
  exactly this. Never deploy the sellers against an unpopulated catalog.
- 🔴 **Never re-add a literal `filter[features][]` to `searchNumbers`.**
  Probed 2026-08-26: `features[]=sms&voice` on GB/DE local returns **HTTP 400
  code 10015**, not an empty list — the old hardcoded filter made every
  voice-only country read as a provider outage. `searchNumbers` now defaults
  to NO features filter; callers pass what the catalog row says.
- **`withinWholesaleCeiling`** (config `line_wholesale_ceiling_monthly_cents`
  300 / `_upfront_` 500) is a SAFETY guard, not pricing. The comparison is
  `>`, so a number at exactly the ceiling is allowed — PR samples at exactly
  300¢/mo and must stay orderable. Non-USD quotes are refused, never
  converted; outside NANP `costKnown=false` is a refusal (the fallback cents
  are NANP-calibrated).
- **`verify-line-subscription` re-checks sellability after the JWS and before
  `orderNumber`**, and a Telnyx `requirement-info-pending` rejection
  self-heals the catalog (`sell_reason='order_rejected'`, preserved by the
  refresh until a real blocker replaces it) so the next user never hits the
  same wall. `rent-line-credits` does the same. **Swap is deliberately NOT
  gated on sellability** (only the ceiling) — a regulatory change after the
  sale must not strand a paying subscriber; swap stays same-country always.
- **`toE164` takes the line's country** and refuses a bare national number on
  a non-NANP line instead of guessing +1. The client warns voice-only ONLY on
  `supports_sms === false`, so a sellable country must always carry a real
  supports_sms value.
- The client (2.4) shows ALL probed countries with capability icons, green
  where supported, gray where not; blocked rows render "Not available yet".
  Behavioural checks: `scripts/verify-line-country-catalog.sql` (10 groups,
  rolled back), `scripts/verify-line-catalog-gate.ts` (29 offline assertions),
  `scripts/verify-lines-countries-format.ts` (`/lines countries` rendering —
  the Telegram ops view of the catalog incl. per-country wholesale).
- ⚠️ **The first non-NANP order has never run** — US/CA/PR need no documents
  so today's sellable set exercises only the proven NANP path. When a
  requirement group first makes a documented country sellable, the first
  order IS the probe (owner-controlled credits line, read the order back).

