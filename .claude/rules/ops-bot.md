---
paths:
  - "supabase/functions/telegram-*/**"
  - "supabase/functions/_shared/tg*.ts"
  - "supabase/functions/_shared/opsFormat.ts"
---

# Telegram ops bot — commands, formatting, alerts

Loaded automatically when working on the bot. Split out of the root CLAUDE.md
on 2026-09-09; the text is byte-identical to what was there.

⚠️ The safety-critical halves stayed in the root file deliberately: the
`app_config` RLS key whitelist, and the fact that the balance-alert threshold
lives in THREE places that will drift. Do not duplicate them here — read them
there.

### Telegram ops bot

`telegram-notify` (cron, every minute) sweeps new signups / credit purchases /
eSIM purchases / line rentals, pages the watchdog verdict, emits a 6-hourly
digest and a 09:00-Paris morning brief; `telegram-webhook` answers 21 commands
(see "Overhaul 2026-08-21" just below). Exactly-once is a claim row in `telegram_events`
(`kind`,`ref` PK) written *before* sending, so the instant path in `iap-verify`
and the sweep can never double-send. Secrets: `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID`, `TELEGRAM_WEBHOOK_SECRET`. The webhook is public and gated
twice — matching `X-Telegram-Bot-Api-Secret-Token` **and** owner chat id — and
returns a silent 200 on every rejection so it isn't an oracle.

#### Overhaul 2026-08-21 — registry, Paris time, autocomplete, new screens

**Commands are a REGISTRY, not an if/else.** `_shared/tgCommands.ts` is the
single source of truth: it generates `/help` AND the Telegram `/` popup menu
(`setMyCommands`, plus the ≡ button via `setChatMenuButton`). `_shared/
tgHandlers.ts` holds the handlers and a pure `runCommand(text)`; `telegram-
webhook/index.ts` is transport only (auth, support routing, send). **Adding a
command = one entry in the registry + one handler; then RE-RUN `telegram-setup`
or the popup menu keeps the old list** — the menu is bot-level state held on
Telegram's side, exactly like the webhook URL.

The set: `/now` (one screen: balances + runway, watchdog, paused flags, today
since midnight Paris, lines + next conversion, support, active alerts),
`/today` `/week` `/stats`, `/trials` (every subscription by `expires_at`, Paris
time, auto-renew on/off, what will bill), `/failures [24h|7d]` (no-number and
no-code orders by route, e-mail/eSIM/call failures, blocked routes),
`/orders`, `/delivery`, `/route <service> [country]` (why something is
unavailable — status, price, pool rate, stock, 7d orders/codes), `/balance`,
`/revenue` `/profit`, `/subs` (only the ENTITLED subscriptions, each with its
expiry in Paris and its price normalised to a MONTH), `/lines` (no arg now LISTS live lines with usage
and real rent; `on|off` unchanged), `/support` (threads waiting, oldest first),
`/alerts` (what is firing + ladder/cooldown states), `/funnel`, `/config`
(read-only: grant, e-mail caps, pause switches, swap price), `/announce`,
`/esim`, `/metrics`, `/help`.

**`/tabs number|temp` (2026-09-09) decides which tab the app OPENS ON** —
`app_config.launch_tab`, read at launch from UserDefaults, effective on the
user's second cold launch. Full account under the line-tab note at the top of
this file; it is the kill switch for the 2026-09-09 decision to lead with the
rented number, which has a measured cost in the other direction.

**`/metrics on|off` (2026-09-03) hides the ONLY delivery figure users see** —
the vendor network rate rendered as High/Medium/Low — by writing
`app_config.delivery_metrics_hidden` (published through the RLS whitelist,
read in the same fetch as `esim_paused`). **Display-only by design:**
`AppState.displayedPoolRate` is what every render site reads (Home hero,
Checkout, ServiceSheet, CountrySheet rows), while steering
(`rankedUntestedKey`, `bestCountry`, the retry picker) and the country sort
keep reading `poolRate` — the owner is hiding a number, not the knowledge.
When hidden, the "Network rate" sort chip is labelled "Recommended" and
loses its ⓘ. **Client-side, so it ships with 2.8**; older builds keep
showing the rate whatever the flag says. Takes effect on cold launch.

