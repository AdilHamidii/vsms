# Temp-e-mail subscription — design

**Date:** 2026-08-19
**Status:** approved for planning
**Ships in:** 2.2 (2.1 is live; the CallKit audio fix is already on `main` for 2.2)

## What this is

The temp-e-mail line becomes a subscription product. A non-subscriber gets
**one free address, ever**. After that, ordering a free-domain address requires
an auto-renewable subscription:

| product | price | trial |
|---|---|---|
| `com.anthersystems.VirtualSIM.mail.monthly` | $2.99 / month | none |
| `com.anthersystems.VirtualSIM.mail.yearly` | $29.99 / year | 3 days |

The subscription grants **unlimited addresses on the free domains**
(`outlook.com`, `hotmail.com`). **`gmail.com` is not included** and stays at
1 credit for everyone, subscriber or not.

The review prompt also moves off the code screen (section 7).

## Why

E-mail is the most-used surface in the app and earns essentially nothing:
over the 14 days to 2026-08-19 it took **177 orders from 54 users, 158 of them
free**, against **1 credit of lifetime revenue**. It also delivers better than
the paid SMS line — **48% (85 of 177)** against SMS's 26.7% — so the traffic is
real demand meeting a product that works.

## Owner decisions (settled — do not re-litigate)

1. **One free address per account, LIFETIME**, not per day.
2. **Retroactive.** Free orders already in `email_orders` count. The ~54
   existing e-mail users are walled on their next attempt, with no grace period.
3. **Free domains only.** `gmail.com` stays a 1-credit purchase for subscribers
   too.
4. **Review prompt fires on the next foreground after a delivered code**, never
   on the code screen.

### Risk accepted with decisions 1 and 2

This ends the app's highest-volume surface for everyone who does not convert.
Expect free e-mail volume to fall to near zero within a day of release; the
replacement conversion rate is not predictable from current data.

**Agree the reversal trigger before shipping.** Two levers, and they are not
the same: the *number* of lifetime free addresses is read live from
`app_config.email_free_lifetime_grants` (default 1, clamped 0–50), so raising
it needs no deploy; switching back to a *per-day* rule is a migration, because
the predicate itself changes. Decide in advance what free-e-mail volume or
conversion rate would make you pull either lever.

### Open question, non-blocking

**"Unlimited" is only as good as HeroSMS's free stock.** Stock is per
(site, domain) and genuinely runs dry — hotmail measured **two** available for
discord.com in one sweep. A paying subscriber can therefore be refused, and the
one domain that would rescue them is excluded by decision 3. Two ways out,
owner's call before release:

- let subscribers fall back to `gmail.com` at our cost, under a stated daily
  cap (~$0.04 each, so 10/day is $12/month against $2.54 net — needs a low cap);
- or word the pitch so it never promises availability.

The build does not depend on which is chosen. **Default if undecided: no
fallback**, and the paywall copy names the two domains explicitly rather than
saying "unlimited e-mails".

## Architecture

### Chosen approach: a second subscription table, parallel to the line

`email_subscriptions` mirrors `line_subscriptions`. It reuses
`verifyAppleJWS`, the ASSN endpoint, and the same lapse vocabulary, but keeps
its own rows and its own state.

**Rejected — one generic `subscriptions` table with a `kind` column.**
Architecturally cleaner and avoids two near-identical state machines. Rejected
because `line_subscriptions` currently carries three live paying subscribers
and a lapse backstop added on 2026-08-18, 88 minutes before the first trial
would have lapsed undetected. Restructuring live money code in order to add a
second product is the wrong order of risk. Revisit if a third subscription
appears.

**Rejected — client-side entitlement via StoreKit only.** No server table; the
device reports whether it is subscribed. Violates the standing rule: *if a
value decides money and the device can set it, the device must not settle.*

### A second App Store subscription GROUP is mandatory

Apple allows **one active subscription per group**, with no quantity on iOS.
The line group (`22289428`) holds `line.monthly` + `line.yearly` as
upgrade/downgrade siblings, and `_shared/iap.ts` documents that a user must not
be able to hold two at once. Putting mail products in that group would make
buying a $2.99 mail plan **replace** a $9.99 number.

A separate group also means a user may legitimately hold **both** a line and a
mail subscription. Nothing may assume otherwise.

