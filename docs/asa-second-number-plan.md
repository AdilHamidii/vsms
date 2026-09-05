# Apple Search Ads — the second-number campaign (plan, 2026-09-05)

*Every figure below was read from the ASA API, the aso-connect keyword scorer
or the app's own database on 2026-09-05. Nothing is recalled from memory.*

Owner brief: stop buying "temp sms" intent, buy **second-number** intent,
€20/day, EU + US, optimise for **subscriptions**, cheap installs.

Tooling: `scripts/asa.py`, run from `/Users/adyl` with
`ASA_PRIVATE_KEY=/Users/adyl/private-key.pem` (the key in `~/.searchads/` is a
different pair and fails `invalid_client`). Every write command dry-runs
unless `--yes` is passed, and every write must be READ BACK — this account
returns HTTP 200 for writes it ignores.

---

## 1. What the account looks like today

| campaign | state | why not serving | 30d |
|---|---|---|---|
| vSMS EN `2144317663` (US) | PAUSED | paused by user | 634 impr · 50 taps · 22 installs · €30.47 · **CPA €1.38** |
| vSMS EU `2144209783` (29 countries) | PAUSED | ad group `2149602623` end date reached | 81 impr · 9 taps · 6 installs · €3.62 · **CPA €0.60** |
| vSMS LATAM | PAUSED | paused by user | 0 |
| vRoam ×5 (the eSIM app) | ENABLED, €46/day | — | **0 impressions in 30 days** |
| MedVault ×4 | PAUSED | — | 0 |

🔴 **Gate zero: five ENABLED vRoam campaigns with €46/day of budget served
ZERO impressions in 30 days.** That is not a keyword problem; it is the shape
of an account that is not being billed. The vSMS campaigns went dark "1 day in
3" in August for the same reason, and Apple exposes no billing endpoint. **Fix
the card at ads.apple.com → Settings → Billing before anything below is
created**, or €20/day becomes €0/day with every campaign reading RUNNING.

The US ad group is `MAX_CONVERSIONS`: no bid knob, no cpaGoal. The 36 keywords
are all temp-SMS intent (`temp sms`, `sms virtual`, `receive sms`, …) with the
second-number terms **paused** since the 08-18 rewrite. It stays paused; the
new campaigns below are built with fixed CPT bids so a keyword can actually
be steered.

## 2. What the product converts to today — the honest numbers

**Attribution** (`attribution_summary()`, Production receipts): 705 organic
installs → 18 credit buyers (2.6%). 8 ASA-attributed installs → 0 buyers. Too
small to say anything about ASA yet; it only proves the pipe works.

**The line** (`line_subscriptions`, lifetime, all USA storefront):

| | |
|---|---|
| subscriptions started | 16 |
| $0 yearly trials (Aug 15–24) | 10 — every one expired or in grace, **all three $99.99 charges declined**, $0 collected |
| paid | 6: one $9.99 monthly (08-17, still active, renewal off), one $99.99 yearly (08-20, **refunded**), four $5.99 monthlies (09-04 ×2, 09-05 ×2; 3 of 4 auto-renew ON) |
| gross actually kept | ≈ $33.95 |
| renewals ever | 1 (`DID_RENEW`) |
| signup → purchase | 0–15 minutes, every time |
| inbound messages per line | median 1; most lines 0 or 1 |

US signups since the line launched (08-10): 214. So ~7.5% of US signups
*start* a subscription and ~2.8% pay. But **the Number store was refusing
every country for most of 08-28 → 09-03 and for three hours on 09-05** (see
CLAUDE.md, "THE STORE WAS DARK") — so the 2.7 numbers are not a measurement,
and the four $5.99 monthlies landed in the 30 hours the store was actually
working. **We do not know the line's conversion rate yet.** That is the
strongest argument for a bounded test and the strongest argument against
calling it a killing in advance.

**Unit economics per paid monthly**, net of Apple 15% and Telnyx ($1 upfront +
$1/mo): month 1 ≈ **+$3.09**, each renewal ≈ **+$4.09**. With one renewal ever
recorded, the defensible LTV today is **~$3–5**. A yearly ($59.99 → ~$51 net,
$13 rent) is worth ~$38 — the only SKU that pays for a paid install on its
own, and the one the trial data says this audience does not complete.