**Every timestamp the bot prints is Europe/Paris**, through
`_shared/tgFormat.ts` (`parisFull`, `ago`, `until`, `duration`, `usd`,
`ratio`, `stamp`). Before this every command printed raw UTC ISO strings to an
owner in France. Every command reply ends with a `🕒 … Paris` stamp. Never
format a time any other way in bot code.

**House style, enforced by the formatter tests** (`.claude/tmp/fmt-test.ts`
while the worktree lives; re-create from the renderings if lost): line 1 is
the answer, caveats last in italics, percentages only when n ≥ 5 (`ratio()`
prints "3 of 4" below that), lists capped with "… and N more", never
`undefined`/`NaN`/raw ISO.

**Six new RPCs** (`20260821120000_ops_bot_rpcs.sql`, all service-role only —
asserted `has_function_privilege('anon', …)` = 0 rows): `ops_now()`,
`ops_trials()`, `ops_failures(p_window)`, `ops_support()`, `ops_lines()`,
`ops_route(p_service, p_country)`. Three facts they encode that the code
cannot tell you:
- **`orders` has NO close-reason column.** A numberless order is
  `status='canceled'`, `actual_cost_cents is null`, and that is all — stockout,
  `margin_too_low` and provider fault are indistinguishable at row level. So
  `/failures` says "got no number", never why; the function logs hold the why.
- 🔴 **`orders.provider` DEFAULTS TO `'smspva'` AND IS ONLY OVERWRITTEN WHEN A
  NUMBER IS RESERVED** (`create-order` stamps `provider: used` after a
  successful reservation). So every numberless order — today's entire
  `/failures` "no number" cohort — reads `smspva` whatever provider actually
  refused it, and a grouped-by-provider view would "prove" a retired provider
  is taking orders. Found 2026-08-21 when `/failures` said telegram/co was
  smspva while `/route` said 5sim: the route was 5sim, the orders had never
  been stamped. `ops_failures` and the `route_fill` alert take the provider
  from `routes`, never from a numberless order row. If you ever need the
  truth per order, it is in the function logs, not the column.
- **A trial is `price_milli = 0` on a `.yearly` product in state active/grace.**
  There is no offer-type column; a yearly is the only kind of product with a
  trial, so this heuristic is exact today and wrong the day a $0 promo ships on
  a monthly. `/trials`, `trial_soon` and `trial_off` all share it.
  **`mail.yearly` carries a 3-day trial again (REINSTATED 2026-08-27, owner
  decision); the LINE products carry none.** History: both trials were
  removed by 2026-08-25 because every billing attempt across them failed
  (6/6 line, 1/1 mail, all `DID_FAIL_TO_RENEW` with auto-renew still on).
  The mail one was brought back two days later — the mail sample was n=1
  and $29.99 is a softer conversion than the line's $99.99 — and this time
  it covers **all 175 priced territories** (the 2026-08-19 original was
  base-territory only). Created and read back by
  `scripts/asc-mail-yearly-trial.py` (dry-run by default; idempotent).
  Verified: line 6798759539 offers = empty; mail 6803258736 offers = 175.
  So a `price_milli = 0` row on `mail.yearly` is a real trial; on any LINE
  product it means an offer came back or something is wrong. **`line.monthly`
  (6798378879) carries a PAID $3.99 first-month intro in 175 territories
  since 2026-09-10** (`scripts/asc-line-monthly-intro-offer.py`, same shape):
  its first period rows read `price_milli = 3990`, never 0, and
  `linePlanLabel` marks them "· intro price". The paywalls
  need no release — trial copy reads the live intro offer and appears or
  disappears on its own.
- **"Today" is since midnight Paris**, not UTC — `ops_now` does
  `date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris'`.
- **Every count a formatter prints must be computed in SQL, not over the rows
  it was handed.** `ops_route` caps its `routes` array at 25, so `routes_active`
  (active AND, where the provider publishes a stock figure, non-zero) and
  `routes_total` are BOTH returned; counting the array made the headline an
  artifact of the LIMIT — telegram read "25 of 69 bookable" against 54.
- **The watchdog's "last ran" is `value->>'checked_at'`, NEVER the row's
  `updated_at`.** `telegram-notify` writes `alerted`/`last_alert_at` back onto
  the same `app_config` row on every page, which fires `app_config_touch` — so
  `updated_at` moves without `run_watchdog` having run, and a dead watchdog plus
  one 6-hourly re-page reads as "ran just now". `/now`, `/balance`, `/alerts`
  and `telegram-notify` all treat a verdict older than **30 minutes** as
  `watchdog_stale`, and in `/now` that is the HEADLINE — `/now` is also the
  morning brief, i.e. the one message read daily.

