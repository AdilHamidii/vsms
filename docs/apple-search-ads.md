# Apple Search Ads — state, economics, and the one lever that works

*Verified live against the API on 2026-08-17. Every figure here was read from
the account or computed from this app's own receipts, not recalled.*

Tooling: `scripts/asa.py` (see its docstring for setup). Credentials live in
`~/.searchads/config.json`; the private key is at `/Users/adyl/private-key.pem`
and is **not** the one in `~/.searchads/` — that file is a different, unused
pair, and pointing at it fails with `invalid_client`. Run with
`ASA_PRIVATE_KEY=/Users/adyl/private-key.pem`.

> ⚠️ macOS TCC blocks headless processes whose cwd is under `~/Desktop`.
> Run from `/Users/adyl`.

## Account

`orgId 22495890` ("Adil Hamidi"), EUR, role API Campaign Manager.
App `adamId 6774768570`.

| campaign | id | state |
|---|---|---|
| **vSMS EN** | `2144317663` | **ENABLED / RUNNING, US only, €20/day** |
| vSMS EU | `2144209783` | PAUSED (2026-08-17) |
| vSMS LATAM | `2144318785` | PAUSED |
| MedVault PROBE | `2144343399` | PAUSED (different app) |

Ad groups under vSMS EN: `2149912993` "vSMS EN main" (32 exact keywords) and
`2150336740` "Automated" (Search Match, 4 taps / 0 installs lifetime).

## The economics, and they are tight

From this app's own receipts: **$232.59 net over 14 buyers**, and **6.9% of
signups buy**. So an install is worth **$1.15 ≈ €1.06**, and that is the
breakeven CPA. Nothing about the ad account changes this number — the way to
move it is to make more installers buy, not to bid differently.

Measured 30 days to 2026-08-17, per country:

| | taps | installs | CR | spend | CPA |
|---|---|---|---|---|---|
| **US** | 246 | 105 | 42.7% | €151.96 | **€1.45** |
| FR | 15 | 11 | 73.3% | €6.27 | €0.57 |
| DE | 12 | 7 | 58.3% | €4.67 | €0.67 |
| SE | 8 | 6 | 75.0% | €3.59 | €0.60 |
| UA | 8 | 5 | 62.5% | €2.09 | €0.42 |

🔴 **The US is the worst market in the account and Europe was subsidising it.**
US converts at 42.7% against Europe's 58–75%, and costs 2–3× more per install.
Concentrating on the US at €20/day is an owner decision taken with this table
in view (2026-08-17); it is not what the data would choose on its own. If
volume matters more than margin, un-pausing vSMS EU is one call and it ran at
€1.04 — essentially breakeven — while delivering 121 of the account's 175
installs.

## 🔴 The only lever is keywords — there is no bid knob

The ad group runs `biddingStrategy: MAX_CONVERSIONS`. Two things follow, and
both were learned by trying:

- `defaultBidAmount` is `0` and **per-keyword bids are ignored**. A bulk bid
  PUT returns **HTTP 200 and changes nothing** — `modificationTime` does not
  move. That silent success is the trap; verify against `modificationTime`,
  never the status code.
- **`cpaGoal` cannot be set either**: HTTP 400 `"cpaGoal must be null for
  adgroups under Max Conversions Campaign"`.

So CPA is controlled by **daily budget, geo, and which keywords and negatives
exist** — nothing else. Regaining a bid knob means switching the campaign to
`FIXED_BID`, which discards Apple's accumulated learning; that is an owner
decision, not a tuning step.

**The campaign is not budget-limited.** The US spent ~€5/day against the old
€50 cap. The €20 cap is a guard rail; it will not by itself increase delivery.

## Keyword record — the input to the rewrite

Only 7 of the 32 keywords have ever taken a tap. CPA is the decision variable,
not conversion rate: `text verification` converts at 50% and still lost money.

| keyword | taps | CR | CPA | |
|---|---|---|---|---|
| `sms virtual` | 96 | 36% | **€1.61** | **70% of all taps — the money leak** |
| `temp number` | 21 | 52% | **€1.00** | the one clear winner |
| `temp sms` | 11 | 46% | €1.36 | 1.3× breakeven on real volume |
| `sms verification` | 3 | 33% | €1.41 | tiny sample |
| `text verification` | 2 | 50% | €1.35 | tiny sample |
| `throwaway number` | 2 | 50% | **€0.57** | cheapest in the account, n=2 |
| `receive sms` | 2 | — | — | 0 installs |

The other 25 keywords have zero impressions — including `otp`, `non voip
number`, `second number`, `verification code`, `burner number`. They are not
failing; they are not being served. Under MAX_CONVERSIONS that is Apple's
choice, which is another reason the keyword SET is the lever.

## Negatives — one trap

Navigational brand terms must be blocked as **EXACT, never BROAD**. A broad
negative on `whatsapp` also blocks **"whatsapp verification number"**, which is
the highest-intent query this product has; broad `google voice` blocks "google
voice alternative", a user actively shopping for what we sell. `NEGATIVES` and
`NEGATIVES_EXACT` in `scripts/asa.py` are split for exactly this reason.

No negatives are live on the account yet.

## Why paid search at all

App Analytics exposes **no per-query search terms** (`Source Info` is empty on
all 650 rows), so organic keyword work is before/after inference only. Search
Ads reports the actual query. At current economics the durable return on this
spend is that query list, which then goes into the 100-character keyword field
where it costs nothing forever.

## Still open

- **The keyword set has not been rewritten.** `optimize-us` carries a
  `NEW_KEYWORDS` list and a negatives list, both gated behind omitting
  `--no-keywords`; neither has been applied. The rewrite is to be done against
  real keyword-volume data rather than a guess.
- **`sms virtual` is still live at 1.5× breakeven** and still taking 70% of
  taps. It is the single biggest change available and was left alone
  deliberately, because removing the volume driver belongs in the same decision
  as what replaces it.
- The `Automated` (Search Match) ad group has produced 0 installs from 4 taps.
  Too small to judge; it is the only query-discovery surface, so it was kept.
