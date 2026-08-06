---
paths:
  - "supabase/functions/**"
---

# Provider APIs — measured behaviour, not documented behaviour

Loaded automatically when working under `supabase/functions/`. Split out of the
root CLAUDE.md on 2026-08-06: it is ~10k tokens that only matter while editing
an adapter, and it was being paid for in every session.

⚠️ **Everything here was PROBED unless it says otherwise.** Where a section says
a shape was written from documentation, treat it as unverified — the two blocks
carrying that warning have both since been proven wrong in production.

## 5sim API — the provider that publishes delivery rates (live 2026-08-03)

Base `https://5sim.net/v1`. Auth is `Authorization: Bearer <JWT>` on `/user/*`;
`/guest/*` needs no key at all.

```
GET /v1/guest/prices?country=<slug>   # UNAUTHENTICATED
→ country → product → operator → {cost, count, rate, rate1, rate3, rate24,
                                  rate72, rate168, rate720}   # suffix = HOURS
GET /v1/user/buy/activation/{country}/{operator}/{product}    # pins the pool
GET /v1/user/profile                  # {balance, rating}
```

⚠️ **TWO DIFFERENT WINDOWS DO TWO DIFFERENT JOBS — do not collapse them
(2026-08-05).** `sync-5sim` computes both on every run:

| | function | window | used for |
|---|---|---|---|
| **selection** | `rateOf` | `rate24` → `rate168` → `rate720` | which pool `choosePool` pins. Never stored. |
| **display** | `displayRateOf` | `rate168` → `rate720` | `routes.pool_rate_pct` — what the country row renders and what the client sorts on. |

**Choose on freshness, display on stability.** Leading with `rate24` is right for
selection (fastest way to notice a dead pool, and reacting to noise is worth it
there) and wrong for a number a user reads as their odds. See "The pool rate is
the tie-break" for the incident that forced the split.

`routes.pool_rate_window` records which window each stored figure came from —
`168h` or `720h`. It used to be the hardcoded literal `"720h"` on every row while
the value was whatever the ladder landed on, so it never described the number
beside it until 2026-08-05. **Read it before quoting a rate.**

Do not read 5sim's own website as a reference: its operator list shows the **max
across all seven windows**, and its Statistics tab shows `rate72`, so our figures
will look lower than theirs. That is correct, not a bug.

🔴 **`rate720` ALONE IS NOT SAFE — it lags a pool's death by up to three weeks,
and that cost us a whole route (2026-08-04).** olx/us pinned `virtual63` at a
published **49.24%** whose `rate168`, `rate72`, `rate24` and `rate` were all an
explicit **0**: it had not delivered in at least seven days. Thirteen real
orders across five different users, every one held to expiry, **zero codes**.
On the same route `virtual51` published `rate720 = 0` — so we ranked it last —
while actually running at `rate24 = 22.7%`. We pinned the corpse and skipped the
live pool, then painted the row green at 49%.

Measured over the 801 chosen pools in the 14 busiest countries: **96 (12.0%)**
published `rate720 > 0` against an explicit `rate168 = 0`.

**ABSENT IS NOT ZERO, and this distinction is the entire fix.** The windows are
perfectly nested by length, so an absent field means *no activations* in that
window while an explicit `0` means there *were* activations and every one
failed. Only the explicit 0 is evidence of death. `staleDead` therefore tests
`v.rate168 === 0` and must NEVER be written as `!v.rate168` — the sloppy form
condemns every low-traffic pool in the catalog.

**THE FIX IS A FRESHNESS LADDER, not a special case.** `rateOf(pool)` in
`sync-5sim` returns, in order: `rate24` if positive → `rate168` if positive →
**0** when `rate168` is an explicit 0 → `rate720` → `null` (never measured).
One helper drives all three tiers of `choosePool`.

Leading with the short windows is nearly free. Measured over 4,003 in-stock
pools (2026-08-04):

| window | published | published > 0 |
|---|---|---|
| `rate24` | 35.4% | 8.7% |
| `rate168` | 37.7% | 11.8% |
| `rate720` | 39.5% | 14.8% |

**⚠️ THE ASYMMETRY IS LOAD-BEARING.** A positive short window is accepted
immediately; a **zero is only believed when the 7-day window agrees**. A rate
has no denominator, so a 24h zero can be 0-of-1 and must not condemn a good
pool, whereas a full week of activations that all failed is a verdict. Guarding
only the positive direction is the easy mistake here.

Live effect: rated routes 1,906 → 1,753; simulated over 2,962 routes, 90 switch
pool and 373 are relabelled (187 up, 224 down) for a coverage cost of −3.6%.
olx/us went `virtual63` 49% → `virtual51` 23%.

**Only the bare `rate` field is documented.** All seven windowed fields are
undocumented, and the documented rule *"omitted below 20% or too few orders"* is
already false live (we observe 0.0 and 4.24). Treat presence as the only signal.

**There is no denominator.** Rates cluster on exact small-denominator fractions
(4.76 = 1/21, 33.33 = 1/3), so a published "0%" is frequently 0-of-3, not a
verdict — and **~66% of every published `rate720` in the feed is exactly 0**.
`MIN_POOL_STOCK` guards *stock*, not sample size. Nothing currently bounds it.