**`telegram-setup` gained a cron-gated preview:** POST `{"preview":"/trials"}`
(same `x-cron-secret` gate, trigger via `net.http_post` + `private_cron_secret()`)
returns the rendered HTML WITHOUT sending it — this is how every command is
verified without the owner's phone. Commands whose registry entry carries
`mutates` (`/announce`, `/esim`, `/lines`, `/metrics`, `/tabs`) are REFUSED in
preview with
`preview_refused_mutating` — without that, the cron secret alone could post a
banner to every user, where from the chat it takes the bot token AND the owner
chat id. `/lines` with no argument is read-only and is refused anyway; the
simplicity is worth more than that one preview.

**Alerts share one shape** — `_shared/tgAlert.ts` `alertHtml({sev, title,
what, why, action, at})`: 🔴 money leaking / product down, 🟠 becomes 🔴
without action, 🟡 degraded, 🟢 recovered or good news, ℹ️ business event. The
watchdog page groups checks into Money / Delivery / Lines / Jobs with a plain-
English line and an action per check (`WATCHDOG_COPY`, one entry per check name
— an unknown check falls back to Jobs + raw detail, so adding a watchdog check
without a copy entry degrades, it does not break). Down-time per check lives in
a NEW key **`app_config.watchdog_since`**, because `run_watchdog()` rebuilds the
`watchdog` row every 10 minutes and drops anything extra written there.

**New alert kinds** (constraint `telegram_events_kind_check` widened in
`20260821130000_ops_bot_alerts.sql`, every pre-existing value repeated):
`trial_soon` (🟠 converts within 24h, ref = original tx), `trial_off` (ℹ️ once
when auto-renew flips off), `route_fill` (🟠 ≥3 no-number orders on one
(service,country) in 60 min, ref = `service|country|UTC-hour` so at most
hourly), `line_consumption` (split from `line_refund` — the two shared
`(kind, originalTx)` and whichever Apple sent first silently ate the other; refs
now carry the notification UUID). Without a kind: `support_waiting` (🟠 a
thread with `last_sender='user'` unanswered > 2h, re-nag every 6h via
`app_config.support_nag`) and the **morning brief** (☀️ `/now` rendering, first
run at/after 09:00 Paris, once per Paris day via `telegram_bot.last_brief_on`
— the `telegram_bot` write now MERGES so it cannot drop `last_digest_at`).

**New service-role-only `app_config` keys — never add them to the RLS
whitelist:** `watchdog_since`, `support_nag`, `esim_alert_low_balance`,
`esim_alert_purchase_failed`, `esim_alert_persist_failed` (the eSIM purchase
alerts were the last unthrottled pagers; now 6h cooldown, stamped only after a
confirmed send, same shape as `alertLowBalanceBlock`).

**`{provider}-float` no longer disarms on zero burn.** `watchdog_money_checks`
used to `continue` when 7-day burn ≤ 0 — the exact state of a dead route. Now
burn = 0 with ≥ 1 numbered order in the prior 7–14 days pages "no spend in 7
days against N orders the week before — route may be dead"; burn = 0 with no
prior orders stays silent. Regenerated from `pg_get_functiondef` and diffed:
exactly one hunk.

**`_shared/telegram.ts` SPLITS instead of truncating** (`splitForTelegram`, cut
at the last newline under 4000 chars, `(i/n)` suffixes, `ok` only if every part
landed). ⚠️ It is bundled per function: **every function that sends to
Telegram must be redeployed** or it keeps the old silent truncation. The two
deploy lists at the top of this file are the redeploy set.

🔴 **A part must be well-formed HTML ON ITS OWN, and the hard-cut path is where
that is easy to lose.** A single line over the budget has no newline to cut at,
so it is cut mid-string: the cut is backed up to before an unclosed `<` (never
through a tag), and any `<b>/<i>/<code>/<pre>` still open at the end of a part
is closed there and REOPENED at the start of the next. Without both, Telegram
answers `400 can't parse entities`, `sendMessage` fails on the FIRST part, and
`claimAndSend` releases the claim — so the same doomed message is rebuilt and
re-fails every minute, forever. `<a>` is deliberately not repaired: reopening
it would have to invent an `href`, which Telegram rejects outright. Covered by
`.claude/tmp/alert-test.ts`.

