# vSMS hands-off runbook (owner went absentee 2026-08-29)

The app runs itself — every job is on pg_cron, the watchdog is pure SQL, the
Telegram bot pages on failures and recoveries. The ONLY recurring human duty
is **money in provider accounts**. Everything below is ordered by how fast it
kills revenue if ignored.

## The one habit

Read the ☀️ morning brief (`/now`) the bot sends at 09:00 Paris. Its headline
is the watchdog verdict; if it says anything other than healthy, the message
itself says what to do. Digest silence for a day+ means the bot itself died —
that is the one failure that cannot page, and it's worth a `/now` by hand.

## Top-ups (the actual job)

| account | where | trigger | what dies without it |
|---|---|---|---|
| **HeroSMS** | herosms dashboard | pages at $7.50; ⚠️ **at $4.52 on 2026-08-29 — already below the ceiling, top up now** | the whole temp-EMAIL line (mail subscribers' product) + ~560 SMS routes |
| **5sim** | 5sim.net | pages on the `[37.50, 22.50, 11.25, 7.50]` ladder + runway check | the main SMS product — most of revenue |
| **Telnyx** | telnyx.com | invoice/auto-recharge | rented-number rent + calls (2 active line subs) |

~$50–100 per provider buys weeks at current volume. The bot's `/balance`
shows all balances; `create-order` refuses (never charges) when float is too
low, so a dry balance loses sales, not money.

## Calendar items

- **2027-09-05 — VoIP push certificate expires.** Plain-English: this
  certificate is what lets Telnyx wake an iPhone to ring it for an incoming
  call on a rented number; Apple expires every VoIP certificate after 365
  days, no permanent option. It is a ONCE-A-YEAR ~10-minute chore, not
  maintenance: renew in the Apple developer portal against the SAME key
  (`~/Desktop/telnyx-voip/voip.key` — do not lose it), upload to Telnyx.
  If it lapses the failure is silent (numbers stop ringing, nothing pages) —
  hence a calendar entry, not an alert.
- **Apple annual**: membership renewal, tax/banking agreement re-acceptance —
  Apple emails about these; ignoring them takes the app off sale.
- **Supabase is on the FREE plan — no backups.** Fine while hands-off, but a
  paid plan (~$25/mo) buys point-in-time recovery if the app ever matters.

## Known-degraded, accepted

- **ASA is ABANDONED (owner decision 2026-08-29).** ⚠️ One manual step
  remains: log into ads.apple.com and PAUSE both campaigns (or remove the
  payment method) — the declined card is not a reliable off switch; the
  account historically still spent 2 days out of 3 on it. The API can't do
  it: the repo's ASA credentials no longer authenticate (`invalid_client`).
  Accepted consequence: paid traffic was where the buyers came from; revenue
  now depends entirely on organic search conversion.
- **eSIM line permanently parked** (moved to a separate app, 2026-08-29).
- **2.5 in App Review** as of 2026-08-29; the 2.6 tree (behavioural
  analytics client) is committed but uncut — ship it whenever, or never; the
  server-side geography capture works regardless.

## When the bot pages

Every alert carries its own "action" line. The short version: 🔴 = money
leaking or a product down, act today (usually a top-up); 🟠 = becomes 🔴
without action; 🟡/ℹ️ = read, no action. Recoveries page themselves (✅).
Support messages relay to the same chat — reply to the relayed message and
the user gets it in-app; an unanswered thread re-nags every 6h.