**Four traps, all paid for in production — see the header of `_shared/fivesim.ts`:**

1. **`status: "RECEIVED"` DOES NOT mean a code arrived.** A freshly-bought order
   returns `{"status":"RECEIVED","sms":[]}`, and the docs' own example shows the
   SAME status *with* a code. **`sms[].code` is the only authority** — the same
   rule as SMS `otp is not null` and e-mail `code is not null`.
2. **A stockout and a bad country both return HTTP 200 `no free phones`.**
3. **Errors are PLAIN TEXT, never JSON**, and the status alone is not enough.
   `classifyFivesimFault` classifies transport FIRST and must never return
   `undefined` for one — `reserve()` treats undefined-or-OUT_OF_STOCK as "pinned
   pool dry, retry unpinned", which has already caused a double purchase once.
4. **There is no `maxPrice` parameter.** The post-fill ceiling check in
   `create-order` is therefore the ONLY price guard, so `refuseAboveUsd` uses the
   **tight** `maxCostUsd` bound — the loose `MAX_REVENUE_FRACTION` bound is only
   safe for a provider that enforces a cap server-side.

**The rate limit is REAL and it is a 429, settled 2026-08-03.** This was an open
question because the adapter collapsed every failure to `null`: a 429 (back off)
and a 403 (Cloudflare's bot filter, which spacing cannot fix) were
indistinguishable. `getPricesForCountry` now returns the status and `sync-5sim`
histograms it into **`fetch_faults`**. First instrumented run: `{"429": 10,
"400": 2}`, sample `"429: too many requests"`. So `CALL_SPACING_MS = 600` targets
the right cause — **but 10 hits per run means it is not quite sufficient.** Raise
it only on more than one sample; a run costs ~71s at 600ms × 61 countries and the
edge kill is ~150s.

**Do NOT set an explicit User-Agent.** Measured on the same URL 4s apart:
`Python-urllib/3.11` → **403 `error code: 1010`**, while `curl/8.7.1`,
`Deno/2.1.4` and an empty UA all → **200**. Deno's default already passes;
pinning a value means defending it against their next rule change.

**`user/profile.rating` is a SECOND way to lose the ability to buy**, invisible
in the balance. Starts and caps at **96**; completed activation +0.5, top-up +8,
against cancel −0.1, ban −0.1, timeout −0.15. **At zero you cannot purchase at
all**, surfacing as `not enough rating` — which `classifyFivesimFault` maps to
AUTH_ERROR, i.e. it pages as a dead key rather than the slow drift it is. We ban
dead numbers deliberately and our cancel rate is high, so it only trends down
between top-ups. Recorded into `app_config.5sim_health.rating` by
`poll-active-orders` (currently **96**, ~140 days of headroom). Nothing gates on
it on purpose — the ban is load-bearing for the fresh-number guarantee.

## HeroSMS API — what cost us time (probed live 2026-07-30)

⚠️ **HeroSMS is no longer the primary SMS provider, but it is NOT retired**: it
still owns 560 active SMS routes and the entire temp-EMAIL line, on one shared
account and balance. Everything below still applies to both.

Runs SMS-Activate's `handler_api` protocol. Base is
`https://hero-sms.com/stubs/handler_api.php?api_key=…&action=…` — there is **no
`api.` subdomain**, it is NXDOMAIN. `getCountries` / `getServicesList` /
`getOperators` need no key, so the whole mapping can be built before paying.

- **Every response is served as `content-type: text/html`, including the JSON
  ones.** Block detection keyed on content-type therefore classified every
  *successful* response as a Cloudflare block, which broke ordering outright. Key
  on **status 403/429 plus an HTML-looking body**, never on content-type. The
  symptom was a missing `herosms_health` row — and `recordBalance` returns early
  on null, so the absence looked like nothing at all.
- **Error codes carry suffixes**: `WRONG_MAX_PRICE:0.35`, `BANNED:<date>`. Exact
  `switch` matching silently never fires; use prefix matching for those two.
- **`activeActivations` is an OBJECT, not an array** — the real shape is
  `{"status":"success","data":[],"activeActivations":{…,"rows":[]}}`. So
  `d.activeActivations ?? d.data` never falls through and always returned `[]`.
  Read `d.data` first.
- **There is no documented per-second rate limit.** A 403 during probing was the
  *website's* bot challenge, not the API — 25 rapid calls all returned 200. The
  real cap is the account's `CHANNELS_LIMIT`. Do not add throttling to work
  around a 403 you got from a browser-shaped request.
- **`classifyHerosmsFault` is mandatory.** Per the provider-switch checklist, an
  adapter that does not set `errorType` collapses dead account / bad key / rate
  limit / genuine stockout into `no_numbers_available`, so users are told to "try
  another country" while the whole product is down and the escalation
  `console.error` never fires.
- `getPrices` returns `{cost, count, physicalCount}` per (service, country) —
  `physicalCount` is the real-SIM signal and the reason we moved.
- **`getTopCountriesByService`** works and returns 194 rows of
  `{country, price, retail_price, count}` per service. That is stock and price,
  **not** delivery success. It is now marked **Deprecated** in their docs, which
  point to `GET activations/offers` instead. Its response is an ORDERED map
  (`{"0":{…},"1":{…}}`), and that ordinal is sorted by neither price nor stock —
  which makes it look like the dashboard's quality ranking. **It is not.**
  Decoded for `go` (Google) it reads Indonesia → Colombia → UK → Brazil →
  Philippines → Turkey → Chile, while the dashboard's own "by quality" sort for
  the same service reads Finland → Portugal → Colombia → Chile → Spain. It ranks
  **Indonesia first**, and we have measured google/id at **0 of 4**. Treat the
  ordering as popularity/volume; using it as a quality signal would steer
  straight into routes we know deliver nothing.
- **`/api/v1/activations/offers` WORKS with `Authorization: ApiKey <key>`**
  (verified 2026-07-31). This contradicts the note below, which concluded the
  whole `/api/v1/activations` namespace is session-only — that is true of
  `/api/v1/activations` itself but **not** of this sub-path, so a targeted retry
  is worth it when a specific endpoint is known. It returns strictly more than
  `getPrices`: per (service, country) `counts.{total,physical,defaultPrice}`,
  `prices.{default,retail,min}`, and a price→stock `map`. `prices.min` plus that
  map is a real margin lever — `sync-herosms` currently buys at the default
  price when cheaper stock may exist. Not yet wired up.
- **There IS a rate limit** (`{"title":"RATE_LIMIT"}`), hit after roughly a dozen
  rapid calls on 2026-07-31. This file previously said there was no per-second
  limit because 25 rapid calls all returned 200. Note `sync-herosms` makes ~148
  sequential fetches at `CALL_SPACING_MS = 150` and shares the key with the
  minutely poller — do not probe casually against the production key.

**The per-(service, country) SUCCESS RATES in HeroSMS's dashboard are NOT
available by API — do not go looking again.** Searched exhaustively 2026-07-30:
26+ `handler_api` action names; the `/api/v1` namespaces `statistics`, `stats`,
`analytics`, `top10`, `activations/statistics` (all `ROUTE_NOT_FOUND`); the docs
page (a pure client-side loader with no SSR content); Nuxt `_payload.json`
(empty); all 50 JS chunks for any spec reference; 13 conventional OpenAPI paths
on both the site and their CDN. `/fr/*` is Cloudflare-challenged, so scraping is
out too. The "decisive test" recorded here was that the **same key and `ApiKey`
scheme that returns data from `/api/v1/emails` is rejected by
`/api/v1/activations`**, concluding the whole namespace is dashboard-session.
**That inference was too broad** — `/api/v1/activations/offers` authenticates
fine with `ApiKey` (see above). The bare collection path is session-only; its
sub-paths are not. So the negative result is "these ~45 specific paths do not
exist", not "the namespace is closed".

Re-probed 2026-07-31 with five more targeted paths now that `offers` was known
to work — `activations/{statistics,top-countries,ranking}`,
`statistics/activations`, `activations/offers/statistics` — all
`ROUTE_NOT_FOUND`. **Stop guessing; the path is not discoverable by enumeration.**

**✅ THE FULL OpenAPI SPEC EXISTS AND IS ON DISK: `~/hero-sms-research/openapi.json`**
(219 KB, 31 paths, `"API protocol for working with HEROSMS"`, servers
`hero-sms.com/api/v1` and `/stubs/handler_api.php`). This file previously said
no spec exists at any conventional path — read the spec instead of probing.
⚠️ **It is a CURATED SUBSET, not an inventory:** `getNumbersStatus` appears
**zero** times in it yet we call it in production, `getPrices` has no documented
`currency` param (we send it, it works), and `/api/v1/stats/deliverability` is
absent entirely. "Absent from the spec" means **undocumented**, never
**"does not exist"**.

**Two dead leads, both settled — do not re-open:**
- **`getTopCountriesByServiceRank` is NOT deliverability.** It and
  `getTopCountriesByService` differ in exactly two keys (operationId, summary);
  identical response schema, both deprecated. "Rank" is the **account's loyalty
  discount tier**, verified against SMS-Activate's own pricing pages. Live
  payload is `{country, price, retail_price, count}` — stock and price, no
  outcome field. Same trap as `physic` reading like "all physical SIMs".
- **`getListOfTopCountriesByService` does not exist on HeroSMS.** SMS-Activate's
  archived docs document it returning `{country, share, rate}` where `rate` is
  "% of successful activations" — exactly what we collect by hand. Probed
  2026-08-02: **HTTP 404 `BAD_ACTION: Method Not Found`**. Controls in the same
  minute on the same key proved it a true negative: `getBalance` →
  `ACCESS_BALANCE:10.1551`, `getTopCountriesByService` → 200 / 13,247 bytes.

**FOUND 2026-07-31, by reading the request the dashboard's own Statistics panel
fires (DevTools → Network → XHR). Enumeration never would have reached it:**

```
GET https://hero-sms.com/api/v1/stats/deliverability
      ?service=go            # their service code
      &interval=12           # hours
      &successCount=medium   # the ">50 successful" filter
```

The earlier sweep tried the `/api/v1/stats` namespace but never
`stats/deliverability`. Response is `application/json`, 200, behind Cloudflare.

**It is NOT callable with our API key.** All four schemes return **401
`{"title":"Unauthenticated."}`** — `Authorization: ApiKey`, `Bearer`,
`X-Api-Key`, and `?api_key=`. Note that body is *not* `ROUTE_NOT_FOUND`, so the
route genuinely exists and is simply scoped to a logged-in dashboard session.
**Do not re-probe it; the answer is settled.**

So the vendor is now the only route — but the ask is far smaller than it was,
and should be made in these exact terms: *"please allow
`GET /api/v1/stats/deliverability` to authenticate with an API key."* That is a
middleware change on one existing endpoint, not a feature request.

Asked the vendor 2026-07-31 (Jivo chat, ticket `5207504-97969`) before the path
was known. Response: *"I will forward your request"* — acknowledged, no
commitment, no timeline. **Do not block anything on it.**

**The manual loop is now the ONLY route, confirmed 2026-08-02.** Every API path
to this data has been eliminated (see the two dead leads above plus the
session-scoped `stats/deliverability`). Stop looking; spend the effort on the
vendor ticket or on accumulating our own measurement.

**Until they answer, the data is collected BY HAND, roughly weekly.** The loop,
in full, because half of it is easy to forget:

1. Log in to hero-sms.com, open the Statistics page, DevTools → Console, paste
   `scripts/collect-herosms-deliverability.js`. ~74 min for 147 services at
   30s spacing. It negotiates the loosest interval/threshold the API accepts,
   saves after every service, and resumes if the tab closes.
2. `copy(HERO.sql())` → run against the DB.

**Step 2's SQL ends with `refresh_service_country_ranks()` and that call is
mandatory.** `merge_vendor_deliverability` only stores the RAW payload;
`service_country_ranks` is the projection the app actually reads and is rebuilt
only by that function. Skip it and you load a fresh week of data, watch every
merge return `ok`, and the app keeps serving last week's ranking — a silent
no-op wearing a success message. `HERO.sql()` appends it for exactly that reason.

Saved progress **expires after 6 days**, so a weekly re-paste starts clean.
Without that the second run would find the previous results in localStorage,
mark all 147 services already-collected, fetch nothing, and look like it worked.

**"Top 10" is a CAP, not a quota.** Measured on the first full run
(24h / `successCount=medium`), only **22 of 147** services returned ten
countries; **69 returned none** and 32 returned one or two. leboncoin returned 2
against 33 active routes — not because 31 routes are bad, but because only two
countries saw 50+ successful leboncoin activations in a day. This is why
absence must stay neutral everywhere it is consumed. A longer window and a lower
threshold are what fill the thin services in, which is what the ladder probes.

Replaying the dashboard's session cookie from an edge function would work
technically and is a bad idea: it expires, it carries XSRF, it would fail
silently, and it is the kind of thing that gets an account closed. If a manual
pull is ever wanted, the honest shape is a hand-maintained per-service country
allowlist in `app_config` — same category as `blocked_routes` and
`voip_strict_services`, used as steering input for UNTESTED routes only.

And if it ever IS exposed: it would be **steering input, never a badge**. It is
their aggregate across all customers, not our delivery — the same class of number
as SMSPVA's seeded per-country grade, which ranked as "proven", beat genuinely
untested countries, and had to be demoted to `.notTested`.

## Telnyx API — what live probing found (2026-08-05)

Probed with a real account and one purchased DID (**+1 415 329 3816**, id
`3019915491322889224`, `customer_reference = vsms-test-line`). Balance went
$10.00 → **$8.13**. Everything below is measured, not read off the docs.

🔴 **NOTHING TELLS YOU WHAT YOU PAID.** The number-order response returns
`cost_information: null`, and `GET /v2/phone_numbers/{id}` has no price field
at all — 35 keys, none of them a cost. This is the SMSPool eSIM trap exactly
(*"its response reports no cost at all"*, which made margin analysis circular).
**Capture the price from the SEARCH quote at purchase time** into
`phone_lines.monthly_cost_cents`; `activate_line_claim` already takes it. There
is no way to recover it afterwards.

**Two request shapes that fail if you write them from the docs:**
- `POST /v2/messaging_profiles` **requires `whitelisted_destinations`** (e.g.
  `["US","CA"]`) or returns **40331 `Missing whitelisted destinations`**.
- **`messaging_profile_id` is NOT settable on `PATCH /v2/phone_numbers/{id}`** —
  it returns **10027 "not reachable here"**. Number config is split across
  sub-resources: `/v2/phone_numbers/{id}/messaging` and `.../voice`. The main
  resource does take `customer_reference` and `tags`.

**Prices are FLAT and half what was estimated: $1.00 upfront + $1.00/month for
every type probed** — US local, US toll-free, CA local alike.

⚠️ **"CA toll-free" IS A FICTION.** Filtering `country_code=CA` +
`phone_number_type=toll_free` returns the **identical numbers** as the US query
(+18779074790, +18338471334, +18556650304) — North American toll-free is one
shared NANP pool, so 833/855/877 are not Canadian. **Canada needs LOCAL
numbers.** Do not build a country picker that offers CA toll-free.

🔴 **`regulatory_requirements` IN SEARCH RESULTS IS ALWAYS NULL AND MEANS
NOTHING. IT COST $3.83 TO LEARN THIS.** `GET /v2/available_phone_numbers`
returned `regulatory_requirements: null` for every country probed, which reads
as "no paperwork needed". A GB mobile number was then bought on the strength of
it and arrived **`status: requirement-info-pending`** with **six** outstanding
requirements — it can never be used, and the money is spent. It was released
immediately to stop the recurring charge.

**The reliable pre-purchase source is
`GET /v2/requirements?filter[country_code]=XX&filter[action]=ordering`**, and it
is unambiguous:

| country | ordering rules |
|---|---|
| **US** | **0** |
| **CA** | **0** |
| GB, BE, LT, NL, BR, AU, PL, SE, ZA | **3–5** |

**Only the US and Canada are documentation-free. Every other country needs an
in-country physical address**, and that is fatal rather than inconvenient — GB's
six requirements include *"a valid, real-world physical address located in the
same country as the phone number"*, national proof of address (utility bill),
a government ID or company registration certificate, a company website, contact
details, and a business use-case description with sub-allocation disclosure.
Selling UK numbers needs a UK address; Dutch numbers a Dutch address. The only
alternative is collecting ID documents from every individual customer, which is
a privacy liability and a terrible checkout.

**So the line is US + CA, exactly as first scoped**, and there is no clever way
around 10DLC or toll-free verification. A multi-country catalogue was
investigated on 2026-08-05 and is closed — do not re-open it on the strength of
the search endpoint's null field.

## The definitive sellable catalogue (exhaustive sweep, 2026-08-05)

228 ISO codes → **138 carry ordering requirements** (fetched from
`/v2/requirements?filter[action]=ordering`, 292 rows, the reliable source) →
the remaining 92 were swept for live inventory. **Everything we can sell
without paperwork is NANP (+1):**

| country | type | $/mo | upfront | SMS |
|---|---|---|---|---|
| **US** | local | 1.00 | 1.00 | ✅ |
| **CA** | local | 1.00 | 1.00 | ✅ |
| **VI** US Virgin Is. | local | 1.00 | 3.00 | ✅ |
| **PR** Puerto Rico | local | 3.00 | 3.00 | ✅ |
| CD DR Congo | mobile | 27.00 | 27.00 | ❌ voice only |
| BW Botswana | toll_free | 40.00 | 40.00 | ❌ voice only |

The other **86** requirement-free codes have **no inventory at all**. CD and BW
are voice-only and cost 3–5× the retail price, so they are unsellable.

⚠️ **PR and VI are US area codes, not extra markets.** They are +1/NANP, so US
carrier rules — including 10DLC — apply to them exactly as to any US number.
Listing them as "4 countries" would be marketing fiction; it is one market with
four flag icons.

✅ **CANADA NEEDS NO 10DLC — MEASURED, AND IT IS THE LAUNCH PATH.** Tested
2026-08-05 with a real purchase: `+1 343 513 1580` (Ottawa) went **`active`
immediately** with no requirement pending, and sending from it to our US number
with **no TCR brand and no campaign registered** was **`delivered`** at
$0.0040. `/v2/10dlc/brand` reports `totalRecords: 0` — nothing is registered
and it worked anyway.

**So the zero-paperwork launch is: sell CANADIAN numbers.** No TCR brand, no
campaign, no toll-free verification, no waiting on an external approval that
can be rejected. A +1 number is equally credible to a US recipient, and CA
costs the same $1.00/month as US.

⚠️ **US numbers still need 10DLC to SEND.** The purchased US number carries
`messaging_campaign_id: null` and is unregistered. Do not assume the Canadian
result generalises to it — it does not, because TCR is a US carrier programme
and the Canadian number is simply not subject to it. Offer US numbers only
after the brand and campaign clear.

⚠️ **Inbound to a Canadian number is still domestic-only** (`international_
inbound: false`, same as US), so this fixes the *paperwork*, not the
can-a-European-text-it problem.

**The inbound path is now PROVEN END TO END.** The `message.received` webhook
arrived, passed Ed25519 verification in production, and was captured. Replayed
through the verifier: real bytes verify, one flipped byte fails, a re-serialized
body fails, a replay past 300s fails, and a slid timestamp fails — 6/6.

🔴 **The parse-after-verify rule is not theoretical: Telnyx sends
PRETTY-PRINTED JSON.** The captured body is **1,703 bytes**; `JSON.parse` then
`JSON.stringify` yields **1,203**. Parsing before verifying would silently
discard 500 bytes of signed content and every signature would fail. Read
`await req.text()` once, verify, *then* parse.

**A corollary worth keeping:** the two-tier pricing designed for a 36-country
catalogue is unnecessary. US and CA are both $1.00/month, so **one product at
$9.99 covers the whole catalogue.**

🔴 **US NUMBERS ARE DOMESTIC-ONLY FOR SMS, AND YOU CANNOT TURN THAT OFF.**
Measured on the live number: `features.sms` reads
`{domestic_two_way: true, international_inbound: false, international_outbound:
false}`. A European phone texting the number produces **nothing at all** — not a
failure, not a webhook, not a `detail_record`. The message leaves the sender's
handset looking sent and simply never reaches Telnyx.

⚠️ **`PATCH /v2/phone_numbers/{id}/messaging` with
`features.sms.international_inbound = true` returns 200, no error, AND CHANGES
NOTHING.** The write is silently ignored — the same silent-no-op class as
`getPrices` accepting an `operator` param it discards, and as the column-revoke
migration that edits `pg_attribute` while the table grant still wins. **Read the
value back; do not trust the 200.** Enabling international messaging is an
account-level capability that needs Telnyx to grant it, not an API call.

**The P2P lane is a DEAD END — settled 2026-08-05, do not re-probe.** The
number advertises `eligible_messaging_products: ["A2P", "P2P"]`, which reads
like an unregistered person-to-person route and is exactly what a
rent-a-number product wants. It is not available:
`PATCH /v2/phone_numbers/{id}/messaging` with `{"messaging_product":"P2P"}`
returns **200 with no error and changes nothing** — `messaging_product` stays
`A2P` on read-back. Same silent-no-op as the international flag above, in the
same session, on the same endpoint. **"Eligible" describes the number, not your
account.** US carriers closed the unregistered P2P lane to CPaaS traffic;
10DLC registration is genuinely unavoidable for outbound, with any provider,
because it is a carrier rule rather than a Telnyx one.
(`/v2/10dlc/brand` currently reports `totalRecords: 0` — nothing registered.)

**What that means for who this line is for.** It is a **US product**, and that
is fine: measured over all 39 Production purchases, **USA is 53.8% of purchases
and 9 of 21 buyers** (FRA 23.1%, then ESP/BGR/TUR/POL/AUT/SVK/SWE at 1–2 each).
The single largest market gets a fully working product. But a European user who
rents a US number **cannot text their own contacts with it**, which is a
refund-generating surprise rather than a limitation they will infer. Either gate
the line to the US/CA storefronts or say plainly on the store screen that a US
number exchanges messages only with US and Canadian numbers. European local
numbers are not the escape hatch — those are exactly the ones needing
regulatory bundles with an end-user address.

Other measured facts: number orders are **asynchronous** (`pending` → `success`,
under 5s here, but build the poller anyway — it is what survives a webhook
outage); `reservable: true`, so the reserve-then-paywall flow is available;
`emergency_status` is **`disabled` by default**, so our E911 stance is "never
enable it" rather than "remember to turn it off"; US local has `hd_voice`,
toll-free does not; and the default US local search returns obscure rate
centers (a Texas one), so the picker must filter by `national_destination_code`
— area code 415 correctly returned San Francisco numbers.

✅ **`@noble/curves/ed25519` RUNS on the Supabase edge runtime — verified in the
hosted runtime, not assumed.** A well-formed but wrong signature was rejected
as `bad_signature`, which means the curve math executed. This is the check the
P-384 incident demands: that failure passed locally and threw
`NotSupportedError` in production, rejecting every purchase for weeks.

**Blocked on external clocks, none of them code:** toll-free verification and/or
10DLC brand+campaign (weeks, can fail outright — fanning many end users through
one Standard 10DLC campaign is what carriers police; note the purchased local
number has `messaging_campaign_id: null` and cannot send US A2P until
registered). ⚠️ **US only** — Canada needs none of it, which is why the launch
is Canadian; see "CANADA NEEDS NO 10DLC".

✅ **The App Store Server API key EXISTS and is WIRED (2026-08-05).**
`SubscriptionKey_BTPZRH3GW3.p8` (Users and Access → Integrations → **In-App
Purchase**), stored at `~/.appstoreconnect/private_keys/` and mirrored into four
Supabase secrets: `APPSTORE_KEY_ID` / `APPSTORE_ISSUER_ID` /
`APPSTORE_BUNDLE_ID` / `APPSTORE_KEY_P8`.

Three facts settled by probing, none of them obvious from Apple's docs:

- **The issuer id is the SAME as the ASC API one** (`4644ed13-…`). The In-App
  Purchase keys page shows an issuer id and it is easy to assume it differs; it
  does not. Nothing extra to obtain.
- **The JWT needs `bid` (the bundle id)**, which the App Store Connect API JWT
  does not. Omitting it returns **401**, indistinguishable from a wrong key.
- **`AuthKey_R5ZVLBTUR6.p8` genuinely will not work here** — it is an App Store
  Connect key. Keep the two straight; they live in the same directory.

Verified against `POST /inApps/v1/notifications/test` on **both**
`api.storekit-sandbox.itunes.apple.com` and `api.storekit.itunes.apple.com`:
both returned **404 `4040007` "No App Store Server Notification URL found"**,
which is a *business* error and therefore proof the auth passed. A 401 is the
auth failure; do not read a 404 here as a broken key.

That 404 also states the remaining blocker exactly: **`subscriptionStatusUrl`
and its sandbox twin are still `null`** and can only be set once
`apple-notifications` is deployed, because Apple validates reachability.

⚠️ **Float — this is the ONE hard blocker left, and it is money, not code**
(owner deferred it 2026-08-05: *"ill do that when i got funds"*). Each line
costs $1 upfront + $1/month, Apple pays ~45 days in arrears, so the float is
carried ahead of any revenue: 50 subscribers is $50/mo out before a cent comes
back. Last reading **$2.33** — that is a test balance, not a launch balance.
Everything downstream of provisioning can be BUILT and tested against Sandbox
without it; only actually buying a DID needs it.

**Three traps the plan calls out that are easy to lose:** the reviewer will use
a **Sandbox** subscription, and `iap-verify`'s `environment === "Production"`
gate applied to provisioning means the reviewer subscribes, gets nothing, and
rejects. **Inbound SMS/calls are the uncapped cost risk** — the user cannot
control them, so never bill for inbound and cap it server-side. And E911 must
be **disabled and unmissably disclosed**, not buried in a Terms link.

## Why `sync-5sim` exists (hourly :07) — the PRIMARY pricing sync

Fetches `guest/prices` **one country at a time** (61 countries, ~71s/run). The
all-countries form is a single 9.1 MB response; per-country is 0.1–0.6 MB, which
bounds peak memory inside the edge runtime and lets a partial run still write
what it got. `CALL_SPACING_MS = 600` plus one 2.5s retry — see the 5sim section
for why (measured 429s, not a bot filter).

It prices routes (`CREDIT_DIVISOR = 0.03`), applies the **cost RATCHET**, picks
the pool each route buys from, and writes `pool_operator` / `pool_rate_pct`.

**`choosePool` has THREE tiers, and the ordering is the whole point:**

1. `rate720 > 0` — best rate first.
2. **unrated** — most-stocked, `ratePct = null`.
3. **all pools published zero** — most-stocked, and the 0 is kept.

Tier 2 must sit above tier 3. Before this was fixed (2026-08-03), **844 routes
picked a published-0% pool over an unmeasured pool holding a median 271× the
stock** — olx/Finland took `virtual4` at 0% over `virtual34`'s 8.6 M numbers —
and then painted the route red in the picker with that number. Both the pick and
the label rested on a sample that is frequently 0-of-3. Live effect: routes
carrying a published zero went **1,184 → 359**. It is also a **repricing**,
because cost derives from the chosen pool: 469 routes got cheaper, median −1
credit.

The chain is filtered by `affordable()` — non-head members above
`headCost × 3 + 0.10` are dropped, so a fallback can never cost wildly more than
the pool we advertised.

**Guards, each matching a failure this codebase has already had:** it aborts
without writing if every country fetch fails (`countries_ok === 0`); it skips
routes whose country failed *this* run rather than reading a failed fetch as
"not served" (`skipped_failed_country`); it enforces `blocked_routes` and
`MAX_WHOLESALE_CENTS = 450`. Watch `fetch_faults` and `countries_failed` in the
response — a country silently dropped for an hour reads as "5sim does not serve
it".

## Why `sync-herosms` exists (hourly :37)

**⚠️ IT PRICES FROM `/api/v1/activations/offers`, NOT `getPrices` (2026-08-02).**
`getPrices` returns a DEFAULT price and a TOTAL count, and **those two numbers
are not about the same numbers** — on many routes nothing at all is available at
the default price. The worked example cost a paying customer their entire
session (8 straight failures, then they left), apple / Turkey (`wx`/62):

```
getPrices : cost 0.30, count 140211              <- what we used to store
offers    : counts.defaultPrice = 0,
            map = { "0.4177": 641003 }           <- the truth
```

Zero numbers at $0.30; all 641,003 cost $0.4177. Storing $0.30 priced the route
at 12 credits, which set the order ceiling at $0.40 — **1.8 cents below the only
stock in existence**. Every attempt returned `WRONG_MAX_PRICE` → `margin_too_low`
→ charged and refunded, forever.

Measured over 1,554 pairs: **60 (4%) had ZERO stock at the advertised price** and
**1,107 (71%) had stock CHEAPER than it**, so `getPrices.cost` is wrong in both
directions. We now take the cheapest key in `map` **with a non-zero count**.

- **`prices.min` is NOT that number** — it reads 0.27 on wx/62 where nothing
  exists below 0.4177. It is "the lowest price you may bid". Only the map says
  what is buyable.
- Falls back per service to `getPrices` when offers fails **or reports
  `hasMore`** — the pagination params are undocumented, and a partial page must
  never read as "not served".
- **Also ~40× fewer calls**: 144 codes in ONE run of ~4 requests instead of ~148
  sequential fetches at `CALL_SPACING_MS`, which was most of our rate-limit
  exposure. Live run: **11.5s**, `via_offers 144 / via_getprices 0 / truncated 0`.
- Watch `via_getprices` in the response. If it climbs toward `codes_ok`, offers
  is degrading and we are silently back on the phantom default price.

It records HeroSMS's real per-route wholesale into
`routes.herosms_cost_cents` + `herosms_physical_count` / `herosms_total_count` /
`herosms_checked_at`, and hides routes HeroSMS cannot serve. **It deliberately
does not touch `retail_credits`** — repricing is the separate owner decision
above; this function exists to stop us selling what we cannot deliver.

The bug it fixes: after the cutover, HeroSMS rows still held SMSPVA's frozen
`last_cost_cents`, and `create-order`'s graceful degrade did
`liveCost ??= route.last_cost_cents/100`. For routes HeroSMS cannot serve at all
`livePriceUsd` returns null, the **stale SMSPVA cost passed the margin gate**,
and the reservation then failed `NO_NUMBERS` — charging and refunding the user
and telling them to "try another country". The fallback is now provider-scoped,
so a HeroSMS route can only fall back to a HeroSMS cost. First run hid **4,849**
routes (active HeroSMS 10,049 → 5,198); ~3× more than estimated.

Guards worth keeping, each matching a failure this codebase has already had: it
**aborts without writing if every price fetch fails** (a dead key must not hide
the catalog), skips routes whose service code failed *this* run rather than
reading a failed fetch as "not served", destructures every read error, and
enforces `blocked_routes` and `MAX_WHOLESALE_CENTS` — neither of which was
enforceable on HeroSMS rows before it existed.

`herosms_physical_count` is the **real-SIM** count (vs VoIP), confirmed against
HeroSMS's own UI: every country it labels "Only virtual" reports 0. **4,046 of
the 5,198 active HeroSMS routes have physical stock.** Stored and not yet used
for steering — that is the open lever for the Meta services.

**Credit packs** (`Models/CreditPack.swift` + `Products.storekit` + `_shared/iap.ts` `PRODUCT_TO_CREDITS`): 5/$2.99, 12/$5.99 (MOST POPULAR), 30/$12.99, 60/**$24.99**, 150/**$59.99** (BEST VALUE) — a strictly improving per-credit ladder (each pack beats stacking smaller ones): $0.598 → $0.499 → $0.433 → $0.417 → $0.400. The per-credit label is computed **live** from the StoreKit price in `IAPStore.perCredit`, so it never drifts; production prices must be set to match in App Store Connect.

**USD and EUR were realigned on 2026-07-31 (owner decision) — the numbers above
are now what BOTH storefronts bill.** Until then the US paid *less*: `credits.12`
was **$4.99** against €5.99 and `credits.30` **$11.99** against €12.99.

The cause was the base territory, and it is worth knowing because it will
recur: `credits.5/12/30` were anchored to **FRA**, so their dollar price was
*derived* from the euro one; `credits.60/150` were anchored to **USA**. Mixing
anchors across a single ladder is what let it drift. Fixed by adding an explicit
USA manual price to 12 and 30 while leaving FRA the base — so only USD moved and
every other territory (DEU/ESP €5.99, GBR £4.99, CAN $6.99, AUS $7.99, JPN ¥800)
is untouched. Verified after the write.

**That drift had inverted the ladder in the US, on the top revenue product.**
At $11.99/30 and $24.99/60 the 30-pack was **$0.3997**/credit and the 60-pack
**$0.4165** — so two 30-packs bought 60 credits for **$23.98**, beating the
$24.99 60-pack. The 60-pack was strictly dominated. The US ladder is now
strictly improving again and identical to the EUR one:

| pack | US price | per credit |
|---|---|---|
| 5 | $2.99 | $0.598 |
| 12 | $5.99 | $0.499 |
| 30 | $12.99 | $0.433 |
| 60 | $24.99 | $0.417 |
| 150 | $59.99 | $0.400 |

Apple proceeds went $4.24 → **$5.09** on the 12-pack and $10.19 → **$11.04** on
the 30-pack. A price change needs no review and takes effect immediately, but
**`revenue_snapshot` reads the signed `price` out of each receipt**, so
historical rows keep the old amounts and are still correct — do not "fix" them.
Confirm against `/v1/inAppPurchasePriceSchedules/<iap-id>/{manual,automatic}Prices`
before acting on any of these numbers; this file has been wrong about them twice.

**The 60 and 150 packs are the LIVE ASC prices, read back from the API on
2026-07-25 — this file previously claimed $22.99/$49.99, which was never what
the store would have billed.** **`credits.60` is now `APPROVED` and SELLING** —
verified 2026-07-30 both on `/v1/apps/6774768570/inAppPurchasesV2` and by two
live `$24.99 USD` purchases within 20 minutes of each other. This file said it
had "**never** been approved" and that the largest purchasable pack was 30
credits; that is wrong, and it mattered — the 60-pack is now the **top revenue
product**, out-earning everything else in the 24h to 2026-07-30. **All five packs now read
`APPROVED` (verified 2026-08-02)** — `credits.150` cleared review after being
submitted 2026-07-30 06:53Z, so the full ladder is purchasable.

Check `state` on `/v1/apps/6774768570/inAppPurchasesV2` before assuming the
ladder the code defines is the ladder a user sees — and note this file has now
been wrong about it twice. (Product-level `state` is unreliable for
*submittability* — see Release prep — but `APPROVED` vs not is trustworthy.)