**`/revenue [24h|7d|30d|90d|all]`** (default `all`) answers exactly one question —
**how much money customers actually paid, in USD** — and derives nothing else.
**`/profit`** is the separate command that nets off Apple's cut and wholesale.
Both read `revenue_snapshot(interval)`; the split is in the formatter
(`formatGross` vs `formatRevenue` in `_shared/opsFormat.ts`). Keep them apart:
`/revenue` answering with a P&L was the thing that made the number hard to trust
at a glance, because a single figure was silently three assumptions deep.

**It does NOT use a hardcoded price table, and must not be "simplified" into
one.** `iap_receipts` stores no price, so the obvious implementation is a
product→USD map next to `PRODUCT_TO_CREDITS`. That is wrong: the store charges
by **storefront**, and ours is not one price — `credits.12` bills **$4.99 in the
USA but €5.99 in France**, `credits.30` **$11.99 vs €12.99**. Sales so far span
USA/FRA/ESP/SVK/BGR in two currencies, so a USD ladder would overstate US
revenue ~17% and misprice every EUR sale. Instead `jws_payload()` base64url-
decodes the Apple JWS we already persist in `raw_jws`, which carries signed
`price` (**milliunits** — 4990 = 4.99), `currency` and `storefront`. It is the
amount actually billed and it self-corrects when ASC prices change.

Three deliberate honesty properties, all load-bearing:
- **Mixed currencies are never silently totalled.** The function returns
  per-currency subtotals; the formatter converts with a hand-set `FX_TO_USD`,
  **prints the rate**, and lists any currency missing from the map as
  unconverted rather than folding it in at 1.0.
- **`APPLE_COMMISSION = 0.15`** assumes the Small Business Program. If vSMS is
  not enrolled it is 0.30 — worth ~$24 of the profit line. The rate is printed
  next to the figure so it can't be read without its assumption.
- **Profit is flagged an upper bound** whenever orders held a number but have no
  `actual_cost_cents` (48 of them, all before 2026-07-13 when cost recording
  started). Orders that never got a number are correctly excluded — nothing was
  reserved, so nothing was paid.

`environment = 'Production'` is filtered and the dev account is excluded from
revenue but its **provider spend is subtracted on its own line** ($4.01 lifetime)
— real cash out, not a cost of serving customers. Note `ops_snapshot`'s `buys`
does **not** filter environment, so the digest counts the one Sandbox receipt
(12 credits, $0 paid) as a purchase; `revenue_snapshot` does not repeat that.

**`/orders [24h|7d|30d|90d|all]`** (default **24h**, not lifetime — it prints one
line per order) answers "what happened to each order", which `/stats` cannot:
route, provider, tier, credits charged, wholesale actually paid, and **how long
the number was held**. Backed by `orders_recent(interval)`; rendered by
`formatOrders` in `_shared/opsFormat.ts`.

Four details that are load-bearing:
- **The dev account is INCLUDED and flagged `dev`**, unlike every analytics
  surface, which excludes it. This is an operational view — "did my test order
  work" is precisely the question, and hiding it would look like the order
  vanished.
- **Outcome reads `otp is not null`, never `status = 'received'`.** A rescued
  code lives on a `canceled` row, so status would report a delivered code as a
  failure — the same rule as every other consumer of order outcomes.
- **`held_s` is on every line** because it is the most diagnostic number here:
  seeing `✖ … 8s` beside `✅ … 58s` makes cancel-before-arrival legible at a
  glance. It is what exposed one user firing 13 google orders at Kenya and
  Indonesia in seven minutes, every one cancelled inside 73 seconds.
- **Orders that never held a number get their own count**, not a place in the
  delivery rate — they died inside `create-order` (stockout, `margin_too_low`)
  and never reserved anything. ⚠️ **The rate is over `settled`, NOT `numbered`
  — corrected 2026-08-08** (see the three commands below).
- Rows are capped at 35 with an explicit *"… and N older, not shown"*. A
  silently truncated list reads as "that was everything".

### `/funnel`, `/delivery`, `/subs`, `/help` (2026-08-08)