## 🔴 The most dangerous change: `isSubscriptionProduct` means two things

The predicate is consumed in two places whose requirements are **opposite**:

| caller | meaning today | mail products must be… |
|---|---|---|
| `iap-verify:114` | "not a credit pack — do not 400 and page the owner" | **included** |
| `apple-notifications:233` | `if (!isSubscriptionProduct(...)) return; // not our line` | **excluded** |

Every branch after that line in `apple-notifications` UPDATEs
`line_subscriptions` and drives the phone-number lapse machine. If mail
products fall into it, a mail cancellation **suspends and releases someone's
rented phone number**.

Resolution:

```ts
export type SubscriptionFamily = "line" | "mail";
export function subscriptionFamily(productId: string): SubscriptionFamily | null
export function isSubscriptionProduct(id: string): boolean   // family(id) !== null
```

- `iap-verify` keeps calling `isSubscriptionProduct` — behaviour unchanged, mail
  is now covered.
- `apple-notifications` dispatches on `subscriptionFamily(...)`: `"line"` runs
  the existing code path untouched, `"mail"` runs the new one, `null` falls
  through to the existing consumable handling.

**This is the single most likely source of a silent money bug in the change.**
It gets explicit behavioural coverage (see **Testing**, item 1), not just a
green build.

Also unchanged and load-bearing: **`PRODUCT_TO_CREDITS` must never gain a
subscription id** — one entry pays wallet credits on every renewal forever.

## Components

### 1. App Store Connect

- New subscription group **"vSMS Mail"**, with group localization.
- Two products as tabled above; `mail.yearly` carries the 3-day introductory
  free trial. Yearly is a 16% saving against monthly ($29.99 vs $35.88).
- **Base territory USA**, and **prices set manually in both USD and EUR.** ASC
  consumable/subscription price equalization has inverted this app's ladders
  twice (credit packs drifted to $4.99-vs-€5.99). Never set only the base.
- Territory availability, then prices — in that order. Setting a price before
  `subscriptionAvailability` exists returns a misleading 409
  `ENTITY_ERROR.RELATIONSHIP.INVALID` pointing at the price point, which is
  fine.
- Base price does **not** propagate to other territories over the API. Use
  `scripts/asc-equalize-subscription-prices.py`.
- Review screenshot + review notes are required or the product sits in
  `MISSING_METADATA`, and **a `MISSING_METADATA` product is not returned by
  StoreKit even in Sandbox** — from the phone that looks like a bug in our own
  code. Check ASC state before debugging the client.
- ASSN URLs are **app-level and already configured**; this group's
  notifications arrive at the existing `apple-notifications` endpoint. That is
  exactly why the family split above must land in the same release.
- `VirtualSIM/Products.storekit` gains a matching local group — local StoreKit
  testing does not read ASC, so the two are kept in step by hand.

### 2. Schema

```
public.email_subscriptions
  original_transaction_id  text primary key
  user_id                  uuid not null        -- NO FK to auth.users (see below)
  product_id               text not null
  state                    public.line_sub_state not null
  auto_renew               boolean not null default true
  environment              text not null
  expires_at               timestamptz
  grace_expires_at         timestamptz
  last_transaction_id      text
  latest_signed_transaction text                -- raw JWS, so revenue_snapshot
                                                -- can decode the REAL price
  revocation_date          timestamptz
  revocation_reason        integer
  storefront               text
  price_milli              bigint
  currency                 text
  created_at / updated_at  timestamptz not null default now()

index (user_id)
index (state, expires_at)
RLS enabled; revoke all from anon, authenticated
```

**`state` reuses the existing `public.line_sub_state` enum**
(`active,grace,billing_retry,expired,revoked,canceled_pending`) rather than
declaring a second identical one. The values describe Apple's subscription
lifecycle, which is not line-specific. The `line_` prefix in the type name is
therefore now a misnomer; renaming it is not worth a migration on a live enum,
so this note is the record that it is shared on purpose.

**No foreign key to `auth.users`, deliberately.** Same reasoning as
`line_subscriptions`: with a FK, delete-account → re-signin drops our record of
a live Apple subscription and lets the same `original_transaction_id` bind to a
second account. `subscription_bound` is returned on that replay.

### 3. SQL

