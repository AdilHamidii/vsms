# A second code on the same number — the resend window

**Date:** 2026-09-08
**Status:** approved, not yet implemented
**Owner decisions:** deliver the second code automatically (not on request),
tell the user explicitly how long they have, and let the newer code replace the
older one on builds already in the field.

## The problem, from a real support case

User `62a14c57` registered a Whatnot account on `+13193702474` (us / 5sim /
`virtual51`), received the code at 14:19Z, and Whatnot then asked for a second
code. There was no way to get it. They burned two more numbers trying — which
could never work, because the second code goes to the number that holds the
account, not to a new one.

**We caused this.** The order was created 14:19:01 and closed **14:19:26** —
twenty-five seconds later — because `poll-active-orders` calls `markSuccess()`
on code arrival, which for 5sim is `five.finish(orderId)`. 5sim's own FAQ opens
with:

> If you finish an order, then there is no way to request and receive SMS using
> the same number again.

So `finish` is the thing that forecloses it, and we call it immediately.

## What 5sim actually supports

The same FAQ:

> You can receive an unlimited quantity of SMS within 6-30 minutes from a
> certain service to the numbers of England (lycamobile, three, ee, vodafone
> etc.), USA (Virtual8), Canada (Virtual8, Virtual12), to the numbers of
> Virtual2, Virtual21, Virtual26, Virtual34, Virtual36, Virtual38, Virtual40,
> Virtual47, Virtual49, Virtual51, Virtual52, Virtual53, Virtual54, Virtual58
> operators.
>
> After receiving the first SMS, you have up to 5 minutes to receive the next
> SMS, otherwise the order will be closed automatically.

Two consequences that shape the whole design:

1. **The mechanism is "do not hang up", not "buy again".** The second SMS
   arrives on the *original activation*. Nothing is purchased, so nothing is
   charged — the owner's "if it's free then 0 credits" branch is the only branch
   that exists.
2. **The window is 5 minutes from the LAST SMS, not a fixed budget from the
   first.** The clock restarts on every message. Copy must say what is true
   after each arrival rather than counting down from a total.

### Reuse is a dead end — proven, do not revisit

`user/reuse/{product}/{number}` is refused after a cancel (probe, 2026-08-18)
**and** after a finish (probe, 2026-09-08 — 400 `reuse not possible`, $0.00
charged, twelve minutes after the activation finished). Production never buys
with `?reuse=1`, and adding it would reprice every order to serve a minority.
This design does not use reuse at all.

## Coverage

Measured over 30 days, restricted to orders that actually received a code —
the only population that can want a second one:

| provider | codes | eligible per the FAQ |
|---|---|---|
| 5sim | 78 | **45 (58%)** |

Eligible pools carrying our traffic: `virtual51` (29 codes), `virtual8` (6),
`virtual34`, `virtual12`, `virtual58`, `virtual53`, `virtual26`.
Ineligible: `virtual63` (12), `virtual66` (7), `virtual60` (4), `virtual59`,
`virtual61`, `virtual65`, `virtual4`, `virtual28`.

⚠️ **58% is 5sim's published claim, not our measurement.** The first real second
code is the probe. Re-derive rather than quoting this table:

```sql
select operator_used, count(*) filter (where otp is not null) as codes
from public.orders
where provider = '5sim' and smspva_number is not null
  and created_at >= now() - interval '30 days'
group by 1 order by codes desc;
```

## Scope

**In:** 5sim only.

**Out:** HeroSMS. `_shared/herosms.ts:645` defines `STATUS_RETRY = 3` —
commented *"request another code on the SAME number (free)"* — with a wrapper at
line 677 and **no caller anywhere in the repo** (the same shape as the six
`line_subscriptions` updaters that shipped with no INSERT). It is an explicit
*request another* verb rather than a hold-open, so it needs different semantics,
and HeroSMS delivered 3 codes in 30 days. Its own change, later.

## Design

### 1. Eligibility — `_shared/fivesim.ts`

Add `supportsResend(country, operator): boolean` over a frozen set:

- unconditional: `virtual2, virtual21, virtual26, virtual34, virtual36,
  virtual38, virtual40, virtual47, virtual49, virtual51, virtual52, virtual53,
  virtual54, virtual58`
- `virtual8` — USA and Canada only
- `virtual12` — Canada only

England's named operators (`lycamobile`, `three`, `ee`, `vodafone`) are HeroSMS
territory in our catalog and are out of scope with the rest of HeroSMS.

The function must fail **closed**: an unknown operator, a null `operator_used`,
or a non-5sim provider returns false. Holding an activation open on a pool that
does not support it wastes the window and delays `finish` for nothing.

### 2. Schema — one migration

```sql
alter table public.orders
  add column resend_watch_until timestamptz,
  add column otp_history jsonb;
```

- `resend_watch_until` — how long we keep the activation open. Null means "not
  eligible, or the window has closed and `finish` has been called".
- `otp_history` — `[{code, text, at}]`, newest last.