Three read-only snapshot functions — `ops_funnel(interval)`,
`ops_delivery(interval)`, `ops_subs()` — plus formatters in `_shared/opsFormat.ts`.
**`/funnel [7d|14d|30d]`** is per-day signups → orders → numbered → codes →
Production purchases, with **cohort** activation and buyer rates over the
signups in the window and the signup grant read live from
`app_config.signup_bonus_credits`. **`/delivery [24h|7d|30d]`** is per provider
with the watchdog verdict, the SMSPVA hidden-route count and one balance line
per provider. **`/subs`** answers ONE question — which
subscriptions are LIVE right now, when does each end, and what is each paying
per month — for BOTH families at once (see the block below). It still *warns
when subs and lines disagree*: a live line with no subscription is rent we pay
for nothing. `/help` lists everything and the unknown-command fallback now
points at it rather than dumping the whole list.

⚠️ **The same commit fixed three measurement defects in `ops_snapshot` /
`orders_recent`, and all three made the bot flatter revenue or delivery:**
`buys` did not filter `environment = 'Production'` (a $0 Sandbox receipt counted
as a sale), and both delivery rates ran over EVERY numbered order — so they were
mostly measuring **user impatience** (~60% of numbered orders are cancelled at a
median 57s and deliver ~1%) and our own **default-landed** pre-selection. The
cohort is now `status in ('received','expired') and not from_default`, identical
to `run_watchdog`'s, which is why `/delivery` and the watchdog now agree exactly
(11/44). Cancels, refusals, rescued codes and default-landed orders each get
their own line instead. Live effect on the 7d digest: **15% → 25%**.

### `/subs` = the live subscriptions only (2026-09-08)

**Owner decision: `/subs` answers ONE question — which subscriptions are LIVE
right now, when does each end, and how much is each paying per month.** It
used to be subscription-STATE counts against LINE-status counts plus a mail
summary: a reconciliation view that never listed a mail subscriber and listed
every expired and revoked line row.

