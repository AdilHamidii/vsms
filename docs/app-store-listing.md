# App Store Connect listing — vSMS

Copy these into App Store Connect → My Apps → vSMS → App Information /
Localizable Information (US English).

The structure below is **ASO-optimized**: keywords are spread across
Name, Subtitle, and Keywords field without repetition (Apple combines
all three for search indexing, so a word appearing in Name doesn't
need to repeat in the Keywords field — that just wastes character
budget).

---

## Name & subtitle

```
LIVE NOW (read from ASC 2026-07-31):
  Name      (30/30):   vSMS: Temp Number, Receive SMS
  Subtitle  (26/30):   Second Phone Number & eSIM

PROPOSED for 1.6:
  Name      (30/30):   vSMS: Temp Number, Receive SMS      ← unchanged
  Subtitle  (30/30):   Temp Mail & Phone Verification      ← replaces the above
```

⚠️ **This file had drifted from the live listing.** It previously documented a
name and keyword set that were never live. Always read ASC before trusting it:
`GET /v1/appInfos/{id}/appInfoLocalizations` for name+subtitle,
`GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations` for keywords.

**Indexed atoms across name + subtitle** (Apple composes phrases across the two,
so none of these need repeating in the keyword field):
`vsms · temp · number · receive · sms · mail · phone · verification`

**Why the subtitle changes.** `Second Phone Number & eSIM` spent the app's
second-heaviest ranking field on the two worst possible targets: "second phone
number" is owned by TextNow (913,221 US ratings), Text Free (594,098) and Text Me
(667,853) — users who want a *permanent* line they can send from, which this app
cannot do — and eSIM is a **paused** product returning zero purchasable plans.

**Why `Temp Mail` intact.** Owner decision. It duplicates `Temp` from the name,
costing 5 characters, and that is the deliberate price of an exact phrase in a
high-weight field: practitioner consensus is that an intact phrase outranks the
same words composed from scattered atoms. `Phone` + the name's `Number` composes
*temp phone number* / *phone number* (18,100/mo US each), and `Verification` is
the highest-frequency term in competitor SMS subtitles that the name lacks.

**Strategy note:** SMS is the revenue product; temp email is an acquisition hook.
The name therefore stays 100% SMS, and the rest of the email vocabulary goes into
the keyword field and additional localizations — surfaces that are *additive*
rather than displacing terms that already earn.

---

## Keywords (100 chars, comma-separated, NO spaces around commas)

```
LIVE NOW (100/100):
burner,otp,code,verification,virtual,disposable,privacy,private,text,online,data,temporary,anonymous

PROPOSED for 1.6 (100/100):
email,virtual,disposable,temporary,online,otp,code,inbox,fake,spam,burner,signup,text,verify,address
```

**Added:** `email` (composes *temp email*, *burner email*, *disposable email*,
*email verification* — and with `Mail` in the subtitle, *temp mail*), `inbox`,
`fake`, `spam`, `signup`, `verify`, `address`.

**Dropped, with reasons:**
- ❌ `privacy` + `private` (14 chars) — head terms owned by VPNs and password
  managers; Proton Mail (46,010 US ratings) owns "private email". Unwinnable at
  0 ratings, and wrong-user traffic hurts the per-query conversion Apple weights.
- ❌ `data` — eSIM is paused. Composes *data recovery / data usage / data plan*.
- ❌ `anonymous` — **not defensible as a claim.** Sign in with Apple is mandatory
  and 203 of 204 accounts carry an email address; every order is stored against a
  `user_id` with the number and the message body. Guideline 2.3.7 targets
  unverifiable claims. "Private — keeps your real number off the form" is
  defensible; "anonymous" is not.
- ❌ `verification` — promoted into the subtitle, so repeating it here is waste.

**Deliberately NOT included:**
- ❌ Words already in Name or Subtitle (`sms`, `temp`, `number`, `receive`,
  `mail`, `phone`, `verification`). Apple explicitly says not to repeat them, and
  it composes across the three fields anyway.
- ❌ `whatsapp`, `telegram`, `tinder`, `textnow` and any other brand — banned in
  three separate places (App Store Search "improper keyword use", 2.3.7, 5.2.1),
  and independently a trademark exposure. Safe in screenshots and description.
- ❌ `free` — the app is free to download, but the claim dilutes conversion and
  invites the free-unlimited-inbox expectation that our credit pricing breaks.
- ❌ `esim` — paused.