🔴 **No new `order_status` value.** The iOS `OrderStatus` enum
(`Components/Pills.swift`) is a plain String enum with no unknown case, so a
status it does not recognise throws on decode and breaks the Orders tab for
every shipped build. The order still flips to `received` exactly as today; the
window lives in a nullable column, which is the same pattern `late_watch_until`
already uses for the late-code rescue.

### 3. `poll-active-orders`

**a. First code** (the existing atomic claim, `index.ts` ~726). Unchanged
except: when `supportsResend(...)` is true, also write `resend_watch_until =
now() + 5 minutes` **and skip `markSuccess`**. Deferring that call is the entire
feature.

**b. A new sweep**, placed **before** the pending-orders loop, alongside the
late-watch sweep. That position is deliberate and is a rule this repo already
paid for: the last thing in the handler is the first thing dropped when the
worker approaches its ~150s budget.

For each order with `resend_watch_until > now()`:

- poll the provider; `fivesim.ts:327` already walks `sms[]` backwards, so the
  newest code comes back with no adapter change
- if the returned code differs from `orders.otp`: append `{code, text, at}` to
  `otp_history`, set `otp` to the new code, reset `resend_watch_until = now() +
  5 minutes`, and push
- if `resend_watch_until <= now()`: call the deferred `markSuccess` and set
  `resend_watch_until = null`

The claim must be atomic in the same style as every other status write here —
the update is conditional on the row still carrying the `otp` we polled against,
so two overlapping runs cannot double-append or double-push.

**The failure mode is safe by construction.** If the sweep never runs, 5sim
closes the activation itself after 5 minutes. We lose a little account rating,
never money, and never a code.

**c. `check-order`** — the manual "Check now" path flips `waiting → received`
and calls `markSuccess` at `index.ts:93`. It needs the identical deferral, or a
user who taps Check now loses the window the cron path would have kept.

### 4. Push

`{ orderId, otp: <new code>, event: "resend" }` — the `orderId` + `otp` shape is
byte-identical to the push shipped builds already route on. `PushManager` routes
on `orderId`, opens the OTP screen, and the screen renders `orders.otp`, which
now holds the newer code.

**This is what delivers the feature to 2.2–2.11 with no release.** The accepted
cost, per the owner's decision: on those builds the first code is *replaced* on
screen rather than appended. The risk of a non-code SMS overwriting a real code
is bounded by the poller only accepting entries where 5sim populated
`sms[].code`.

### 5. Client — next release

- `Order` gains `resendWatchUntil: Date?` and `otpHistory: [OrderCode]?`, both
  **optional** so a row without them decodes cleanly.
- `OrdersAPI.columns` gains both names. That list must stay exactly the decoding
  model's stored properties — a column dropped from it silently nils an optional
  and throws on a non-optional.
- `OtpScreen` renders the countdown the owner asked for, ticking from
  `resendWatchUntil`: *"Need another code? You have 4:32 to get one on this
  number."* It disappears when the window lapses, and is absent entirely when
  `resendWatchUntil` is null — an ineligible pool must never advertise it.
- When `otpHistory` holds more than one entry, list them newest-first so the
  earlier code is still reachable.
- Six locales. Never `Text("literal")`.

### 6. Deliberately unchanged

- **`orders.expires_at`.** Our own 8-minute window is bookkeeping; the expiry
  sweep selects `status='waiting'` only, so an order sitting at `received` past
  its `expires_at` collides with nothing. 5sim's activation window is theirs and
  outlives ours.
- **`markSuccess` itself.** It is deferred by its callers, not modified. Its
  contract — tell the provider the activation succeeded — is unchanged.
- **Money.** No wallet call, no refund path, no new `wallet_reason`. A second
  code is free within the original activation.

## Risks, stated plainly

1. **The 58% is unverified.** 5sim's list is a published claim. If second codes
   never arrive on a pool the list names, the feature silently does nothing —
   which is why the sweep logs every held window and every promotion.
2. **Deferred `finish` delays account rating.** 5sim's `rating` falls on abusive
   patterns and blocks buying below a floor. Delaying a *successful* close by
   five minutes should be neutral, but it is untested at volume — watch
   `5sim_health.rating`.
3. **The first code is replaced on shipped builds.** Accepted by the owner. New
   builds keep the history.
4. **A held-open order holds its number longer.** Already paid for, so it costs
   nothing extra.

## Verification

There is no test suite, so:

- `scripts/verify-resend-window.sql` — behavioural, inside a rolled-back
  transaction: an eligible order gets a window; an ineligible one does not; a
  second code appends and resets the clock; a double sweep neither
  double-appends nor double-pushes; a lapsed window calls `finish` once and
  nulls the column.
- `xcodebuild` for the client half. `swiftc -typecheck` is retired.
- Live: grep the poller logs for the first `resend` promotion. Until one lands,
  the feature is unproven regardless of what the code does.

## Documentation

CLAUDE.md, in the same commit as the code:

- the 5sim reuse bullet already records the disproof; add that the supported
  path is holding the activation open, with the operator list and the 5-minute
  rolling window
- a note under the poller that `markSuccess` is now **deferred** for eligible
  5sim orders, and why calling it on arrival was destroying the second code
- the HeroSMS `STATUS_RETRY` caller-less wrapper, recorded as known-open