Backed by a new `active_subs` key on `ops_subs()` (migration
`20260908100000`, two hunks, the live prosrc verified md5-identical to
`20260818160004`'s body before editing). Rules that are load-bearing:

- 🔴 **ENTITLED, not "the state column says active".** The predicate is
  `state in ('active','grace') AND greatest(expires_at, grace_expires_at) >
  now()` — byte-identical to `has_email_subscription()` and to the `mail` →
  `active` key beside it. **NEVER `coalesce`**: a subscriber who went through
  a grace period and then renewed carries a STALE `grace_expires_at` in the
  past alongside a fresh, later `expires_at`, and coalesce takes the first
  non-null regardless of which is later — reporting a fully-paid renewed
  subscriber as inactive. That bug shipped once already (fixed 2026-08-19).
- **BOTH families in one list** — `line_subscriptions` and
  `email_subscriptions` are separate Apple groups and one user may hold both,
  so they are rendered as two blocks of the same shape rather than a list plus
  a summary.
- **Money is normalised to a MONTH, and it comes from Apple's own signed
  price** (`price_milli` / `currency` on the row), not from a table. A yearly
  prints both (`$59.99/yr ≈ $5.00/mo`): the yearly figure is the one the owner
  recognises, the monthly one is the only one that can be summed. Rows still
  exist at the pre-2026-09-02 $9.99 monthly, and they render as $9.99 —
  which is the whole point of reading the row.
  `LIST_PRICE_USD` in `_shared/opsFormat.ts` is a FALLBACK ONLY, used where no
  billed price exists, and every figure taken from it is marked `*` with a
  footnote. Keep it in step with the live ASC ladder (line 5.99 / 59.99, mail
  2.99 / 29.99).
- **A `$0` billed price is a FREE PERIOD, and that is an INFERENCE** — no
  offer-type column exists anywhere in this schema. Those rows are counted and
  totalled SEPARATELY ("worth $X/mo if every one converts"), never folded into
  the billed MRR: a trial is not revenue yet.
- **Mixed currencies are never silently added.** Non-USD monthly totals print
  on their own line, unconverted — the same rule `/revenue` follows.
- **A row hidden by the 10-row cap still counts toward the total.** The
  formatter renders every row and throws away the text of the hidden ones;
  without that the MRR figure would silently shrink as subscribers are added.
- **The subs-vs-lines divergence warning survives**, because it is the only
  place either half is checked: a live line with no subscription is rent we
  pay for nothing, a live subscription with no line is a customer paying for
  nothing, and both have happened.
- 🔴 **IT COMPARES APPLE SUBSCRIPTIONS AGAINST APPLE-BILLED LINES ONLY — fixed
  2026-09-08 (`lines_active_apple` / `lines_active_credits`, migration
  `20260908220000`).** It used to count ALL live lines, so the owner's own
  credits-billed test line made it fire permanently: 12 lines against 11 subs,
  every single render. **A warning that is always lit is a warning nobody
  reads**, which is precisely how the next real one gets missed — the same
  reasoning that gave the e-mail domain check its cross-domain condition.
  Verified live through `telegram-setup`'s `{"preview":"/subs"}`: 11 = 11 and
  the warning is gone. Credits lines are SPLIT OUT rather than filtered away
  (`plus N credits-billed line(s) — rent we pay outside Apple`), because a
  credits line that has outlived its funding is still $1/month of Telnyx rent
  — the same leak wearing a different label. The formatter falls back to the
  old all-billing sum when the key is absent, so a stale bundle degrades to
  the previous behaviour instead of reading zero and inverting the warning.

Dropped from the rendering (available elsewhere, and they were not the
question): the raw state histograms, the ASSN 7-day notification table, the
`active_billed` per-currency block and the Telnyx balance line (`/balance`,
`/now` and `/alerts` all carry it). Every one of those KEYS is still in the
payload — nothing was removed from `ops_subs()` — so restoring any of them is
formatter-only.

### Balance alerts: ONE level per provider (2026-09-08)

🔴 **Owner decision: page at 5sim < $5.00, HeroSMS < $5.00, Telnyx < $10.00.
Nothing else.** The four-rung ladder derived from `MAX_ORDER_COST_USD`
(`[37.50, 22.50, 11.25, 7.50]`) is **DELETED** — at the owner's hands-off,
fund-on-demand cadence it meant three warnings before the one that matters, on
the single channel that has to stay readable.

**Telnyx is $10, DOUBLE the SMS providers, and that is deliberate**: a dry
Telnyx balance does not merely block a new sale, it means an EXISTING
subscriber's $1/month number cannot be renewed.

🔴 **THE SAME NUMBER LIVES IN THREE PLACES AND WILL DRIFT. Change them in one
commit:**

| copy | where | what it does |
|---|---|---|
| `BALANCE_ALERT_USD` | `poll-active-orders/index.ts` | the instant Telegram PAGE, once per crossing |
| `LOW_BALANCE_USD` / `TELNYX_LOW_USD` | `_shared/opsFormat.ts` | the "⚠️ top up" DISPLAY on `/balance`, `/now`, `/delivery` |
| `v_floor` | `watchdog_money_checks()` (migration `20260908110000`) | the standing watchdog verdict |

- **`alert_tier` keeps its name and is now 0 or 1**, so every stamped row and
  every reader still parses. The read is **clamped at 1** (`Math.min(...)`):
  rows stamped by the old ladder carry tiers up to 4, and without the clamp a
  provider sitting at `alert_tier: 4` could never satisfy `tier > prevTier`
  again — its page would be permanently disarmed, silently, which is the exact
  failure this function has already shipped once.
- **The RUNWAY check is untouched** (`balance ÷ 7-day burn < 5 days`,
  `watchdog_money_checks`), and so is the zero-burn "route may be dead" branch
  and `create-order`'s `alertLowBalanceBlock` shortfall pager. The absolute
  floor catches "nearly empty"; runway catches "healthy balance, about to be
  spent". Neither subsumes the other: at $0.20/day of burn, $2.00 reads as a
  10-day runway and pages nothing while a single $1.50 route is already
  unfundable.
- 🔴 **Telnyx is now IN `watchdog_money_checks` for the first time.**
  `telnyx_health` has been written minutely since 2026-08-06 and the watchdog
  had never read it. It gets the absolute floor only — it has no `orders`
  rows, so its burn is 0 and it falls out of the runway branch by
  construction. It fired on the live state the moment it landed ($6.00 against
  the $10 floor), which is correct, not a false positive.
- The check NAME stays `<provider>-float` because `_shared/tgAlert.ts` resolves
  its copy from that suffix; `telnyx-float` additionally has its own
  `WATCHDOG_COPY` entry, because the generic fallback says "every order on it
  is refused", which is the wrong consequence for rent.
- Migration procedure followed (a one-line refactor that changes a watchdog
  threshold is a monitoring outage): regenerated from `pg_get_functiondef` and
  diffed against the live definition — exactly the two intended hunks plus the
  new `v_floor` declaration differ; every other clause byte-identical.

⚠️ **`MAX_ORDER_COST_USD` is GONE from `poll-active-orders`** — it existed
only to derive the ladder, and a dead constant named like a live threshold is
how the next reader gets it wrong. `MAX_WHOLESALE_CENTS` in the three syncs is
untouched. **NOT changed, and worth knowing it exists:** `winback/index.ts`'s
`claimSafe = balUsd >= 7.5`, a cohort liveness gate rather than an alert.

### Announcement banner + `/announce`, `/esim` (2026-07-31)

A small owner-written banner on **Home**, posted from Telegram. Ships in 1.6.

```
/announce Your message          → live, info (accent)
/announce warn Your message     → live, amber
/announce off                   → clears it
/announce                       → shows what is currently live
/esim on | /esim off            → set_esim_paused() from the phone
/esim                           → reports which way it is set
/lines on | /lines off          → set_lines_paused() from the phone
/lines                          → reports which way it is set + live line count
```

⚠️ **`/lines` was added 2026-08-06 because `set_lines_paused` had NO CALLER
ANYWHERE.** The kill switch for the one product that bills monthly and costs us
rent per subscriber existed only as a function you had to open a SQL console to
reach — which is exactly the moment you cannot. It mirrors `/esim` including
reporting the live count, so "pausing did nothing" is visible rather than
looking like success.

**Pausing lines stops NEW rentals only**, and the reply says so: existing lines
keep sending, receiving and calling — and keep costing us rent until they lapse
through the normal suspend → release path (no hold since 2026-09-05).

**`app_config` is RLS-restricted to an explicit key WHITELIST, and that is the
only safe way to widen it.** The table also holds `herosms_health` /
`smspva_health` (balances), `watchdog`, `blocked_routes` and sync cursors. The
policy is now:

```sql
app_config_read: SELECT to authenticated
  using (key = any (array['maintenance','announcement','esim_paused',
                          'lines_paused','line_swap_credits',
                          'delivery_metrics_hidden','email_sub_daily_cap',
                          'launch_tab']))
```

⚠️ **EIGHT keys as of 2026-09-09, and this block has claimed three, then six.**
`lines_paused`, `line_swap_credits`, `delivery_metrics_hidden`,
`email_sub_daily_cap` and `launch_tab` were all added later.
Re-read the live policy (`select qual from pg_policies where
tablename='app_config'`) rather than quoting this list. Widening it by one
named key is the ONLY safe way to publish a value; `line_swap_credits` is
published because the swap confirmation dialog must quote a price the owner
can change without a release.

**Never** replace that with `using (true)` — it would publish the balances and
the watchdog verdict to anyone holding the publishable key. Verified after the
change: `anon` reads `herosms_health` → `[]`. `anon` has a table SELECT grant
but **no policy**, so it reads nothing; the app is past `AuthGate` and reads as
`authenticated`.

Three details that are load-bearing:

- **`/announce` reads the RAW message text, not the parsed one.** The webhook
  does `const text = raw.toLowerCase()` before dispatch, so building the
  announcement from `text` would deliver *"esims are back"* to every user.
- **Dismissal is keyed on the announcement's `id`, which changes on every
  post.** Storing a bare "dismissed" Bool would mean the next thing the owner
  writes is invisible to everyone who waved the previous one away — a broadcast
  channel that silently stops broadcasting to exactly the people who have used
  it before.
- **The text is never localized.** It is a human's words rendered verbatim;
  machine-translating it would put words in the owner's mouth. Only the chrome
  around it (dismiss label) is localized. It is also styled distinctly from the
  app's own measured statements — `kind` picks a colour and asserts nothing.

`MAX_ANNOUNCE = 280`, and over-length is **refused rather than truncated**:
truncating would let the owner send a message whose ending nobody reads.

**`telegram-webhook` MUST be deployed `--no-verify-jwt`** (Telegram sends no
Authorization header; `config.toml` now carries `verify_jwt = false` for it,
`telegram-notify` and `telegram-setup`, but the flag on the command line is
still the habit to keep). Deploying it without the flag 401s every update and kills the bot
silently. Assert with an unauthenticated POST: it must return **200** (the
function's own silent rejection), never 401.

