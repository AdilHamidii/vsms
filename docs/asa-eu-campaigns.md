# Apple Search Ads — the European campaigns (2026-09-10)

*Every figure here was read from the ASA API, the aso-connect scorer, ASC or
the app's own database on 2026-09-10. Nothing is recalled. Re-derive before
acting: `scripts/asa.py campaigns` · `report N` · `searchterms <cid> N`.*

Owner brief: *"focus on European countries, and make ads for a us number,
second number, temp sms, temporary sms and such keywords"*, then *"i need
second number ads for eu market too"* — the second-number cluster gets its own
campaign on the owner's explicit instruction, after being shown that all 20
line subscriptions ever sold are USA storefront.

Design went through two adversarial red-team passes. Both returned DO NOT SHIP
against earlier drafts; what shipped is the third design, and the two findings
that produced it are §1 and §2 below.

---

## 1. 🔴 EU delivery is a MATCH-TYPE problem, not a relevance problem

This is the finding that shapes every campaign here, and it contradicts what
`docs/asa-second-number-plan.md` §9 concluded.

§9 explained the 09-06 zero-impression result as a metadata-relevance failure:
*"the listing carries no `usa`/`american` anywhere… so exact-match terms get no
relevance."* **That is true of the US cluster and false as a general
explanation of Europe.** Pulled from the deleted campaign `vSMS WhatsApp EU`
(2144617614) — deleted campaigns stay queryable with
`{"field":"deleted","operator":"IN","values":["true","false"]}`:

```
CAMPAIGN TOTAL, entire life: 16 impressions, 3 taps, 0 installs, €2.01
  virtuelle nummer   0 impr   <- 'virtuelle' WAS in the live de-DE keyword field
  numéro virtuel     0 impr   <- 'virtuel'   WAS in the live fr-FR keyword field
  recibir sms        0 impr   <- 'recibir'   WAS in the live es-ES keyword field
  ricevere sms       0 impr   <- 'ricevere'  WAS in the live it    keyword field
  numéro jetable     0 impr   <- 'jetable'   WAS in the live fr-FR keyword field
```

Six fully metadata-supported keywords drew zero at a €1.30 bid. Meanwhile, the
same org, the same day, the same European storefronts:

| 2026-09-06 | impressions |
|---|---|
| a vRoam EU campaign (BROAD ad groups) | **1,263** |
| `vSMS WhatsApp EU` (100% EXACT) | **15** |

**84×.** The one structural difference is match type.

Confirmed again inside a *single* campaign, on 2026-09-10, via the new
`searchterms` command on `vRoam MENA Intent`:

```
BROAD  esim app / badi esim / شريحة سفر …   85, 82, 66, 55, 49 impressions
EXACT  تجوال / esim roaming / e sim / ايسيم    5,  2,  1,  2 impressions
```

Same app, same account, same days, same storefronts — broad outdraws exact by
one to two orders of magnitude.

🔴 **So every European campaign here carries a BROAD ad group beside its EXACT
groups, on the same terms.** That pairing is the only thing that separates the
two live hypotheses — *low absolute query volume on long-tail EXACT terms* vs
*something suppressing this app specifically*. **Do not "simplify" these back
to all-EXACT without reading `searchterms` first.**

⚠️ **Not Search Match** (`automatedKeywordsOptIn`). It is the only construct in
this org that reliably spends its cap — `vRoam EN Discovery` took 1,146 and
1,170 impressions on 09-06/07 — at the **worst CPI in the account (€3.86)**,
and ASA budgets are CAMPAIGN-level with no per-ad-group cap, so beside exact
groups drawing ~2/day it takes essentially the whole budget. BROAD buys the
same discovery and is steerable with negatives.

## 2. 🔴 There is no lifetime budget. Apple removed them in June 2026.

Apple paused every campaign that carried a lifetime budget, and switched
campaigns holding both to daily-only. `budgetAmount` survives as a legacy key
in the v5 Campaign model and reads **None on all 22 campaigns in org
22495890**, hand-made web-UI ones included.