**Breakeven per install** at a *hoped-for* 5% paid-monthly conversion with
1.5 months' life ≈ $0.35, plus ~$0.18 of credit-pack revenue ≈ **$0.53 ≈
€0.49**. The US ran at €1.38, Europe at €0.60. **At today's conversion the
campaign loses money in both markets.** It becomes profitable only if
second-number intent converts several times better than temp-SMS intent did —
which is plausible (the product now leads with WhatsApp, the store works, the
paywall is one tap from the number) and is exactly what this spend should
measure.

## 3. Where to spend — EU vs US

| | tap→install | CPA | what a US number is to them |
|---|---|---|---|
| US | 42.7% | €1.38–1.45 | their own second number: calls, texts from US senders, WhatsApp |
| FR/DE/ES/IT/SE | 58–75% | €0.42–0.67 | **a WhatsApp number only** — the line receives from US/CA senders, so a French SMS never arrives |

Europe is cheaper and converts to install better, but the product is narrower
there: the ONLY honest EU pitch is *"a US number to verify a second WhatsApp
(or WhatsApp Business)"*. That is a real, searched intent — and the keyword
data says it is the cheapest intent in every EU storefront:

| storefront | keyword | pop | diff | class |
|---|---|---|---|---|
| de | zweite whatsapp nummer | 40 | 34 | **Sweet Spot** |
| de | temporäre nummer | 41 | 29 | **Sweet Spot** |
| de | virtuelle nummer | 70 | 48 | Good Target |
| fr | deuxième numéro whatsapp | 41 | 34 | **Sweet Spot** |
| fr | numéro virtuel | 71 | 50 | Good Target |
| fr | second numéro / deuxième numéro | 63 / 61 | 48 | Good Target |
| es | segundo número whatsapp | 39 | 33 | easy |
| es | número virtual / recibir sms | 56 / 65 | 43 / 48 | Good Target |
| it | numero temporaneo whatsapp | 31 | 28 | easy |
| it | numero virtuale / secondo numero | 65 / 61 | 48 / 46 | Good Target |
| gb | second phone number / receive sms | 78 / 74 | 53 / 44 | Good Target |
| us | second phone number | **92** | **73** | Hard — TextNow/TextFree/Burner own it |
| us | second number for whatsapp | 63 | 66 | Hard |
| us | receive sms | 83 | 56 | best US opportunity, but it is temp-SMS intent |

Generic "second number" in the EU (`deuxième numéro`, `zweite nummer`) is
tempting on price but **off-product**: a French user wanting a second French
line installs, sees "US or Canadian number", and leaves. Keep those out until
the WhatsApp set has data.

## 4. The campaigns

Two new campaigns, **fixed CPT bids** (`pricingModel: CPC`, per-keyword
`bidAmount`), Search Results placement only, EXACT match, every write read
back. The old EN/EU campaigns stay paused as the temp-SMS control.

### A · "vSMS Number US" — US only — **€10/day**

| ad group | bid | keywords |
|---|---|---|
| **WhatsApp** | €0.90 | second number for whatsapp · virtual number for whatsapp · whatsapp number · number for whatsapp business · whatsapp verification number |
| **Second number** | €0.80 | second phone number · second number · 2nd phone number · burner number · burner phone · temporary phone number · virtual phone number · private number · us phone number · canada phone number · phone number app |
| **Conquest** (brands) | €0.45 | burner · hushed · textnow · text free · 2ndline · sideline · line2 · phoner · dingtone · talkatone · google voice alternative |

Expect €0.7–1.0 CPT, ~45% tap→install → **CPI ≈ €1.6–2.2, ~5–6 installs/day.**
"second phone number" is difficulty 73 with TextNow (918k ratings) and
TextFree (601k) above the fold; at €0.80 we will lose most auctions on it and
win the long tail. That is intended — the cap is the daily budget, not volume.

### B · "vSMS WhatsApp EU" — DE, FR, ES, IT, NL, GB — **€10/day**

| ad group | bid | keywords |
|---|---|---|
| **DE** | €0.45 | zweite whatsapp nummer · virtuelle nummer whatsapp · whatsapp nummer · virtuelle nummer · temporäre nummer · us nummer |
| **FR** | €0.45 | deuxième numéro whatsapp · numéro virtuel whatsapp · numéro whatsapp · numéro virtuel · numéro temporaire · numéro jetable |
| **ES** | €0.40 | segundo número whatsapp · número virtual whatsapp · número whatsapp · número virtual · número temporal · recibir sms |
| **IT** | €0.40 | secondo numero whatsapp · numero virtuale whatsapp · numero temporaneo whatsapp · numero virtuale · numero temporaneo · ricevere sms |
| **EN-intl** (GB, NL) | €0.50 | second number for whatsapp · virtual number for whatsapp · whatsapp number · virtual number · us phone number · second phone number |