- **`record_email_subscription(...)`** — signature mirrors
  `record_line_subscription`, returns `{ok, reason}` and refuses
  `subscription_bound` when the original transaction already belongs to another
  user. The **only** creator of rows.
- **`has_email_subscription(p_user uuid) returns boolean`** —
  `state in ('active','grace')` and `coalesce(grace_expires_at, expires_at) >
  now()`. `SECURITY DEFINER`, `search_path = public`.
- **`begin_email_order` changes** (free path only; the credit path is untouched):

  ```
  if p_credits = 0 then
      if has_email_subscription(p_user) then
          -- subscriber: allow, subject to the abuse cap below
      else
          lifetime := count(*) from email_orders
                      where user_id = p_user and cost_credits = 0
                        and status <> 'failed';
          if lifetime >= app_config.email_free_lifetime_grants (default 1)
              return {ok:false, reason:'subscription_required'};
      end if;
  end if;
  ```

  `status <> 'failed'` is retained from the current daily rule: an order that
  never provisioned a mailbox is not a grant.

- **Subscriber abuse cap.** Free domains cost $0 wholesale but the inventory is
  scarce and shared across all users. A subscriber loop could drain it for
  everyone. Hard stop at `app_config.email_sub_daily_cap` (**default 25/day**),
  refused as `daily_cap_reached` with the cap in the payload so the client can
  state it. Tunable without a deploy.
- All new functions: `revoke execute ... from public, anon, authenticated` —
  and assert with `has_function_privilege`, because a `revoke` from
  `anon, authenticated` alone is a **no-op** while PUBLIC holds the grant.

### 4. Edge functions

- **`verify-email-subscription`** — a near-copy of `verify-line-subscription`:
  verify the JWS through `verifyAppleJWS`, reject non-Production
  where the line does, resolve the product, call `record_email_subscription`,
  return `{ok}` or a 409 carrying `subscription_bound`. It is the only path that
  creates a row.
- **`apple-notifications`** — family dispatch (above) plus a mail branch
  handling `SUBSCRIBED` / `DID_RENEW` / `DID_CHANGE_RENEWAL_STATUS` /
  `DID_FAIL_TO_RENEW` (+`GRACE_PERIOD`) / `EXPIRED` / `REFUND` / `REVOKE`.
  Every branch is an UPDATE, and **an UPDATE matching nothing is not an error** —
  the mail branch therefore calls an `ensureEmailSubscriptionRow` equivalent
  first, exactly as the line branch does, or an Apple notification that beats
  our own purchase call silently does nothing forever.
  **A mail REFUND/REVOKE revokes the entitlement only.** It must not touch
  `phone_lines`, wallets, or credits.
- **`create-email-order`** — surfaces the new refusal reasons unchanged from
  SQL: `subscription_required`, `daily_cap_reached`.
- **Deploy lists**: `verify-email-subscription` joins the **JWT** group (it is
  called by a signed-in client). It must be added to the list in `CLAUDE.md` in
  the same commit — a function in neither list is a function nobody redeploys
  after a `_shared` change.

### 5. Client

- **`MailSubscriptionStore`**, modelled on `SubscriptionStore` (which is
  line-specific and stays that way). Products `mail.monthly` / `mail.yearly`.
- **`PurchaseIntent` gains a `.mailSubscription` case, cleared centrally in
  `flow`'s `didSet`** — and, because the paywall can be opened at `flow == nil`,
  also on the transitions that leave e-mail mode. This bug class has now shipped
  three times (checkout draft, `checkoutEsimPlan`, `emailMode`); the fourth
  product line gets the clear in its first commit.
- **Paywall placement.** Not over the code. The first free address delivers its
  code normally; the offer appears on the **next attempt** to order a free
  address — the user has seen the product work before being asked to pay.
- **`APIError`** gains `subscription_required` and `daily_cap_reached` in the
  same commit as the backend literals.
- Existing `EmailDomainSheet` copy must stop implying free addresses are
  unlimited, and the gmail row keeps its 1-credit price for subscribers.

### 6. Ops

- `/subs` extends to report mail subscriptions beside line ones, including the
  active/expired split and the state-vs-entitlement disagreement warning.
