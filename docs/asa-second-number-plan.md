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

> **Bids below are the LAUNCH values and are superseded.** At €0.40–0.90 the
> whole account won 6 auctions in its first day (all US, 0 taps, €0), so on
> the evening of 2026-09-05 the owner raised bids across all 7 enabled
> vRoam + vSMS campaigns (15 ad groups, 506 keywords — ad-group default and
> every keyword, read back), **tiered by intent**: US Second-number +
> WhatsApp €1.50 · vRoam exact (Destinations, Buy intent, Problem-aware, EU
> destinations) €1.20 · EU WhatsApp DE/FR/ES/IT/EN-intl €1.00 · US Conquest
> €0.80 · vRoam broad seeds + Search-match research €0.70 · vRoam Brand
> €0.50. Rationale: second-price auction means the max rarely binds on cheap
> terms, but broad/discovery groups at a high max buy irrelevant taps fast,
> and competitor-brand searches convert worst. Daily budgets are unchanged
> and remain the hard cap. Read live bids with `asa.py keywords <c> <g>`;
> the tables keep the launch numbers only to record the reasoning.

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
or LATAM. ~~any bid above €1.00~~ — superseded 2026-09-05: bids are €1.50
(see the note under §4); the €10/day budgets, not the bid, are the cap.

Also learned day 1: Search Results campaigns take **no ad objects** — an
empty `…/ads` list is normal and is NOT why impressions are zero. Zero
delivery on a `RUNNING` campaign with no `servingStateReasons` is bids/age.

## 8. Day-2 read (2026-09-06) and the "US number" cluster

Read from the API, not the dashboard — the Apple Ads web UI lagged the API
by most of a day on 09-06 (it showed 132 impressions / 1 tap / €0.62 for
vSMS Number US while the API and `install_attributions` both said 388 / 15 /
11 installs / €15.12). **Always read `report 1` and the keyword report; the
dashboard's "Last 7 days" excludes today.**

- 09-05 (bids raised in the evening): 63 impressions, 0 taps. **09-06: 325
  impressions, 15 taps, 11 installs, €15.12** — on a €10/day budget. So
  delivery is BUDGET-capped, not bid-capped: adding keywords redistributes
  the same €10, it does not raise impressions. More impressions = more
  budget, and that decision waits on € per paid sub (§5).
- CPT €1.01, tap→install 73% (organic is 68%), CPA €1.37 — 2.8× the €0.49
  breakeven at a hoped 5% sub conversion. Expensive for OUR economics, not
  for the market (US clears €1.50–4.00 on these terms).