Expect €0.35–0.50 CPT, ~65% tap→install → **CPI ≈ €0.55–0.75, ~14 installs/day.**
NL searches in English often enough to ride the EN-intl group; Dutch terms
can be added once a Dutch query shows up in the search-terms report.

### Negatives (campaign level, both campaigns)

BROAD: free · free sms · free phone number · unlimited free · gratis · hack ·
spoof · prank · prank call · fake call · call recorder · ringtone · caller id
· reverse lookup · phone number lookup · number tracker · track phone · spy ·
esim · data plan (the last two keep vSMS out of vRoam's auctions).
EXACT only: whatsapp · telegram · google voice · textnow · hushed · burner app
— **never broad**: a broad `whatsapp` kills "whatsapp verification number",
the highest-intent query we have.

### Budget

€20/day = €600/month, split 50/50 for the first 14 days, then re-split by
**cost per paid subscription**, not by CPI. A cheap EU install that never
subscribes is worth exactly nothing.

## 5. Measurement — what decides anything

The install → subscription join did not exist before today.
`attribution_summary()` now also returns **`line_subs`** and **`line_paid`**
per (campaign, keyword) (migration `20260905120000`), read from
`line_subscriptions` — so the question "which keyword bought a subscriber" is
one query:

```sql
select * from public.attribution_summary() where attributed order by installs desc;
```

Read it every Monday next to `scripts/asa.py report 7`. Rules, written down
now so they are not negotiated later:

| after | keyword rule |
|---|---|
| ≥ 15 taps | pause if tap→install < 40% (US) / < 55% (EU) — off-intent, not a page problem |
| ≥ 25 installs | pause if `line_subs` = 0 |
| 14 days | move budget toward the campaign with the lower **€ per paid sub**; if neither has a paid sub from ≥ 150 installs, halve to €10/day |
| 30 days | **stop** unless ≥ 1 paid sub per €25 spent (that is CPA ≈ 4× first-month margin — the most a month-2 renewal rate we have not measured could justify) |

The ASA search-terms report is the other return on this spend: it is the
only place Apple shows the actual query, and every converting query goes into
the 100-character keyword field where it is free forever.

## 6. The levers that change the math (product, not ads)

Ads cannot fix a €0.49 breakeven. These can, and each is a small release:

1. **Yearly at checkout, framed against monthly** — $59.99 vs 12 × $5.99 =
   $71.88 saves 17%; it is the only SKU worth a paid install. It exists; the
   picker shows it; it is not argued for. Trial stays OFF (3 of 3 trial
   conversions declined at $99.99).
2. **Month-2 retention** is the whole LTV. Median usage is one inbound
   message. The 2.9 pitch ("Great for WhatsApp") and the swap picker are the
   right direction; the next signal is whether the four 09-04/05 monthlies
   renew on 10-04/05. Do not scale spend before that date.
3. **A Custom Product Page per intent** (ASA supports up to 35): a WhatsApp
   CPP for the WhatsApp ad groups whose first screenshot is the code landing
   in the app. The current page leads with temp SMS.
4. **The Number tab as first tab for ASA-attributed installs** is not possible
   (attribution resolves after boot), but the store is already reachable in
   one tap and now works.

## 7. Executed 2026-09-05 (owner: "billing fixed, go ahead with both")

`scripts/asa.py create-number-campaigns --yes` created, and read back:

| campaign | id | ad groups | keywords | state |
|---|---|---|---|---|
| vSMS Number US | **2144619440** | `2150866068` WhatsApp · `2150867040` Second number · `2150865771` Conquest | 27 | ENABLED / RUNNING, €10/day |
| vSMS WhatsApp EU | **2144617614** | `2150866615` DE · `2150867343` FR · `2150867590` ES · `2150866468` IT · `2150865817` EN intl | 30 | ENABLED / RUNNING, €10/day |

Every keyword count read back equal to what was sent; negatives 20 broad + 6
exact per campaign. The old vSMS EN / EU campaigns remain PAUSED as the
temp-SMS control.

Next: day 1 confirm impressions > 0 on both (`report 1`) — if zero, it is
billing again, not keywords; day 7 and 14: the rules in §5; day 30: stop or
scale, on **€ per paid subscription** only (`attribution_summary()`).

Not doing: touching the paused temp-SMS campaigns (they are the control),
Search Match / Search Tab (awareness placements with no query behind them),
LATAM, or any bid above €1.00.