**Consequence:** `dailyBudgetAmount` is the only cap that exists. Total
exposure is *daily × days until a human pauses it*. Nothing on the platform
stops a campaign on a date. Any plan that states a total spend is stating a
promise about someone's memory.

⚠️ `cmd_create_us` still sends `budgetAmount` and `cmd_campaigns` still prints
a `total` column. Both are inert. Do not build a bound on either.

## 3. What Europe has actually bought

| product | who has ever paid |
|---|---|
| line subscription | **20 all-time, every one USA storefront.** Of those, 10 carry `price_milli = 0` (the discontinued yearly free trial) and 1 was refunded — so **~9 people have ever paid for a line.** Europe: **0** |
| credit packs | 82 Production purchases — USA 56, **Europe ≈ 18** (FRA 8, ESP 3, BGR 2, ITA 1, AUT 1, POL 1, SWE 1, SVK 1) |

ASA's own lifetime record, `install_attributions`: **19 attributed installs →
0 credit-pack buyers, 0 delivered codes, 1 subscription** (from the old
temp-SMS campaign, not from second-number intent). Two of the 19 were European.

**So Europe is graded on credit-pack purchases.** Grading it on line
subscriptions divides by zero. The second-number and US-number groups exist
because the owner asked for them and because their relevance blocker was just
removed (§4) — they are a measurement, not a forecast.

## 4. The listing, and what it does and does not support

The USA subtitle **is** live and **is** new: the `READY_FOR_SALE` appInfo
carries USA in all 13 locales (`USA Phone Line & Verification`, `USA-Nummer &
SMS-Code`, `Ligne USA & SMS temporaire`, `Linea USA y SMS temporal`, `Linea
USA e SMS temporanei`, `Numero USA e SMS temporario`). It shipped with 2.10,
created 2026-09-06 and submitted 09-06 17:05Z / 09-07 07:56Z — the second is
*after* the campaigns were paused at 07:00Z on 09-07, so the 09-06 experiment
genuinely ran on a listing with no `usa` token.

**But that fixes the US cluster only, and §1 shows it does not explain
Europe.** Two further facts:

- ⚠️ **The keyword field still has no `usa` in any locale** (identical on live
  2.11 and on 2.13 in review). The `it` field's `usaegetta` is a false
  positive — Italian for *usa e getta*, "disposable", and a single token.
  US-intent relevance rests on the subtitle alone.
- ⚠️ **The fallback language is the app's PRIMARY locale, `en-US`** — not
  en-GB (`GET /v1/apps/6774768570` → `primaryLocale: en-US`). GB and IE map to
  en-GB; **NL, SE, DK, NO, FI, PL have no listing locale and fall back to
  en-US.** The two fields differ in exactly the token that matters:
  `receive` is in en-US and **not** in en-GB. So `receive sms` is supported
  where the volume isn't and unsupported where it is.
- **There is no `nl` locale**, so Dutch keywords have no metadata to be
  relevant against — even though `virtueel nummer` (60 pop / 31 diff) beats
  `virtual number` (51/39) organically. NL is served by the English campaign.

🔴 **The free intervention, and it is probably worth more than this budget:**
put `usa`, `receive`, and verification tokens (`verification`,
`verifizierung`, `vérification`, `verificación`, `verifica`) into the 2.14
keyword fields. It costs €0, is permanent, and reaches the organic channel
that produces **all** of this app's downloads. 2.13 is `WAITING_FOR_REVIEW`
and must NOT be pulled from review for it.

## 5. The campaigns

`scripts/asa.py create-eu --yes`. Three campaigns, €4/day each. Every write is
read back, and **`endTime` is asserted null on every ad group** — an ad group
that reached its end date is what silently killed the previous EU campaign
while it read ENABLED.

### A · `vSMS EU Verification` — DE, AT, CH, FR, BE, ES, IT — €4/day