**Format rules (Apple-documented):** comma-separated, **no spaces after commas**
(every one is a wasted indexed character), one grammatical form per term, no
stop words, no category name (indexed separately), no app or developer name.

---

## Promotional text (170 chars — editable any time without resubmit)

```
LIVE NOW — inaccurate, replace immediately:
Get a temporary number in seconds and receive your verification code with a push notification. Now with eSIM data plans.

USE UNTIL BUILD 19 SHIPS (SMS only — no email claim yet):
Get a temporary phone number for any signup that needs an SMS code. Most codes arrive within 3 minutes, and you are only charged if one does.

USE ONCE BUILD 19 IS LIVE (adds email):
Temporary phone numbers and temporary email addresses for signup codes. Most SMS codes arrive within 3 minutes, and you are only charged if a code arrives.
```

**This field is editable WITHOUT a new version or a review** — it is the one
fast-iteration lever on the whole listing, so never waste it on keywords (it is
not indexed).

**Why the live text must change now.** It advertises **eSIM data plans**, which
are paused (`app_config.esim_paused = true`, 0 of 1,081 plans active) — a live
Guideline 2.3 exposure. It also promises delivery "in seconds": measured p50 is
58s but p90 is 131s, and the app's own copy correctly says "within 3 min". The
house rule is to quote p90 next to a running clock, never p50.

⚠️ **Do not add the email sentence before build 19 is the live build.** The
released 1.5 has no email UI; advertising temp email that the shipped binary
cannot deliver is exactly the misleading-metadata case under 2.3.

---

## Description (4000 chars max — first ~170 chars visible without "more" tap)

```
vSMS gives you a temporary phone number for SMS verification codes — and a temporary email address when a site wants the code by email instead. Without giving up your real number.

Protect your real number from spam, data breaches, and marketing lists. Get a fresh number for any service that accepts SMS, receive the code, and move on. Most codes arrive within 3 minutes.

WHAT IT DOES
• Pick a service and country — 265 services across 69 countries
• Tap once to get a fresh number — no setup, no commitments
• Receive your SMS automatically — one-tap copy
• See exactly how long is left before the number expires
• Auto-refund in credits if no code arrives within 8 minutes

TEMPORARY EMAIL, TOO
• Need an email code instead? Get a temporary address on outlook.com,
  hotmail.com or gmail.com
• outlook.com and hotmail.com are free — up to 3 a day
• gmail.com costs 1 credit
• The code appears in the app the moment it arrives

HOW IT WORKS
• Sign in with Apple — no email forms, no passwords
• Pay with credits — buy a small pack, use them anywhere
• Live pricing per service and country — see exactly what you'll pay before you commit
• Credits never expire

WHY YOU'LL LIKE IT
• Quiet, Apple-utility design that respects your time
• Zero ads. Zero tracking. Zero marketing emails.
• Push notifications the moment your code arrives — even with the app closed
• Honest pricing: the price shown is the price charged
• Available in English, French, German, Italian, Spanish, Portuguese, and Japanese

WHO IT'S FOR
vSMS is for people who want a temporary number for short-term, lawful purposes — protecting privacy when signing up for a new service, testing your own app, or recovering account access. It is not a tool for fraud or for bypassing legitimate identity checks. Please use only on services where temporary numbers are permitted by their terms.

CREDIT PACKS
• 5 credits — $2.99
• 12 credits — $5.99
• 30 credits — $12.99
• 60 credits — $24.99
• 150 credits — $59.99 (best value per credit)

Different routes cost different amounts depending on the service and country — most sit in the low tens of credits, a few cost more. The exact cost is always shown before you confirm, and you are never charged a hidden fee.

PRIVACY FIRST
We do not collect your contacts, your real number, your location, or any device data beyond what's needed to deliver the service. Full Privacy Policy and Terms of Use are linked inside the app under Account → Legal.

QUESTIONS
Email support directly from inside the app: Account → Support → Contact support.
```

Char count: ~2,400 (well under the 4,000 cap; leaves room to add more sections later without rewriting).

---

## Support URL

```
https://superficial-watch-d12.notion.site/Help-3704b908b4b780fd8d39ea0fd6078efd?source=copy_link
```

## Marketing URL (optional)

Skip unless you have a landing page.

## Privacy Policy URL (required)

```
https://superficial-watch-d12.notion.site/Privacy-Policy-3704b908b4b7801aa6fbfe1bacdaec09?source=copy_link
```

---

## App Review Information

