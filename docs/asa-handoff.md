# Handoff — Apple Search Ads keyword rewrite (paste this into the new session)

*Written 2026-08-17. Everything below was verified live against the API that
day. The full account write-up is `docs/apple-search-ads.md`; this file is the
short version plus the exact task.*

---

## Task

Rewrite the keyword set of the vSMS US Search Ads campaign, using the ASO MCP
for real keyword-volume data plus the past ads performance below.

## What is already done — do not redo it

- **One active campaign**: vSMS EN `2144317663`, **US only, €20/day**,
  ENABLED/RUNNING. vSMS EU `2144209783`, LATAM `2144318785` and MedVault PROBE
  `2144343399` are all PAUSED.
- The ad group's `endTime` was set to 2026-08-19 (it would have gone dark
  silently, as vSMS EU already had). **Cleared, verified `null`.**
- Tooling exists: `scripts/asa.py` on branch `worktree-apple-search-ads`.

## Setup to run anything

```bash
cd /Users/adyl    # macOS TCC blocks headless processes under ~/Desktop
ASA_PRIVATE_KEY=/Users/adyl/private-key.pem python3 \
  ~/Desktop/IOS_APPS/VirtualSIM/scripts/asa.py doctor
```

Commands: `doctor`, `campaigns`, `adgroups <cid>`, `keywords <cid> <gid>`,
`report [days]`, `optimize-us [--no-keywords] [--yes]`, `budget <cid> <eur>`.
Write commands dry-run unless given `--yes`.

⚠️ The private key is `/Users/adyl/private-key.pem`. The file at
`~/.searchads/private-key.pem` is a **different, unused pair** and fails with
`invalid_client`. `~/.searchads/config.json` holds the clientId/teamId/keyId.

IDs: org `22495890` (EUR) · app adamId `6774768570` · campaign `2144317663` ·
ad groups `2149912993` ("vSMS EN main", 32 exact keywords) and `2150336740`
("Automated", Search Match).

---

## 🔴 The three constraints that decide the rewrite

**1. There is no bid knob.** The ad group is `biddingStrategy:
MAX_CONVERSIONS`. `defaultBidAmount` is 0, per-keyword bids are **ignored** (a
bulk bid PUT returns **HTTP 200 and changes nothing** — check
`modificationTime`, never the status code), and `cpaGoal` is rejected with
*"cpaGoal must be null for adgroups under Max Conversions Campaign"*.
**CPA is controlled by the keyword set, the negatives, the geo and the budget —
nothing else.** Getting a bid knob back means switching to `FIXED_BID`, which
discards Apple's learning; that is an owner decision, not a tuning step.

**2. Breakeven CPA is €1.06, and it is tight.** From the app's own receipts:
$232.59 net over 14 buyers, and 6.9% of signups buy → an install is worth
$1.15. The US ran at **€1.45**, i.e. ~37% underwater.

**3. It is not budget-limited.** The US spent ~€5/day against the old €50 cap.
Raising budget does nothing on its own.

---

## The data to rewrite against

**Per country, 30 days to 2026-08-17:**

| | taps | installs | CR | spend | CPA |
|---|---|---|---|---|---|
| **US** | 246 | 105 | 42.7% | €151.96 | **€1.45** |
| FR | 15 | 11 | 73.3% | €6.27 | €0.57 |
| DE | 12 | 7 | 58.3% | €4.67 | €0.67 |
| SE | 8 | 6 | 75.0% | €3.59 | €0.60 |
| UA | 8 | 5 | 62.5% | €2.09 | €0.42 |

**Per keyword (only 7 of the 32 have ever taken a tap).** CPA decides, not
conversion rate — `text verification` converts at 50% and still lost money:

| keyword | taps | CR | CPA | |
|---|---|---|---|---|
| `sms virtual` | 96 | 36% | **€1.61** | **70% of all taps — the money leak** |
| `temp number` | 21 | 52% | **€1.00** | the one clear winner |
| `temp sms` | 11 | 46% | €1.36 | 1.3× breakeven on real volume |
| `sms verification` | 3 | 33% | €1.41 | tiny sample |
| `text verification` | 2 | 50% | €1.35 | tiny sample |
| `throwaway number` | 2 | 50% | **€0.57** | cheapest in the account, n=2 |
| `receive sms` | 2 | — | — | 0 installs |

The other 25 keywords have **zero impressions** — including `otp`, `non voip
number`, `second number`, `verification code`, `burner number`, `fake number`,
`private number`. They are not failing; Apple is not serving them. Worth
understanding why before adding more.

---

## Decisions to make in the new session

1. **`sms virtual`** — 70% of taps at 1.5× breakeven. Biggest single lever.
   Left alone deliberately, because removing the volume driver only makes sense
   alongside whatever replaces it. Use MCP volume data to find that replacement
   first.
2. **Which of the 25 zero-impression keywords to keep.** A keyword Apple never
   serves is not free — it dilutes the ad group.
3. **Negatives — none are live yet.** `scripts/asa.py` has them split
   `NEGATIVES` (broad: free, hack, prank, call recorder, reverse lookup…) and
   `NEGATIVES_EXACT` (navigational brands). **Keep that split.** A *broad*
   negative on `whatsapp` also blocks **"whatsapp verification number"**, the
   highest-intent query this product has; broad `google voice` blocks "google
   voice alternative", a user actively shopping for what we sell.
4. **Whether to un-pause vSMS EU.** Owner chose US-only on 2026-08-17 with the
   country table above in view. Worth re-stating: Europe converted at 58–75%
   vs the US's 42.7%, cost €0.42–0.71 vs €1.45, and delivered **121 of the
   account's 175 installs**. The US is the worst market in the account and
   Europe was subsidising it. One call to reverse.

## Applying the rewrite

`optimize-us` already carries `NEW_KEYWORDS` and the negatives, gated behind
omitting `--no-keywords`. **Replace that list with the MCP-informed one rather
than running it as-is** — it was written from intuition before the account data
came back, and it is largely redundant with the 25 keywords already present.

Always dry-run first (no `--yes`), and verify with `keywords 2144317663
2149912993` plus `modificationTime` — this account returns HTTP 200 for writes
it silently ignores.

## Wider context worth carrying in

Search is this app's **entire** acquisition channel — 20,884 impressions and
all 143 organic downloads came from App Store search, zero browse, zero
referral. App Analytics exposes **no per-query search terms** (`Source Info` is
empty on all 650 rows), so paid search is the only way to learn which queries
convert. At these economics the durable return on the spend is that query list,
which then goes into the 100-character keyword field where it is free forever.

Organic US benchmark: **2.45% impression→tap, 68.4% tap→install**. Paid taps
converting well below 68% mean the keyword is off-intent, not that the product
page is broken.

See also the `aso-listing` skill for the listing itself. Note the live US app
name is **`vSMS: Second Number & Temp SMS`**, which does *not* match what
`docs/app-store-listing.md` records — that file has drifted; read ASC.
