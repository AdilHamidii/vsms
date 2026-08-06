# Rented numbers — what's left to be 100% operational

Target: a user can rent **multiple numbers at once**, send SMS, receive SMS,
place calls and receive calls.

Status as of 2026-08-06. Everything below was verified against live state
(Supabase, Telnyx secrets, the schema) rather than taken from notes.

---

## 0. The design decision that has to come first

🔴 **"Rent multiple numbers" cannot be built as "buy the subscription again".**

Apple allows **one active subscription per subscription group**, and `quantity`
on `Product.purchase` applies to **consumables only** — never auto-renewables.
So a user cannot hold 2× `com.anthersystems.VirtualSIM.line.monthly`. The
schema already encodes the single-line assumption as a hard constraint:

```
phone_lines_one_live_per_user  UNIQUE (user_id)
  WHERE status IN (provisioning, active, grace, past_due, suspended, releasing)
```

Three ways out. **Pick one before any code is written** — they differ in schema,
in ASC setup, and in what the paywall says.

| option | how it works | cost |
|---|---|---|
| **A. Tiers in one group** (recommended) | Products for 1 / 3 / 5 numbers in the existing "Second Number" group. Apple handles upgrade/downgrade and proration natively. | New ASC products + prices; `line_subscriptions` gains a `slots` column; the unique index becomes a count check against `slots`. |
| **B. One group per slot** | "Number slot 1", "Number slot 2", … each its own group, each independently subscribable. | Ugly in Manage Subscriptions, no proration between slots, and N× the ASC maintenance. Genuinely works, but the user sees N line items. |
| **C. Credits** | Fund rentals from the credit wallet. | ⛔ Contradicts a deliberate design property: the line **never touches the credit wallet**, which is what keeps it clear of the claim/refund bugs that have hit every other line. Would need a ledger FK and a refund path. Not recommended. |

**Recommendation: A.** It is what the schema comment already anticipates
("More lines later means TIERS inside the same group, never a second group"),
it is the only option Apple handles natively, and it keeps one subscription per
user so the lapse state machine stays as-is.

⚠️ Whatever is chosen, note the current subscription is **$9.99 for one number**
against a **~$2/number/month** cost. A 3-number tier is not $29.97 of value to
us — price it deliberately.

---

## 1. Owner actions — nothing ships without these

- [ ] **Fund Telnyx.** Live balance **$2.33**. Each number is **$1 up front +
      $1/month**, and Apple pays ~45 days in arrears, so the float is carried
      ahead of revenue. This is the cause of the "We can't set up new numbers
      right now" refusal — the guard is working, there is simply no money.
      ✅ Now monitored: `app_config.telnyx_health`, minutely, pages when low.

- [ ] **Create the VoIP push credential** in the Telnyx dashboard, uploading the
      APNs key for `com.anthersystems.VirtualSIM.voip`, then:
      ```
      supabase secrets set TELNYX_IOS_PUSH_CREDENTIAL_ID=<id>
      ```
      🔴 **Blocks ALL inbound calls.** Without it every credential connection is
      created with no push capability, so no incoming call can wake the device.
      `mint-line-token` now reports `inbound_ready: false` and logs
      `telnyx_push_credential_missing` instead of claiming it works.

- [ ] **Check the subscription's state in App Store Connect.** It was
      `MISSING_METADATA`, and a product in that state is **not returned by
      StoreKit even in Sandbox** — from the phone that looks like a bug in our
      own app. Read the state in the web UI, which flags the missing field in
      red; the API exposes no reasons array.

- [ ] **Decide the territory story.** US numbers need **10DLC** (brand +
      campaign, weeks, can be rejected) before they can send. **Canada needs
      none** — measured: a Canadian number sent to a US number with no brand and
      no campaign registered and it delivered. Launching Canadian is the
      zero-paperwork path.

- [ ] ⚠️ **Decide how to disclose the SMS limitation.** US/CA numbers are
      **domestic-only for SMS**: `international_inbound: false`, and the setting
      cannot be turned on by API (the PATCH returns 200 and silently changes
      nothing — it is an account-level capability Telnyx must grant). A European
      customer renting a US number **cannot text their own contacts**. Either
      gate the line to US/CA storefronts or say it plainly on the store screen.
      This is a refund generator if discovered after purchase.

---