| ad group | match | bid | keywords |
|---|---|---|---|
| DE | EXACT | €1.30 | virtuelle nummer · virtuelle telefonnummer · temporäre nummer · sms verifizierung |
| FR | EXACT | €1.30 | numéro virtuel · recevoir sms · numéro temporaire · sms temporaire · numéro jetable · vérification sms |
| ES | EXACT | €1.20 | recibir sms · número virtual · número temporal · sms temporal · verificación sms |
| IT | EXACT | €1.20 | numero virtuale · ricevere sms · numero temporaneo · sms temporaneo · verifica sms |
| **EU** | **BROAD** | €0.80 | the same 11 core terms across all four languages |

### B · `vSMS EU Second Number` — DE, AT, CH, FR, BE, ES, IT — €4/day

Its own campaign because ASA budgets are campaign-level: sharing one with the
verification terms would let them eat the spend and there would be no clean
read on the thing the owner asked for. The keyword sets are disjoint, so the
two campaigns cannot bid against each other.

| ad group | match | bid | keywords |
|---|---|---|---|
| Second number | EXACT | €1.30 | zweite telefonnummer · zweite nummer · zweite handynummer · second numéro · deuxième numéro · deuxième numéro de téléphone · segundo número · secondo numero |
| US number | EXACT | €1.30 | usa nummer · us nummer · us telefonnummer · numéro usa · numéro us · número usa · numero usa |
| **Second number** | **BROAD** | €0.80 | the 8 highest-volume of the above |

### C · `vSMS EU English` — GB, IE, NL, SE, DK, NO, FI, PL — €4/day

| ad group | match | bid | keywords |
|---|---|---|---|
| Temp SMS | EXACT | €1.30 | receive sms · temp number · sms verification · temp sms · temporary sms · otp number · virtual number |
| Second number | EXACT | €1.20 | second phone number · second number · 2nd phone number |
| US number | EXACT | €1.20 | us number · usa number · american number · us phone number |
| **English** | **BROAD** | €0.80 | the 6 highest-volume of the above |

**Negatives: 20 BROAD + 6 EXACT per campaign** (`NUMBER_NEGATIVES_BROAD` /
`_EXACT`). On an all-EXACT campaign these are near-inert; **with a broad group
they are load-bearing**, and `esim` / `data plan` especially so —
`vRoam EU Intent` is ENABLED at €30/day across a strict superset of these
countries, and broad match will otherwise put the owner's two apps in each
other's auctions. The searchterms readout above shows broad drift is real:
`safari` and `my airtel app` both matched broad eSIM keywords.

## 6. Keyword rulings

- 🔴 **Every "American number" adjective is dead volume**, measured:
  `amerikanische nummer` popularity **0** with **0 results**; `numéro
  américain` **1**, its single result a VIN-check app; `número americano`
  **7**; `numero americano` **14**, half its results English-teaching apps.
  **The `usa` abbreviation is the live form**: `numero usa` **58**,
  `usa nummer` **49**, `numéro usa` **50**, `número usa` **41**.
  `american number` survives in GB only (50/45).
- 🔴 **`burner number` / `burner phone` stay OUT.** The owner paused them
  2026-09-07 after they delivered 8 of 18 installs on two-way-texting,
  free-app intent this product does not serve. Outbound SMS outside NANP is
  still hard-blocked.