```
First Name:     Adil
Last Name:      Hamidi
Phone Number:   <your number>
Email:          adil.hamidii123@gmail.com

Demo Account:
  Apple ID:     N/A — app uses Sign in with Apple.
                The reviewer can sign in with any Apple ID. Each new
                account is automatically granted 3 free credits, which
                is enough to complete a low-cost route end-to-end
                without an in-app purchase.

Review Notes:
  vSMS provides temporary phone numbers for receiving SMS verification
  codes, and temporary email addresses for receiving email codes.
  Numbers are supplied by two infrastructure providers (HeroSMS and
  SMSPVA) depending on the service. The full flow can be tested with
  the free signup credits, or with no credits at all via the free
  email tier.

  EASIEST PATH — NO CREDITS NEEDED (temporary email):
  1. Tap "Sign in with Apple" on the welcome screen.
  2. On the Home tab, switch the toggle from "Numbers" to "E-mails".
  3. Pick any service, then choose the outlook.com or hotmail.com
     domain — both are FREE (up to 3 per day, per account).
  4. Tap to create the address. It is usable immediately.
  5. Use that address to sign up on the corresponding website. The
     verification code appears in the app when it arrives.

  SMS PATH (uses the free signup credits):
  1. On the Home tab, keep the toggle on "Numbers".
  2. Tap the Service picker and choose a 1-credit route — current
     examples: TikTok + Philippines, Twitter/X + Colombia, or
     LinkedIn + Indonesia.
  3. Tap "Get number" in Checkout.
  4. The Waiting screen shows the assigned phone number with a live
     8-minute reservation timer.
  5. To exercise the receive path, text any code from another device
     to the displayed number; the OTP screen appears with the code.
     Alternatively tap "Check now".
  6. If no SMS arrives within 8 minutes, the credits are refunded
     automatically. Cancelling is available after a 3-minute hold,
     and also refunds.

  NOTE ON DELIVERY: these are real third-party numbers, so a given
  service may decline a given number and no code arrives. That is the
  expected failure mode and it is always refunded — it is not a bug in
  the app. If one route does not deliver, please try another.

  TO TEST IN-APP PURCHASE (sandbox):
  Account tab → Top up → pick a pack → confirm purchase with a
  sandbox Apple ID. The credits will be added to the wallet
  immediately upon server-side receipt verification.

  TO TEST ACCOUNT DELETION (Guideline 5.1.1(v)):
  Account tab → scroll to "Danger zone" → tap "Delete account" →
  confirm in the dialog. This deletes the auth user, profile,
  wallet, order history, and any pending SMSPVA reservations.

  Privacy Policy, Terms of Use, Refund Policy, and Help Center are
  all linked from Account → Legal / Support and open in Safari.
```

---

## App Privacy (nutrition labels)

Configure under App Privacy → Get Started:

| Data type        | Linked to user | Used for tracking | Purpose            |
|------------------|----------------|-------------------|--------------------|
| Email address    | Yes            | No                | App Functionality  |
| User ID          | Yes            | No                | App Functionality  |
| Purchase history | Yes            | No                | App Functionality  |
| Device ID (APNs) | Yes            | No                | App Functionality  |
| Crash data       | No             | No                | App Functionality  |

Everything else: **No, we don't collect data of this type.**

---

## Age rating

Self-declare **17+** to align with the Terms of Use age requirement.
For the questionnaire, all checkboxes are "None" / "No" — there's
no mature content in the app itself.

---

## Content Rights

```
Does your app contain, display, or access third-party content?
  → No
```

(Service catalog logos load at runtime from Clearbit / Google
FaviconV2 APIs — they are not bundled with the app, and the
catalog itself is functional integration data, not creative content.)

---

## Export Compliance

```
Does your app use encryption?
  → Yes (standard HTTPS / TLS via system frameworks)

Does it qualify for the exemption in Category 5, Part 2 of the EAR?
  → Yes (uses only standard encryption built into iOS)
```

---

## ASO post-launch monitoring

Once live, watch these signals in App Store Connect → Analytics:
- **Impressions** → search visibility for your keywords
- **Conversion rate** → are screenshots + name compelling enough
- **Source = Search** → how many installs come from organic search

If conversion is low (<2%), iterate on the first 2 screenshots
(they're 80% of conversion impact) before touching keywords.
If impressions are low for a specific query (e.g. "burner number"),
test moving that word from the keywords field into the subtitle —
subtitle weight is ~2x keywords field.

You can change Name, Subtitle, Promotional text, and Keywords on
every release without a content review.