- Where the money went: the Second-number group converted **9 taps → 9
  installs** (€10.99, CPA €1.22); Conquest took **285 of 388 impressions**
  for 2 installs (€4.10) — `text free`, `line2`, `hushed`, `sideline` are 83
  impressions / 0 taps (people typing an app's name want that app). Too
  early to kill (§5 says day 7), but this is where budget goes to die.
- 7 US installs attributed in our DB: 3 reached the line checkout, 2 hit
  Apple's sheet and **cancelled**, 0 subscribed (n=7, hours old).
- `us phone number` (in both campaigns since 09-05) has **0–1 impressions**.
  Two causes, both fixable: the keyword is alone in its cluster, and the
  listing carries no `usa`/`american` anywhere until 2.10's subtitle ships
  (keyword field still lacks `usa` — add on 2.11; Apple's ad relevance is
  the organic relevance).

**The cluster, scored (App Store popularity, 0–100):** US storefront — us
phone number 63, us number for whatsapp 64, get us number 62, us number 61,
usa number 61, american number 61, fake us number 61, us mobile number 60,
us virtual number 59, american phone number 58, usa number for whatsapp 58,
temporary us number 56, usa phone number 54, united states phone number 53.
GB — us number 52, us phone number 52, american number 50, usa number 47.
DE — usa nummer 51, us nummer 43, us telefonnummer 42 (amerikanische
nummer **0**). FR — numéro usa 50, numéro us 48 (numéro américain **0**).
ES — número usa whatsapp 47, número usa 41 (número americano 7). IT —
numero usa 57, numero usa whatsapp 51, numero americano 33.

**APPLIED 2026-09-06 evening (owner: "go, add all the keywords" and
"unlimited budget, I just need more impressions"):** all 30 keywords below
are live and read back (US 22 + 7, EU 14 / 8 / 8 / 8 / 9). Daily budgets
raised **€10 → €50 (US) and €10 → €30 (EU)**; EU EN-intl/DE/FR/ES/IT bids
**€1.00 → €1.30** on the group default and every active keyword; **US
groups stay at €1.50** (they were pushed to €2.00 for ~20 minutes and
reverted the same evening — owner: "2 euro bids are a bit too high"; the
budget raise alone removes the cap that actually bound, and at €1.50 the
Second-number terms cleared €0.99–1.45 per tap). Conquest stays €0.80. Read
back per keyword, zero mismatches. The old §5 kill rules still apply, and
"unlimited" is bounded by those two daily caps — raise again with `asa.py
budget <id> <eur> --yes` if `report 1` shows the cap being hit. Nudge US
bids in €0.25 steps ONLY if spend sits well under €50 with impressions flat
(the rank-capped signature).
The seven calls as run (`add-keywords` is EXACT, dedupes against what is
live, dry-run without `--yes`, reads back):

```
asa.py add-keywords 2144619440 2150867040 1.50 "us number,usa number,usa phone number,american number,american phone number,us virtual number,us mobile number,united states phone number,temporary us number,get us number,fake us number"
asa.py add-keywords 2144619440 2150866068 1.50 "us number for whatsapp,usa number for whatsapp"
asa.py add-keywords 2144617614 2150865817 1.00 "us number,usa number,usa phone number,american number,american phone number,us virtual number,us number for whatsapp,usa number for whatsapp"
asa.py add-keywords 2144617614 2150866615 1.00 "usa nummer,us telefonnummer"
asa.py add-keywords 2144617614 2150867343 1.00 "numéro usa,numéro us"
asa.py add-keywords 2144617614 2150867590 1.00 "número usa,número usa whatsapp"
asa.py add-keywords 2144617614 2150866468 1.00 "numero usa,numero usa whatsapp,numero americano"
```

Where the cluster really lives: a "US number" searcher INSIDE the US wants
a second line; OUTSIDE the US (the EU campaign) wants a US number for
WhatsApp — the exact product. Expect the EU half to be the cheaper one.

## 9. Day-3 read (2026-09-07): who the installs were, and the burner pause

Owner's question: "15 downloads from ASA yesterday, nobody ordered the US
number they came for — why?" Answered from `install_attributions` joined to
`app_events`, not from ASA alone. API figures: **12 installs on 09-06 +
6 on 09-07 (US campaign), 0 from EU** (15 taps / 3 EU taps).

**Nobody came for a US number.** All 30 `us number / usa number / american
number` keywords had **0 impressions** in two days — the listing carries no
`usa`/`american` anywhere until 2.10's subtitle ships, so exact-match terms
get no relevance. The installs came from `burner number` 4, `burner phone`
4, `phone number app` 3, `textnow` 2, `virtual phone number` 2,
`2nd`/`second phone number` 2, `talkatone` 1 — two-way-texting, free-app
intent, which the product does not serve (no sending, no incoming calls).

Of 18 installs, **11 signed up** (the other 7 are invisible: the app shows
nothing before sign-in). Of the 11: **3 spent their free credits on a
temp-SMS code instead** (Home is the first tab; two landed on tiktok/CA),
**4 looked at the eight New York numbers and tapped none**, **3 reached
checkout**: 2 tapped Subscribe and cancelled at Apple's sheet within 11 s
and 30 s, and the one EU install (Italy, `número whatsapp`) was shown
TORONTO numbers by 2.9's storefront default and never tapped Subscribe.
The 30-second canceller had first searched the SMS catalog for "usa"
(`service_search_empty`), then hit a 21-credit WhatsApp paywall and opened
WhatsApp support twice. **Not the cause:** the store was up every time
(`line_numbers_shown count: 8`), catalog fresh, lines not paused, and the
sheet works — 4 organic users paid $5.99 on 09-04/05, one right after a
cancel. App-wide over the same 33 h: 59 store viewers → 29 checkouts →
7 Subscribe taps → 7 cancels (median 15 s) → 0 paid.

**APPLIED 2026-09-07 (owner: "pause the burner keywords"):** `burner`
(Conquest), `burner number` and `burner phone` (Second number) are
**PAUSED**, read back. The rest of Conquest (textnow, talkatone, hushed…)
is still live — same intent class, owner's call. Owner's stated premise
for keeping calling-intent terms: with 2.10 the numbers make calls and
"even receive". Checked in `line_calls` the same morning: **outbound is
proven at volume** (131 completed calls settled from Telnyx detail
records, up to 249 s, last 2026-09-06); **inbound DOES NOT WORK** — the
same-day three-agent audit plus a new Telnyx read-back found 13 real inbound
calls to sold lines in 30 days (the owner's own included), 0 answered, 0
reaching a device: the client never hands a VoIP push to the SDK unless the
app was already connected (CLAUDE.md → Known-open → INBOUND CALLING). Do
not put "receive calls" in any ad or listing until that is fixed and
device-tested; and the burner objection was about TEXTING, which 2.10 does
not change.

**Both campaigns read `PAUSED_BY_USER` at 09:00 Paris on 09-07** — not
done from this repo. Resume with the web UI or `PUT /campaigns/{id}`
`{"campaign":{"status":"ENABLED"}}`; the keyword pauses hold either way.
Next levers, in evidence order: route ASA installs to the Number tab off
`record-attribution`'s response; the sign-in wall (7 of 18 lost); revisit
the US cluster only after 2.10 is live and `report 1` shows it earning
impressions.