- `revenue_snapshot` should count mail subscription revenue. It currently
  covers credit packs only and **already omits line subscription revenue** —
  that gap is pre-existing and is explicitly *out of scope* here, but the new
  product makes it worse, so it is recorded as a follow-up rather than silently
  inherited.

### 7. Review prompt

- Remove the `requestReview()` call sites from `OtpScreen` and
  `EmailCodeScreen`.
- `reviewableRecentDelivery()` on foreground becomes the only path. It already
  exists, is bounded to 30 minutes after a delivery, and delegates every gate
  (once per app version, per-order dedupe, `ScreenshotMode` guard) to
  `shouldRequestReview` — none of which changes.
- **New rule: a review prompt and the subscription paywall never appear in the
  same session.** Whichever fires first suppresses the other until the next
  cold launch.

Rationale: the current prompt fires ~0.9s after the code renders, which is
precisely when the user is leaving to paste it somewhere else — a near-guaranteed
dismissal that also burns one of Apple's ~3 prompts per user per year.

## Data flow

```
first free address
  user taps order → create-email-order → begin_email_order
    free path, lifetime count = 0 → allowed
  code arrives → EmailCodeScreen (no review prompt)
  user leaves, pastes code
  user returns → foreground → reviewableRecentDelivery() → native review prompt

second free address
  user taps order → create-email-order → begin_email_order
    lifetime count = 1, no subscription → {ok:false, subscription_required}
  client maps to the paywall → MailSubscriptionStore → StoreKit purchase
  → verify-email-subscription (JWS verified server-side)
  → record_email_subscription writes the row
  → retry the order → has_email_subscription = true → allowed

lapse
  Apple → apple-notifications → subscriptionFamily = "mail"
  → ensure row, UPDATE state → has_email_subscription false at expiry
  → next free order refused with subscription_required
```

## Error handling

| condition | code | surfaced as |
|---|---|---|
| free allowance used, not subscribed | `subscription_required` | the paywall |
| subscriber past the daily sanity cap | `daily_cap_reached` | states the cap and when it resets |
| free domains out of stock | existing `domain_unavailable` | must not read as "you are not subscribed" |
| Apple tx already bound elsewhere | `subscription_bound` (409) | "already used on another account" |
| JWS fails verification | `verification_failed` (400) | generic purchase failure |

Every literal added to an edge function gets its `APIError` case in the same
commit — the standing rule that already cost one outage when the backend was
renamed to `provider_unreachable` and the client still matched
`smspva_unreachable`.

## Testing

There is no test suite; verification is behavioural and stated per item.

1. **Family split** — the highest-risk item, and it cannot be tested in a
   rolled-back transaction: `apple-notifications` is an edge function and
   commits its own writes. Procedure: snapshot `phone_lines` and
   `line_subscriptions` for a user who holds a live phone line, POST a
   **Sandbox** mail `EXPIRED` notification for that same user, then diff both
   tables and assert they are **unchanged**. A green build proves nothing here.
2. **`iap-verify` does not 400 a mail purchase**, and no mail product appears in
   `PRODUCT_TO_CREDITS` (assert programmatically, not by eye).
3. **`begin_email_order`** in a rolled-back transaction: 0 prior free orders →
   allowed; 1 prior → `subscription_required`; with an active row → allowed;
   past the daily cap → `daily_cap_reached`; expired subscription →
   `subscription_required`.
4. **Grant privileges** — `has_function_privilege('anon', …, 'execute')` returns
   **0 rows** across every new function.
5. **`record_email_subscription` replay** — same original transaction, second
   user → `subscription_bound`, first user's row unchanged.
6. **Client** — `xcodebuild` (the only check; `swiftc -typecheck` is retired),
   plus a Sandbox purchase of each product with `sandboxOptIn` on the trial so
   the `DID_FAIL_TO_RENEW` branch is exercisable.
7. **Migration recorded** — after applying, `select` it back from
   `schema_migrations` by name, and `select proname from pg_proc` for every
   function it creates. A migration that is merely missing is inert; one that is
   missing while something calls it is a live bug with no symptom.

## Out of scope

- Refactoring `line_subscriptions` into a generic `subscriptions` table.
- Adding subscription revenue (line or mail) to `revenue_snapshot`.
- Any change to the SMS or eSIM lines.
- Making gmail part of the subscription.