## 2. Code — the four capabilities

| capability | state | what's left |
|---|---|---|
| **Receive SMS** | ✅ **Proven end to end.** A real `message.received` webhook arrived and passed Ed25519 verification in production. | Nothing. |
| **Send SMS** | ✅ Built + deployed (`send-line-message`), settle-on-receipt wired. | Unproven against real traffic. Blocked on 10DLC for US; fine on CA. |
| **Outbound calls** | 🟠 Wired: `TelnyxRTC 4.1.2`, CallKit, dialer, allowance gate, CDR settlement. **No real call has ever been placed.** | Device test. The voice adapters were written from docs, not probed — the first call IS the probe. |
| **Inbound calls** | 🔴 Cannot work yet. | The push credential above. The recording half is now fixed (below). |

**Fixed 2026-08-06 while auditing** — inbound calls created no `line_calls` row
at all (`record_line_call` had one caller, outbound-only), so an inbound call
consumed no allowance, appeared in no history, and left nothing for
`sync-telnyx-cdr` to match, meaning the minutes Telnyx billed us were attributed
to nobody. `begin-line-call` now takes a `direction`; inbound is **recorded but
never billed**, because nobody controls who calls them.

---

## 3. Multi-number work (after the §0 decision)

Sized against the live code, not estimated:

- [ ] **Schema.** Replace `phone_lines_one_live_per_user` with a per-user count
      check against the subscribed tier's slots. Add `slots` to
      `line_subscriptions`. The lapse state machine (grace → past_due →
      suspended → releasing) must decide *which* number is released when a user
      downgrades — that is a product decision, not a technical one.
- [ ] **`my_line` → `my_lines`.** The view is singular and is the only thing
      clients may read (the base table holds `monthly_cost_cents` and every
      Telnyx id, and SELECT is revoked from `anon`/`authenticated`).
- [ ] **13 single-line lookups** across **11 edge functions** currently do
      `.maybeSingle()` on the user's line. Each becomes "the line this
      request is about", so every one needs an explicit line id from the client
      — and must verify ownership server-side, never trust the id.
- [ ] **Client.** `AppState.line: Line?` becomes a collection. Needs a line
      switcher, per-line threads, per-line call history, per-line allowance, and
      a dialer that knows which number it is calling *from*.
- [ ] **Allowance semantics.** Per-line, or pooled across lines? Affects
      `consume_line_allowance`, the meter UI and the paywall copy.

---

## 4. Verification before selling

- [ ] **Physical device.** The simulator cannot receive a PushKit push, so
      inbound calling cannot be tested there and an outbound call appearing to
      work there proves nothing.
- [ ] **First real call = the probe.** Read `app_config.telnyx_voice_faults`
      and `telnyx_cdr_probe` immediately after.
- [ ] **Assert the Info.plist.** A green build does not prove it:
      ```
      plutil -p "$APP/Info.plist" | grep -A3 UIBackgroundModes   # must list audio + voip
      ```
- [ ] `scripts/verify-line-lifecycle.sql` — 12 behavioural checks in a
      rolled-back transaction. Re-run after any change to the line RPCs.
      (It was broken and silently unrunnable until 2026-08-06.)
- [ ] **Sandbox the lapse path.** `sandboxOptIn` is on for the grace period
      specifically so `DID_FAIL_TO_RENEW` / `GRACE_PERIOD` can be exercised.

---

## 5. Release

- [ ] The App Store has **1.9, which has no Number tab at all.** Everything
      above is repo-only. A client release is required for any of it to reach a
      user.
- [ ] Draft version **2.0** exists in ASC — the subscription needs to be
      attached to a version to ship.
- [ ] App Review will use a **Sandbox** subscription. Verify the reviewer can
      actually provision a number in Sandbox, or they subscribe, get nothing,
      and reject.
- [ ] E911 must be **disabled and unmissably disclosed**, not buried in a Terms
      link. `emergency_status` is `disabled` by default, so the stance is "never
      enable it".

---

## Critical path

**Telnyx float** → **VoIP push credential** → **device test of one number, all
four capabilities** → **§0 decision + multi-number build** → **client release**.

The first two are money and a dashboard visit. Everything in §2 is already
built and waiting on them; §3 is the only substantial engineering left, and it
should not start until §0 is decided, because the answer changes the schema.