- **Long-form Romance phrasings are traps**: `segundo número de teléfono`
  51/**57** and `secondo numero di telefono` 54/**58** are *harder and lower
  volume* than `segundo número` (58/45) and `secondo numero` (63/47).
- **Bare WhatsApp terms excluded** — `numéro whatsapp` (62/**57**), `número
  para whatsapp` (55), `numero per whatsapp` (54) all carry WhatsApp Messenger
  itself (2.2M–3.5M ratings) in the top 5. The *qualified* forms score better
  (`deuxième numéro whatsapp` 41/34) but `whatsapp` is not a token in any
  locale's metadata, so they are held for the 2.14 keyword-field edit.
- **Dropped as dead**: `wegwerfnummer` (4), `temporäre handynummer` (3),
  `numero usa e getta` (8), `número desechable` (18), `ricevere sms online`
  (11). And `sms empfangen` (71/**58**) — its SERP is Apple Nachrichten and
  Messenger, i.e. carrier-SMS intent.
- **Temp e-mail terms excluded** despite `temp mail` scoring 72 in GB against
  tiny incumbents: e-mail is a free product, and paid installs for
  zero-revenue usage is the worst available use of the budget.

## 7. Reading it — and what each rule can actually resolve

⚠️ **Every campaign in this account delivers ~nothing on day 1** (vRoam EU 26,
vRoam EN Discovery 35, vSMS Number US 63, all €0) and ramps on day 2. Read on
day 2, not day 1.

| when | rule |
|---|---|
| day 2 | 🔴 **BROAD vs EXACT impressions, per campaign.** This is the whole experiment. If broad delivers and exact does not, EU exact terms are simply low-volume and the answer is broad + negatives, not higher bids. If NEITHER delivers, the fault is account-level and no keyword list fixes it. |
| day 2 | `searchterms <cid> 2` returns rows. Verified working before launch against `vRoam MENA Intent`, so an empty result means no impressions, not a broken report. |
| day 2 | every ad group's `endTime` still null |
| day 7 | any ad group with ≥ 200 impressions and 0 taps → pause it |
| day 14 | **cost per Production credit-pack purchase.** At ~3% install→pack (82 buyers / 1,653 users, ~61% of installs sign in), 0 packs from 60 installs has P ≈ 16% — resolvable. **0 packs from ≥ 60 installs → stop.** |
| — | **no per-keyword subscription rule.** Europe has never produced a subscription; it cannot resolve. |

⚠️ **The `US number` group has no revenue metric here**, and that is stated
rather than hidden: a US-number searcher's product is the $5.99 subscription,
which Europe has never bought. That group buys exactly one bit — *does it get
impressions now the subtitle carries USA* — and it should be judged on that
and then either kept or cut.

## 8. Honest accounting of what this is worth

Measured revenue to date is ≈ **$0.63 per signup** — ≈$490 gross of credit
packs across nine currencies plus $559 of line-subscription `price_milli`,
netted of Apple's 15%, over 1,653 `auth.users`. ⚠️ The pack-only figure
(**$0.27**) is the number `/revenue` and `/profit` produce, because both omit
every subscription line (CLAUDE.md → Known-open); do not quote it as total
revenue.

At €0.80–1.30 bids and ~65% tap→install, an install costs roughly €1.20–1.85.
**Every bid that wins an auction here loses money on the install.** What the
spend buys is the answer to §1 — whether Apple will show this app to Europeans
at all, and on which match type — plus the search-terms list, which then goes
into the 100-character keyword field where it is free forever.

**The strongest argument against running this at all**, recorded because it is
a good one: the free 2.14 keyword-field edit (§4) reaches the organic channel
that produces 100% of this app's downloads, costs nothing, and is permanent;
the account has served ~30 impressions/day org-wide for three days for reasons
nobody has diagnosed; and a campaign put on top of an undiagnosed account-level
delivery fault will produce another unreadable zero. The counter-argument, and
the reason it runs: at €12/day the match-type question gets answered in 48
hours for about €25, and it is the question that decides whether ASA is a
channel for this app in Europe at all.

## 9. Preconditions

1. 🔴 **Fund 5sim.** `5sim_health` reads **$8.29**, and `watchdog.failing` is
   `["5sim-float"]` — ~3.4 days of runway. 5sim is the provider a European
   temp-SMS install actually hits, and an empty float fails every order as
   `provider_unreachable`. **Telnyx is fine at $12.42** and is NOT failing.
2. ⚠️ **The live binary is 2.11**; 2.13 is `WAITING_FOR_REVIEW`. A paid
   install today gets no Home router, no $3.99 intro display, and the
   **pre-selected starter pair** that delivers 2.5% against 35.1% for
   user-picked routes — with a wallet of 0, since the signup grant is 0.
   **Conversion readings taken before 2.13 is live are void.** The day-2 rules
   above are about delivery, which is build-independent; the day-14 revenue
   rule is not, and should be restarted when 2.13 ships.
