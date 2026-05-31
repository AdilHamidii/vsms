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
Name (30 chars):       vSMS: Temp SMS & Verify Codes
Subtitle (30 chars):   Receive OTP, Codes & Texts
```

Char counts: name 29, subtitle 26 — both well under the 30 cap.

**Indexed via these two surfaces** (anything searchable here doesn't
need to be in the keywords field):
`vsms · temp · sms · verify · codes · receive · otp · code · texts`

**Why this beats your draft:** "Verification" is the long form of the
verb users actually search ("verify"), and "Codes" matches both
"code" (singular) and "codes" (plural). Adding "OTP" to the subtitle
captures one of the highest-volume queries in the category without
spending characters in the keywords field.

---

## Keywords (100 chars, comma-separated, NO spaces around commas)

```
number,virtual,burner,2fa,phone,private,signup,inbox,online,international,anonymous,sim,activation
```

Char count: 99.

**Indexed via this field** (chosen to complement Name + Subtitle):
- `number` — covers "phone number", "virtual number", "temp number"
- `virtual` — pairs with "number", high-volume
- `burner` — category synonym, captures search intent
- `2fa` — top-tier query, short
- `phone` — pairs with "verify", "number"
- `private` — privacy-positioning query
- `signup` — captures "sign up sms", "signup verification"
- `inbox` — captures "sms inbox"
- `online` — pairs with "sms" for "receive sms online"
- `international` — captures global-numbers searches
- `anonymous` — pairs with "number"
- `sim` — captures "second sim", "virtual sim"
- `activation` — captures "account activation"

**Deliberately NOT included** (covered elsewhere or risky):
- ❌ `sms`, `otp`, `verify`, `verification`, `code`, `codes`, `receive`, `temp` — already in Name or Subtitle
- ❌ `whatsapp`, `telegram`, `tinder`, etc. — brand-name keywords get rejected under 5.2.1
- ❌ `fake` — signals fraud, increases rejection risk under 4.3
- ❌ `free` — app isn't free, dilutes conversion

---

## Promotional text (170 chars — editable any time without resubmit)

```
Rent a temporary phone number, receive your verification SMS in seconds, done. 60+ countries. Pay only for what you use — credits never expire.
```

Char count: 145.

Promotional text appears at the very top of the description, above the
"more" fold. Use it for time-sensitive callouts later (e.g.,
"Now supporting xx countries", "Holiday discount", etc.).

---

## Description (4000 chars max — first ~170 chars visible without "more" tap)

```
vSMS gives you a clean, calm iOS app for receiving SMS verification codes on temporary phone numbers — without giving up your real number.

Protect your real number from spam, data breaches, and marketing lists. Get a fresh number for any service that accepts SMS, receive the code in seconds, and move on.

WHAT IT DOES
• Pick a country and service from a curated list of 200+ destinations
• Tap once to rent a fresh number — no setup, no commitments
• Receive your SMS automatically — one-tap copy
• See exactly how long is left before the number expires
• Auto-refund in credits if no code arrives within 20 minutes

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
• 12 credits — $5.99 (best value per credit)
• 30 credits — $12.99

Different routes cost different amounts of credits depending on the service and country (1 credit for popular routes, up to 100+ for premium long-haul numbers). The exact cost is shown before you confirm — never charged a hidden fee.

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
                account is automatically granted 1 free credit, which
                is enough to complete a low-cost route end-to-end
                without an in-app purchase.

Review Notes:
  vSMS rents temporary phone numbers and delivers SMS verification
  codes via the SMSPVA infrastructure provider. The full flow can be
  tested with the free signup credit.

  TO TEST WITHOUT PAYING:
  1. Tap "Sign in with Apple" on the welcome screen.
  2. You will receive 1 free credit automatically.
  3. On the Home tab, tap the Service picker, then pick any service
     priced at 1 credit (most services in low-cost countries qualify
     — try Discord + Indonesia, for example).
  4. Tap "Get number" in Checkout.
  5. The Waiting screen displays the assigned phone number with a
     live 20-minute reservation timer.
  6. To exercise the SMS-receive path, text any code from another
     device to the displayed number. Within ~1 minute the OTP
     screen will appear with the received code. Alternatively, tap
     "Check now" repeatedly.
  7. If no SMS arrives in 20 min, the credit is auto-refunded.

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
