#!/usr/bin/env python3
"""Apple Search Ads API v5 client — read the account, then spend deliberately.

Search is this app's ENTIRE acquisition channel (see the `aso-listing` skill:
20,884 impressions and all 143 downloads came from App Store search, zero
browse, zero referral). Paid search is therefore the same channel bought
rather than earned, and the organic funnel is the benchmark any campaign has
to beat: US 2.45% impression->tap, 68.4% tap->install.

CREDENTIALS. Four things, and only one of them is a secret:

    clientId / teamId / keyId   identifiers, shown in the Search Ads UI
    private key                 P-256 EC, ES256, NEVER leaves your machine

Apple shows you the PUBLIC key after you upload it. A public key cannot sign,
so it cannot authenticate — if all you have is a `-----BEGIN PUBLIC KEY-----`
blob you are holding the wrong half and must recover the private one from
wherever it was generated (or roll a new pair in the Search Ads UI).

    THE REPO IS PUBLIC. Nothing here is hardcoded. Config is read from
    ~/.searchads/ (outside the tree) or the environment, exactly like the ASC
    key in scripts/asc-equalize-subscription-prices.py.

Setup:

    mkdir -p ~/.searchads && chmod 700 ~/.searchads
    cp <your-private-key>.pem ~/.searchads/private-key.pem
    chmod 600 ~/.searchads/private-key.pem
    cat > ~/.searchads/config.json <<'JSON'
    {"clientId": "SEARCHADS.<uuid>", "teamId": "SEARCHADS.<uuid>", "keyId": "<uuid>"}
    JSON

Usage:

    ./scripts/asa.py doctor            # verify creds + key pair BEFORE anything else
    ./scripts/asa.py acls              # org ids you can act on
    ./scripts/asa.py campaigns
    ./scripts/asa.py adgroups <campaign-id>
    ./scripts/asa.py keywords <campaign-id> <adgroup-id>
    ./scripts/asa.py report [days]     # campaign performance, default 30d

Write commands — these SPEND MONEY and all require an explicit --yes:

    ./scripts/asa.py consolidate --yes   # pause every campaign but the US one
    ./scripts/asa.py create-us --yes     # build the one US campaign
    ./scripts/asa.py budget <id> <eur> --yes

Without --yes each prints exactly what it would send and changes nothing.

    WHY THE BIDS LOOK LOW. Measured from this app's own receipts: $232.59 net
    over 14 buyers, 6.9% of signups buy, so an install is worth $1.15 and
    breakeven CPT is ~$0.60 at a 50% tap->install rate. US Search Ads clears
    €1.50-4.00 on these terms, so bidding at market is 3-6x underwater. This
    campaign bids AT breakeven and accepts thin delivery, because the durable
    return on the spend is the SEARCH TERMS REPORT: App Analytics exposes no
    per-query data at all (`Source Info` is empty on all 650 rows), so paid
    search is the only way to learn which queries convert — and those winners
    then go into the 100-character keyword field, where they are free forever.

Needs PyJWT + cryptography: `pip3 install pyjwt cryptography`.
"""
import json
import os
import subprocess
import sys
import time
from datetime import date, timedelta

import jwt

CONFIG_DIR = os.path.expanduser(os.environ.get("ASA_DIR", "~/.searchads"))
KEY_PATH = os.environ.get("ASA_PRIVATE_KEY", os.path.join(CONFIG_DIR, "private-key.pem"))
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

TOKEN_URL = "https://appleid.apple.com/auth/oauth2/token"
BASE = "https://api.searchads.apple.com/api/v5"

# Apple caps the client-secret JWT at 180 days. Short is fine: it is minted per
# run and never stored.
SECRET_TTL = 1200


def die(msg, *hints):
    print(f"error: {msg}", file=sys.stderr)
    for h in hints:
        print(f"  {h}", file=sys.stderr)
    sys.exit(1)


def config():
    """clientId / teamId / keyId, from env or ~/.searchads/config.json."""
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as fh:
            cfg = json.load(fh)
    for k, env in (("clientId", "ASA_CLIENT_ID"),
                   ("teamId", "ASA_TEAM_ID"),
                   ("keyId", "ASA_KEY_ID")):
        cfg[k] = os.environ.get(env) or cfg.get(k)
        if not cfg[k]:
            die(f"missing {k}",
                f"set ${env} or put it in {CONFIG_PATH}")
    return cfg


def private_key():
    if not os.path.exists(KEY_PATH):
        die(f"no private key at {KEY_PATH}",
            "Apple shows you the PUBLIC key after upload — that half cannot sign.",
            "Recover the private key from where you generated the pair, or create",
            "a new pair in the Search Ads UI (Account Settings -> API).")
    pem = open(KEY_PATH).read()
    if "PUBLIC KEY" in pem:
        die(f"{KEY_PATH} is a PUBLIC key",
            "ES256 signing needs the private half (-----BEGIN EC PRIVATE KEY-----",
            "or -----BEGIN PRIVATE KEY-----).")
    return pem


def client_secret():
    """The ES256 JWT Apple exchanges for an access token."""
    cfg = config()
    now = int(time.time())
    return jwt.encode(
        {"sub": cfg["clientId"],
         "aud": "https://appleid.apple.com",
         "iss": cfg["teamId"],
         "iat": now,
         "exp": now + SECRET_TTL},
        private_key(),
        algorithm="ES256",
        headers={"alg": "ES256", "kid": cfg["keyId"]})


def access_token():
    cfg = config()
    out = subprocess.run(
        ["curl", "-s", "-X", "POST", TOKEN_URL,
         "-H", "Content-Type: application/x-www-form-urlencoded",
         "-H", "Host: appleid.apple.com",
         "--data-urlencode", f"client_id={cfg['clientId']}",
         "--data-urlencode", f"client_secret={client_secret()}",
         "--data-urlencode", "grant_type=client_credentials",
         "--data-urlencode", "scope=searchadsorg",
         "-w", "\n__HTTP__%{http_code}"],
        capture_output=True, text=True).stdout
    txt, _, code = out.rpartition("__HTTP__")
    try:
        data = json.loads(txt.rstrip("\n"))
    except Exception:
        data = {"_raw": txt[:2000]}
    if code.strip() != "200":
        die(f"token exchange failed (HTTP {code.strip()}): {json.dumps(data)[:400]}",
            "invalid_client usually means the clientId/teamId/keyId trio does not",
            "match the uploaded public key — check all four together, not one.")
    return data["access_token"]


def call(method, path, token, org=None, body=None):
    """org=None omits X-AP-Context, which is correct only for /acls."""
    args = ["curl", "-s", "-X", method,
            "-H", f"Authorization: Bearer {token}",
            "-H", "Content-Type: application/json",
            "-w", "\n__HTTP__%{http_code}"]
    if org:
        args += ["-H", f"X-AP-Context: orgId={org}"]
    if body is not None:
        args += ["-d", json.dumps(body)]
    args.append(path if path.startswith("http") else BASE + path)
    out = subprocess.run(args, capture_output=True, text=True).stdout
    txt, _, code = out.rpartition("__HTTP__")
    try:
        data = json.loads(txt.rstrip("\n")) if txt.strip() else {}
    except Exception:
        data = {"_raw": txt[:2000]}
    return int(code or 0), data


def org_id(token):
    org = os.environ.get("ASA_ORG_ID")
    if org:
        return org
    code, data = call("GET", "/acls", token)
    acls = data.get("data") or []
    if code != 200 or not acls:
        die(f"cannot resolve orgId (HTTP {code}): {json.dumps(data)[:300]}")
    if len(acls) > 1:
        print(f"note: {len(acls)} orgs; using {acls[0].get('orgName')}. "
              f"Override with $ASA_ORG_ID.", file=sys.stderr)
    return str(acls[0]["orgId"])


def show(rows, cols):
    if not rows:
        print("(none)")
        return
    widths = [max(len(str(c)), max(len(str(r.get(c, ""))) for r in rows)) for c in cols]
    print("  ".join(str(c).ljust(w) for c, w in zip(cols, widths)))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(str(r.get(c, "")).ljust(w) for c, w in zip(cols, widths)))


def money(v):
    """Search Ads money is {amount: '12.34', currency: 'USD'}."""
    if isinstance(v, dict):
        return f"{v.get('amount', '?')} {v.get('currency', '')}".strip()
    return v if v is not None else ""


# ---------------------------------------------------------------- subcommands

def cmd_doctor():
    """Prove the credentials work before anything depends on them."""
    cfg = config()
    print(f"config    {CONFIG_PATH if os.path.exists(CONFIG_PATH) else '(env)'}")
    for k in ("clientId", "teamId", "keyId"):
        v = cfg[k]
        print(f"  {k:<10} {v[:18]}…{v[-6:]}" if len(v) > 28 else f"  {k:<10} {v}")
    print(f"key       {KEY_PATH}")
    private_key()
    print("  private key present and is not a public key")
    tok = access_token()
    print(f"token     ok ({len(tok)} chars)")
    code, data = call("GET", "/acls", tok)
    if code != 200:
        die(f"/acls returned HTTP {code}: {json.dumps(data)[:300]}")
    for a in data.get("data", []):
        print(f"  org {a.get('orgId')}  {a.get('orgName')}  "
              f"{a.get('currency')}  roles={','.join(a.get('roleNames') or [])}")
    print("\nready.")


def cmd_acls():
    code, data = call("GET", "/acls", access_token())
    print(json.dumps(data, indent=2) if code != 200 else "")
    show(data.get("data", []), ["orgId", "orgName", "currency", "timeZone", "paymentModel"])


def cmd_campaigns():
    tok = access_token()
    code, data = call("GET", "/campaigns?limit=1000", tok, org_id(tok))
    if code != 200:
        die(f"HTTP {code}: {json.dumps(data)[:300]}")
    rows = []
    for c in data.get("data", []):
        rows.append({
            "id": c.get("id"),
            "name": c.get("name"),
            "status": c.get("status"),
            "serving": c.get("servingStatus"),
            "countries": ",".join(c.get("countriesOrRegions") or []),
            "daily": money(c.get("dailyBudgetAmount")),
            "total": money(c.get("budgetAmount")),
            # servingStateReasons is the field that explains a dead campaign.
            # Billing problems surface here and NOWHERE else in the API.
            "why": ",".join(c.get("servingStateReasons") or []),
        })
    show(rows, ["id", "name", "status", "serving", "countries", "daily", "total", "why"])
    stalled = [r for r in rows if r["why"]]
    if stalled:
        print("\nservingStateReasons is set on "
              f"{len(stalled)} campaign(s) — that is why they are not delivering.")
        print("Apple exposes NO billing endpoint; if the reason names payment,")
        print("fix it at ads.apple.com -> Settings -> Billing.")


def cmd_adgroups(campaign):
    tok = access_token()
    code, data = call("GET", f"/campaigns/{campaign}/adgroups?limit=1000", tok, org_id(tok))
    if code != 200:
        die(f"HTTP {code}: {json.dumps(data)[:300]}")
    rows = [{"id": g.get("id"), "name": g.get("name"), "status": g.get("status"),
             "serving": g.get("servingStatus"), "bid": money(g.get("defaultBidAmount")),
             "why": ",".join(g.get("servingStateReasons") or [])}
            for g in data.get("data", [])]
    show(rows, ["id", "name", "status", "serving", "bid", "why"])


def cmd_keywords(campaign, adgroup):
    tok = access_token()
    code, data = call(
        "GET", f"/campaigns/{campaign}/adgroups/{adgroup}/targetingkeywords?limit=1000",
        tok, org_id(tok))
    if code != 200:
        die(f"HTTP {code}: {json.dumps(data)[:300]}")
    rows = [{"id": k.get("id"), "text": k.get("text"), "match": k.get("matchType"),
             "status": k.get("status"), "bid": money(k.get("bidAmount"))}
            for k in data.get("data", [])]
    show(rows, ["id", "text", "match", "status", "bid"])


def cmd_report(days="30"):
    tok = access_token()
    end = date.today()
    start = end - timedelta(days=int(days))
    code, data = call("POST", "/reports/campaigns", tok, org_id(tok), body={
        "startTime": start.isoformat(),
        "endTime": end.isoformat(),
        "selector": {"orderBy": [{"field": "localSpend", "sortOrder": "DESCENDING"}],
                     "pagination": {"offset": 0, "limit": 1000}},
        "granularity": "DAILY",
        "timeZone": "ORTZ",
        "returnRecordsWithNoMetrics": True,
        "returnRowTotals": True,
    })
    if code != 200:
        die(f"HTTP {code}: {json.dumps(data)[:400]}")
    rows = []
    for r in (data.get("data", {}).get("reportingDataResponse", {}).get("row") or []):
        t = r.get("total", {})
        meta = r.get("metadata", {})
        taps, imps = t.get("taps", 0), t.get("impressions", 0)
        installs = t.get("totalInstalls", t.get("installs", 0))
        rows.append({
            "campaign": meta.get("campaignName", "?"),
            "impr": imps,
            "taps": taps,
            "ttr%": f"{100*taps/imps:.2f}" if imps else "-",
            "installs": installs,
            "cr%": f"{100*installs/taps:.1f}" if taps else "-",
            "spend": money(t.get("localSpend")),
            "cpa": (f"{float(t['localSpend']['amount'])/installs:.2f}"
                    if installs and isinstance(t.get("localSpend"), dict) else "-"),
        })
    show(rows, ["campaign", "impr", "taps", "ttr%", "installs", "cr%", "spend", "cpa"])
    print(f"\n{start} .. {end}")
    print("Benchmark to beat — ORGANIC US search: 2.45% ttr, 68.4% tap->install.")
    print("Paid taps that convert well below 68% mean the keyword is off-intent,")
    print("not that the product page is broken.")


# ------------------------------------------------------------ campaign spec
# One campaign, US only, Search Results only. Everything below is tuned for
# CONVERSION rather than reach, because at a $1.15 install value reach is the
# thing that loses money.

ADAM_ID = 6774768570                 # vSMS, from the iTunes lookup by bundle id
CURRENCY = os.environ.get("ASA_CURRENCY", "EUR")
DAILY_BUDGET = os.environ.get("ASA_DAILY_BUDGET", "20")
# A 30-day cap so a runaway cannot outlive a weekend unnoticed.
TOTAL_BUDGET = os.environ.get("ASA_TOTAL_BUDGET", "600")
CAMPAIGN_NAME = "vSMS US — Search Results"

# Exact match only in the earning ad groups. Exact is the whole conversion
# strategy: it buys the query verbatim, so intent is known rather than guessed.
BRAND = ["vsms", "vsms app", "v sms", "vsms temp number"]

CORE = [
    # someone who needs a throwaway number RIGHT NOW
    "temp number", "temporary phone number", "temp phone number",
    "temporary number", "disposable phone number", "burner number",
    "burner phone number", "second phone number", "virtual phone number",
    # the verification job-to-be-done — highest intent in the set
    "receive sms online", "receive sms", "sms verification",
    "sms verification number", "otp number", "verification code app",
    "phone number for verification", "temporary sms", "temp sms",
    # the acquisition hook (owner: email is a hook, not a revenue line)
    "temp mail", "temporary email", "disposable email",
]

# Search Match ON, low bid, ONE job: harvest queries we cannot otherwise see.
# Its installs are a bonus; its search-terms report is the actual deliverable.
DISCOVERY_BID = "0.35"
BRAND_BID = "0.45"
CORE_BID = "0.55"                    # = measured breakeven CPT, not a market bid

# Campaign-level negatives. These protect CONVERSION, which is the whole point
# of the campaign: the paywall lands ~3 minutes after signup, so a free-seeker
# is pure cost, and a navigational query is someone looking for another app.
NEGATIVES = [
    "free", "free sms", "free phone number", "unlimited free", "gratis",
    "hack", "spoof", "prank", "prank call", "fake call",
    "call recorder", "ringtone", "caller id", "reverse lookup",
    "phone number lookup", "number tracker", "track phone",
]

# Navigational brand searches, blocked as EXACT ONLY — never broad.
#
# A BROAD negative on "whatsapp" would also block "whatsapp verification
# number", which is the single highest-intent query this product has; broad
# "google voice" would block "google voice alternative", which is a user
# actively shopping for what we sell. Exact blocks the bare navigational
# search (the person opening WhatsApp) and keeps every qualified variant.
NEGATIVES_EXACT = [
    "textnow", "google voice", "whatsapp", "telegram", "hushed", "burner app",
]


def _eur(amount):
    return {"amount": str(amount), "currency": CURRENCY}


def _confirm(what):
    if "--yes" not in sys.argv:
        print(f"\nDRY RUN — nothing sent. {what}")
        print("Re-run with --yes to apply.")
        return False
    return True


def cmd_consolidate():
    """Pause every campaign that is not the single US one.

    PAUSE, never delete. A deleted campaign takes its history with it, and
    Apple's bid learning does not come back. A paused campaign costs nothing
    and can be revived.
    """
    tok = access_token()
    org = org_id(tok)
    code, data = call("GET", "/campaigns?limit=1000", tok, org)
    if code != 200:
        die(f"HTTP {code}: {json.dumps(data)[:300]}")
    camps = data.get("data", [])
    keep = [c for c in camps if c.get("name") == CAMPAIGN_NAME]
    victims = [c for c in camps
               if c.get("name") != CAMPAIGN_NAME and c.get("status") != "PAUSED"]
    print(f"{len(camps)} campaign(s); keeping "
          f"{keep[0]['id'] if keep else '(none yet — run create-us)'}")
    for c in victims:
        print(f"  pause {c['id']}  {c.get('name')}  "
              f"[{c.get('status')}/{c.get('servingStatus')}]")
    if not victims:
        print("nothing to pause.")
        return
    if not _confirm(f"would pause {len(victims)} campaign(s)"):
        return
    for c in victims:
        code, res = call("PUT", f"/campaigns/{c['id']}", tok, org,
                         body={"campaign": {"status": "PAUSED"}})
        print(f"  {c['id']} -> HTTP {code}"
              + ("" if code == 200 else f" {json.dumps(res)[:200]}"))


def cmd_create_us():
    """Create the one US campaign: 3 ad groups, exact-match core, negatives."""
    campaign = {
        "name": CAMPAIGN_NAME,
        "adamId": ADAM_ID,
        "countriesOrRegions": ["US"],
        "budgetAmount": _eur(TOTAL_BUDGET),
        "dailyBudgetAmount": _eur(DAILY_BUDGET),
        "billingEvent": "TAPS",
        # Search Results ONLY. Search Tab is an awareness placement with no
        # query behind it, so it cannot be bid on intent and converts far worse.
        "supplySources": ["APPSTORE_SEARCH_RESULTS"],
        "adChannelType": "SEARCH",
    }
    groups = [
        ("Brand — exact", BRAND_BID, BRAND, False),
        ("Core intent — exact", CORE_BID, CORE, False),
        ("Discovery — search match", DISCOVERY_BID, [], True),
    ]

    print(f"campaign  {CAMPAIGN_NAME}")
    print(f"  app {ADAM_ID} · US · {DAILY_BUDGET} {CURRENCY}/day "
          f"· cap {TOTAL_BUDGET} {CURRENCY}")
    for name, bid, kws, auto in groups:
        print(f"  adgroup {name}: bid {bid} {CURRENCY}, "
              f"{len(kws) or 'search match'} keyword(s)")
    print(f"  {len(NEGATIVES)} campaign negatives")
    for kw in CORE[:3]:
        print(f"    e.g. exact \"{kw}\"")
    if not _confirm("would create 1 campaign + 3 ad groups"):
        return

    tok = access_token()
    org = org_id(tok)
    code, existing = call("GET", "/campaigns?limit=1000", tok, org)
    if code == 200:
        for c in existing.get("data", []):
            if c.get("name") == CAMPAIGN_NAME:
                die(f"campaign '{CAMPAIGN_NAME}' already exists (id {c['id']})",
                    "edit it rather than creating a second one — this command is",
                    "for standing the campaign up once.")

    code, res = call("POST", "/campaigns", tok, org, body=campaign)
    if code not in (200, 201):
        die(f"campaign create failed HTTP {code}: {json.dumps(res)[:400]}")
    cid = res["data"]["id"]
    print(f"campaign {cid} created")

    code, res = call("POST", f"/campaigns/{cid}/negativekeywords/bulk", tok, org,
                     body=[{"text": t, "matchType": "BROAD"} for t in NEGATIVES])
    print(f"  negatives -> HTTP {code}")

    start = time.strftime("%Y-%m-%dT00:00:00.000")
    for name, bid, kws, auto in groups:
        body = {"name": name, "startTime": start,
                "defaultBidAmount": _eur(bid),
                "automatedKeywordsOptIn": auto,
                "pricingModel": "CPC"}
        code, res = call("POST", f"/campaigns/{cid}/adgroups", tok, org, body=body)
        if code not in (200, 201):
            print(f"  adgroup '{name}' FAILED HTTP {code}: {json.dumps(res)[:300]}")
            continue
        gid = res["data"]["id"]
        print(f"  adgroup {gid} {name}")
        if kws:
            code, res = call(
                "POST", f"/campaigns/{cid}/adgroups/{gid}/targetingkeywords/bulk",
                tok, org,
                body=[{"text": t, "matchType": "EXACT", "bidAmount": _eur(bid)}
                      for t in kws])
            print(f"    {len(kws)} exact keywords -> HTTP {code}")
    print(f"\ndone. Verify: ./scripts/asa.py campaigns")


def cmd_budget(campaign, amount):
    print(f"campaign {campaign} daily budget -> {amount} {CURRENCY}")
    if not _confirm("would change the daily budget"):
        return
    tok = access_token()
    org = org_id(tok)
    code, res = call("PUT", f"/campaigns/{campaign}", tok, org,
                     body={"campaign": {"dailyBudgetAmount": _eur(amount)}})
    print(f"HTTP {code}" + ("" if code == 200 else f" {json.dumps(res)[:300]}"))


# ------------------------------------------------------- the live US campaign
# These are the account's real ids (org 22495890). The US campaign already
# exists with 30 days of history, so we EDIT it rather than building a new one:
# a new campaign throws away Apple's bid learning and every keyword's record.

US_CAMPAIGN = "2144317663"           # "vSMS EN" — becomes US-only
US_ADGROUP = "2149912993"            # "vSMS EN main"
EU_CAMPAIGN = "2144209783"           # paused by `consolidate`

# Measured 2026-08-17 over 30 days. An install is worth $1.15 (= EUR 1.06):
# $232.59 net / 14 buyers, 6.9% of signups buy.
BREAKEVEN_CPA = 1.06

# THE BID RULE, and it is the whole optimisation:
#
#     bid = BREAKEVEN_CPA x (installs / taps)
#
# A tap is only worth what it converts. Bidding one number across keywords
# that convert at 36% and 52% overpays for the first and starves the second —
# which is exactly what this account was doing, and why `sms virtual` (70% of
# all taps, 36.5% CR) sat at CPA 1.61 while `throwaway number` at 50% CR was
# left at a 0.28 bid it could not win volume with.
BID_FLOOR, BID_CEIL = 0.30, 0.70

# The CPA goal handed to Apple's automated bidder. Deliberately a shade BELOW
# breakeven (1.06): a goal is a target the optimiser scatters around, not a
# cap, so aiming exactly at breakeven leaves about half the installs above it.
# The US ran at 1.45 for the last 30 days, so this is a real ~31% cut and will
# cost some volume. That is the trade being made on purpose — it is one number
# and trivially raised if delivery collapses.
CPA_GOAL = 1.00

# Observed conversion per keyword; None = no data yet, use the US average.
US_AVG_CR = 0.427
# (conversion rate, actual CPA in EUR, taps) measured 2026-07-18..08-17.
#
# CPA is the decision variable, NOT the conversion rate: `text verification`
# converts at 50% and still lost money at 1.35, because a high conversion rate
# on an expensive tap is still an expensive install.
OBSERVED = {
    "sms virtual":      (0.365, 1.61, 96),   # 70% of all taps — the money leak
    "temp number":      (0.524, 1.00, 21),   # the one clear winner
    "temp sms":         (0.455, 1.36, 11),
    "sms verification": (0.333, 1.41, 3),
    "text verification":(0.500, 1.35, 2),
    "throwaway number": (0.500, 0.57, 2),    # cheapest in the account, n=2
    "receive sms":      (None,  None, 2),    # 0 installs — too small to judge
}
OBSERVED_CR = {k: v[0] for k, v in OBSERVED.items()}

# ---------------------------------------------------------------- the rewrite
#
# This replaces a list written from intuition BEFORE the account data came back.
# That list would have ADDED `second phone number`, `burner number`,
# `fake phone number` and three e-mail terms — every one of which the evidence
# below says to remove or never buy. Running it as-is would have made the
# campaign worse, which is exactly why the handoff said to replace it.
#
# Every entry carries the aso-connect figure that justifies it, measured against
# the US storefront on 2026-08-17. `pop` is search popularity, `diff` is
# difficulty, and "field" is the rating count of the top organic results — the
# honest measure of whether a one-rating app can rank at all.
#
# THE CONSTRAINT THE WHOLE SET IS BUILT AGAINST. Cost per tap is EUR 0.560 and
# an auction sets it, so keywords barely move it. What they move is
# tap->install, which is CPA's DENOMINATOR: paid runs 38.3% against 68.4%
# organic on the same product page, and breakeven needs 53%. So the question
# for every keyword here is "does this bring someone who wanted THIS product",
# never "is this cheap".

# PAUSE, not delete — reversible in a single call, and it preserves each
# keyword's history so a later reversal starts with its record intact.
#
# Two groups, and the reason differs:
#   1. SECOND-NUMBER INTENT. These sell the rented-line product, which has
#      never connected a call and sends 1 of 7 texts. They are also the least
#      winnable terms in the category: `second phone number` is difficulty 73
#      behind TextNow (915,804 ratings), Text Free (597,406), Text Me
#      (670,356), 2Number (133,785) and Burner (93,385). There is no version
#      of that auction this app wins.
#   2. OWNED BY SOMEONE ELSE ENTIRELY. `otp` returns Google Authenticator
#      (1,156,119 ratings) plus OTP Bank HU and OTP m-bank — a Hungarian retail
#      bank. `one time password` returns Google and Microsoft Authenticator and
#      1Password. Both have taken ZERO impressions here; Apple is being right.
PAUSE_KEYWORDS = [
    "second number", "second phone number", "burner number", "burner phone",
    "private number", "non voip number", "nonvoip number",
    "fake number", "fake phone number",
    "otp", "one time password",
]

# Live but PAUSED in the account today. pop 67 / diff 56, and the 1.41 CPA that
# presumably switched it off rests on THREE taps — far too small a sample to
# have justified it.
UNPAUSE_KEYWORDS = ["sms verification"]

# Genuinely absent from the account, and each scored "Good Target" or
# weak-field by aso-connect.
NEW_KEYWORDS = [
    "sms verify",               # pop 51 / diff 47 — field: 523, 717 ratings
    "get sms code",             # pop 56 / diff 54
    "number for verification",  # pop 57 / diff 60 — SERP is ALL verification apps
    "sms code",                 # pop 61 / diff 58
]

# Already live and already right. Listed so the intended set is legible in one
# place, and so nobody "cleans up" a zero-impression keyword that is a Good
# Target rather than a failure: `receive sms online` (pop 64 / diff 46) and
# `sms online` (65 / 47) are the only two Good Targets in the entire
# verification cluster and BOTH have never taken a tap. Dormant, not dead.
KEEP_KEYWORDS = [
    "temp number",        # 1.00 CPA — top-5 field of 22 / 19 / 3 ratings
    "throwaway number",   # 0.57 CPA, n=2; SERP polluted with 2048 puzzle games
    "temp sms", "receive sms", "receive sms online", "sms online",
    "otp number", "temporary sms", "verification code", "verification number",
]

# HELD DELIBERATELY, and this is sequencing rather than hesitation. 1.61 CPA at
# 1.5x breakeven loses about 0.55 per install — but it is 70% of every tap this
# account has ever taken. Cutting it before the replacements above have a week
# of data takes delivery toward zero, which is the opposite of the goal. Cut it
# in week two, once something else is carrying volume.
HOLD_KEYWORDS = ["sms virtual"]

# NOT ADDED, on purpose — and the numbers make them tempting, which is why this
# list exists rather than a silent omission. `temp mail` scores popularity 86,
# the highest figure measured anywhere in this research, and `temporary email`
# is a Good Target at 71/51. Both are a trap HERE: the e-mail line is free by
# design and has earned ONE credit in its lifetime, so buying taps for it
# against a breakeven set by SMS purchases is precisely how EUR 20/day gets
# spent on people who never pay. E-mail already sits in the 100-character
# keyword field, which costs nothing.
DO_NOT_BUY = ["temp mail", "temporary email", "disposable email"]


def bid_for(cr):
    """Breakeven bid for a keyword converting at `cr`, clamped."""
    return f"{max(BID_FLOOR, min(BID_CEIL, BREAKEVEN_CPA * (cr or US_AVG_CR))):.2f}"


def cmd_optimize_us():
    """US-only, EUR 20/day, per-keyword breakeven bids, plus the missing keywords.

    Order matters: geo and budget first (they bound the spend), then bids, then
    new keywords. If the run dies half way the campaign is already narrowed and
    capped rather than broadened and uncapped.
    """
    print(f"campaign {US_CAMPAIGN} 'vSMS EN' -> US only, "
          f"{DAILY_BUDGET} {CURRENCY}/day")
    print(f"  (US spent ~5 {CURRENCY}/day over the last 30 days, so the cap is")
    print("   a guard rail, not the constraint. Delivery is bid-limited.)")
    print(f"pause    {EU_CAMPAIGN} 'vSMS EU'")
    print(f"adgroup  {US_ADGROUP}: clear endTime (was 2026-08-19 — the ad group")
    print("         was about to expire and take the campaign dark)")
    print("  NOTE bidding is MAX_CONVERSIONS: Apple owns the bid, so neither")
    print("  per-keyword bids nor a cpaGoal can be set. Keywords are the lever.")
    print("\nmeasured 30d record (US) — the input to the keyword rewrite:")
    print(f"  {'keyword':<20}{'taps':>5}{'cr':>7}{'CPA':>7}   verdict "
          f"(breakeven {BREAKEVEN_CPA})")
    for k, (cr, cpa, taps) in sorted(OBSERVED.items(),
                                     key=lambda kv: -(kv[1][2] or 0)):
        if cpa is None:
            v = "no installs — too few taps to judge"
        elif cpa <= BREAKEVEN_CPA:
            v = "KEEP — profitable"
        elif taps >= 10:
            v = f"CUT — {cpa/BREAKEVEN_CPA:.1f}x breakeven on real volume"
        else:
            v = "watch — over breakeven but tiny sample"
        print(f"  {k:<20}{taps:>5}{'n/a' if cr is None else f'{cr*100:.0f}%':>7}"
              f"{'n/a' if cpa is None else f'{cpa:.2f}':>7}   {v}")
    if not _confirm("would edit 1 campaign, pause 1, and retarget 1 ad group"):
        return

    tok = access_token()
    org = org_id(tok)

    # 1. narrow + cap FIRST
    code, res = call("PUT", f"/campaigns/{US_CAMPAIGN}", tok, org, body={
        "campaign": {"countriesOrRegions": ["US"],
                     "dailyBudgetAmount": _eur(DAILY_BUDGET)},
        # MUST be false unless the campaign actually has geo (city/region)
        # targeting to discard. Opting in without it is a 400:
        # OPT_IN_INVALID_FOR_CLEAR_GEO_TARGETING_ON_COUNTRY_OR_REGION_CHANGE.
        "clearGeoTargetingOnCountryOrRegionChange": False})
    print(f"US-only + budget -> HTTP {code}"
          + ("" if code == 200 else f" {json.dumps(res)[:300]}"))

    # 2. one active campaign
    code, res = call("PUT", f"/campaigns/{EU_CAMPAIGN}", tok, org,
                     body={"campaign": {"status": "PAUSED"}})
    print(f"pause vSMS EU    -> HTTP {code}")

    # 3. rebid what already has a record
    code, data = call(
        "GET", f"/campaigns/{US_CAMPAIGN}/adgroups/{US_ADGROUP}"
               "/targetingkeywords?limit=1000", tok, org)
    live = {k.get("text"): k for k in (data.get("data") or [])} if code == 200 else {}
    # 3. The ad group runs Apple's automated bidding (biddingStrategy
    #    MAX_CONVERSIONS), so defaultBidAmount is 0 and PER-KEYWORD BIDS ARE
    #    IGNORED — a bulk bid PUT returns HTTP 200 and changes nothing, which
    #    is how it silently looked like it had worked. Under MAX_CONVERSIONS
    #    the only lever is cpaGoal, so the economics go there instead.
    #
    #    endTime is the other half, and it is the urgent one: this ad group was
    #    set to stop on 2026-08-19. An expired ad group is exactly what took
    #    vSMS EU to NO_AVAILABLE_AD_GROUPS — the campaign stays ENABLED and
    #    simply stops serving, with nothing anywhere reporting a problem.
    #    cpaGoal is NOT a lever either: "cpaGoal must be null for adgroups
    #    under Max Conversions Campaign" (HTTP 400). So under MAX_CONVERSIONS
    #    Apple owns the bid completely, and the ONLY things that move CPA are
    #    the daily budget, the geo, and which keywords and negatives exist.
    #    That is why the keyword set is the whole optimisation here — there is
    #    no bid knob to turn. Regaining one means switching the campaign to
    #    FIXED_BID, which discards Apple's learning and is an owner decision.
    code, res = call("PUT", f"/campaigns/{US_CAMPAIGN}/adgroups/{US_ADGROUP}",
                     tok, org, body={"endTime": None})
    print(f"  endTime cleared -> HTTP {code}"
          + ("" if code == 200 else f" {json.dumps(res)[:300]}"))

    # 4. broaden — this is what actually grows volume.
    # --no-keywords stops here: geo, budget and bids are derived from THIS
    # account's own numbers, but which keywords to add is a research question
    # and is better answered with real keyword-volume data than by my guess.
    if "--no-keywords" in sys.argv:
        print("\n--no-keywords: skipped adding keywords and negatives.")
        print("Structure and bids are applied; the keyword set is untouched.")
        return
    fresh = [t for t in NEW_KEYWORDS if t not in live]
    if fresh:
        code, res = call(
            "POST", f"/campaigns/{US_CAMPAIGN}/adgroups/{US_ADGROUP}"
                    "/targetingkeywords/bulk", tok, org,
            body=[{"text": t, "matchType": "EXACT", "bidAmount": _eur(bid_for(None))}
                  for t in fresh])
        print(f"  +{len(fresh)} keywords -> HTTP {code}"
              + ("" if code in (200, 201) else f" {json.dumps(res)[:300]}"))

    # 5. protect conversion
    code, res = call(
        "POST", f"/campaigns/{US_CAMPAIGN}/negativekeywords/bulk", tok, org,
        body=[{"text": t, "matchType": "BROAD"} for t in NEGATIVES]
             + [{"text": t, "matchType": "EXACT"} for t in NEGATIVES_EXACT])
    print(f"  negatives -> HTTP {code}")
    print("\ndone. Re-check in 7 days: ./scripts/asa.py report 7")


def cmd_rewrite_keywords():
    """Apply the evidence-backed keyword set: pause off-intent, unpause, add.

    Deliberately does NOT touch the campaign's geo, budget or the EU campaign —
    those are separate decisions with their own blast radius, and this command
    exists to change exactly one thing: which queries the account buys.

    EVERY write is verified by reading the keyword list back and comparing
    status, because this account returns HTTP 200 for writes it silently
    ignores (a bulk bid PUT does exactly that under MAX_CONVERSIONS). A status
    code is not evidence here; the read-back is.
    """
    tok = access_token()
    org = org_id(tok)

    code, data = call(
        "GET", f"/campaigns/{US_CAMPAIGN}/adgroups/{US_ADGROUP}"
               "/targetingkeywords?limit=1000", tok, org)
    if code != 200:
        die(f"could not read live keywords: HTTP {code}")
    live = {k.get("text"): k for k in (data.get("data") or [])}

    to_pause = [(t, live[t]) for t in PAUSE_KEYWORDS
                if t in live and live[t].get("status") != "PAUSED"]
    to_resume = [(t, live[t]) for t in UNPAUSE_KEYWORDS
                 if t in live and live[t].get("status") != "ACTIVE"]
    to_add = [t for t in NEW_KEYWORDS if t not in live]
    missing = [t for t in PAUSE_KEYWORDS + UNPAUSE_KEYWORDS if t not in live]

    print(f"ad group {US_ADGROUP} 'vSMS EN main' — {len(live)} keywords live\n")
    print(f"  PAUSE  {len(to_pause):>2}  off-intent (second-number) + "
          f"authenticator-owned")
    for t, _ in to_pause:
        print(f"           - {t}")
    print(f"  RESUME {len(to_resume):>2}")
    for t, _ in to_resume:
        print(f"           + {t}")
    print(f"  ADD    {len(to_add):>2}  scored Good Target / weak field")
    for t in to_add:
        print(f"           + {t}")
    print(f"  HOLD   {len(HOLD_KEYWORDS):>2}  {', '.join(HOLD_KEYWORDS)}"
          f"  (70% of taps — cut in week two, not now)")
    print(f"  NEVER  {len(DO_NOT_BUY):>2}  {', '.join(DO_NOT_BUY)}"
          f"  (free product, no revenue)")
    print(f"  negatives: {len(NEGATIVES)} broad + {len(NEGATIVES_EXACT)} exact"
          f"  (the account currently has none)")
    if missing:
        print(f"\n  note: {len(missing)} planned keyword(s) not in the account, "
              f"skipped: {', '.join(missing)}")

    if not _confirm(f"pause {len(to_pause)}, resume {len(to_resume)}, "
                    f"add {len(to_add)}, and set negatives"):
        return

    def bulk_status(rows, label):
        if not rows:
            return
        code, res = call(
            "PUT", f"/campaigns/{US_CAMPAIGN}/adgroups/{US_ADGROUP}"
                   "/targetingkeywords/bulk", tok, org,
            body=[{"id": k["id"], "status": s} for _, k, s in rows])
        print(f"  {label} -> HTTP {code}"
              + ("" if code in (200, 201) else f" {json.dumps(res)[:300]}"))

    bulk_status([(t, k, "PAUSED") for t, k in to_pause], f"pause {len(to_pause)}")
    bulk_status([(t, k, "ACTIVE") for t, k in to_resume], f"resume {len(to_resume)}")

    if to_add:
        code, res = call(
            "POST", f"/campaigns/{US_CAMPAIGN}/adgroups/{US_ADGROUP}"
                    "/targetingkeywords/bulk", tok, org,
            body=[{"text": t, "matchType": "EXACT",
                   "bidAmount": _eur(bid_for(None))} for t in to_add])
        print(f"  add {len(to_add)} -> HTTP {code}"
              + ("" if code in (200, 201) else f" {json.dumps(res)[:300]}"))

    code, res = call(
        "POST", f"/campaigns/{US_CAMPAIGN}/negativekeywords/bulk", tok, org,
        body=[{"text": t, "matchType": "BROAD"} for t in NEGATIVES]
             + [{"text": t, "matchType": "EXACT"} for t in NEGATIVES_EXACT])
    print(f"  negatives -> HTTP {code}"
          + ("" if code in (200, 201) else f" {json.dumps(res)[:300]}"))

    # ---- verify by READ-BACK, not by status code -------------------------
    print("\nverifying against the live account...")
    code, data = call(
        "GET", f"/campaigns/{US_CAMPAIGN}/adgroups/{US_ADGROUP}"
               "/targetingkeywords?limit=1000", tok, org)
    if code != 200:
        die(f"could not re-read keywords: HTTP {code}")
    now = {k.get("text"): k for k in (data.get("data") or [])}
    bad = []
    for t in PAUSE_KEYWORDS:
        if t in now and now[t].get("status") != "PAUSED":
            bad.append(f"{t}: expected PAUSED, is {now[t].get('status')}")
    for t in UNPAUSE_KEYWORDS:
        if t in now and now[t].get("status") != "ACTIVE":
            bad.append(f"{t}: expected ACTIVE, is {now[t].get('status')}")
    for t in NEW_KEYWORDS:
        if t not in now:
            bad.append(f"{t}: expected to exist, absent")
    active = sum(1 for k in now.values() if k.get("status") == "ACTIVE")
    if bad:
        print(f"  ✗ {len(bad)} discrepancy(ies) — the API accepted a write it ignored:")
        for b in bad:
            print(f"      {b}")
        sys.exit(1)
    print(f"  ✓ every change verified. {len(now)} keywords, {active} ACTIVE.")
    print("\nRe-check in 7 days: ./scripts/asa.py report 7")
    print("The number to watch is tap->install, not CPA: breakeven is 53%,")
    print("it is 38.3% today, and organic on the same page does 68.4%.")


# ------------------------------------------ the second-number campaigns (2026-09-05)
# Plan, scores and kill rules: docs/asa-second-number-plan.md. Two NEW campaigns
# with FIXED CPT bids (pricingModel CPC + per-keyword bidAmount) so a keyword
# can actually be steered — the old EN campaign is MAX_CONVERSIONS and has no
# bid knob. The old EN/EU campaigns stay paused as the temp-SMS control.
#
# Keywords are EXACT only. Bids are in the org currency (EUR). Every write is
# read back below; this account answers HTTP 200 to writes it ignores.

NUMBER_DAILY_BUDGET = 10          # per campaign → €20/day total

NUMBER_US = {
    "name": "vSMS Number US",
    "countries": ["US"],
    "adgroups": [
        ("WhatsApp — exact", 0.90, [
            "second number for whatsapp", "virtual number for whatsapp",
            "whatsapp number", "number for whatsapp business",
            "whatsapp verification number",
        ]),
        ("Second number — exact", 0.80, [
            "second phone number", "second number", "2nd phone number",
            "burner number", "burner phone", "temporary phone number",
            "virtual phone number", "private number", "us phone number",
            "canada phone number", "phone number app",
        ]),
        ("Conquest — exact", 0.45, [
            "burner", "hushed", "textnow", "text free", "2ndline", "sideline",
            "line2", "phoner", "dingtone", "talkatone", "google voice alternative",
        ]),
    ],
}

NUMBER_EU = {
    "name": "vSMS WhatsApp EU",
    "countries": ["DE", "FR", "ES", "IT", "NL", "GB"],
    "adgroups": [
        ("DE — exact", 0.45, [
            "zweite whatsapp nummer", "virtuelle nummer whatsapp", "whatsapp nummer",
            "virtuelle nummer", "temporäre nummer", "us nummer",
        ]),
        ("FR — exact", 0.45, [
            "deuxième numéro whatsapp", "numéro virtuel whatsapp", "numéro whatsapp",
            "numéro virtuel", "numéro temporaire", "numéro jetable",
        ]),
        ("ES — exact", 0.40, [
            "segundo número whatsapp", "número virtual whatsapp", "número whatsapp",
            "número virtual", "número temporal", "recibir sms",
        ]),
        ("IT — exact", 0.40, [
            "secondo numero whatsapp", "numero virtuale whatsapp",
            "numero temporaneo whatsapp", "numero virtuale", "numero temporaneo",
            "ricevere sms",
        ]),
        ("EN intl — exact", 0.50, [
            "second number for whatsapp", "virtual number for whatsapp",
            "whatsapp number", "virtual number", "us phone number",
            "second phone number",
        ]),
    ],
}

# The two campaigns share one negative list. `esim` / `data plan` keep vSMS out
# of the sibling app's auctions; the EXACT set blocks bare navigational brand
# searches ONLY — a BROAD "whatsapp" would kill "whatsapp verification number".
NUMBER_NEGATIVES_BROAD = NEGATIVES + ["spy", "esim", "data plan"]
NUMBER_NEGATIVES_EXACT = NEGATIVES_EXACT


def _create_number_campaign(tok, org, spec):
    """Create one campaign + ad groups + keywords + negatives, reading back each.
    Returns (campaign_id, [(adgroup_id, name, wanted, live)])."""
    body = {
        "name": spec["name"],
        "adamId": ADAM_ID,
        "countriesOrRegions": spec["countries"],
        "dailyBudgetAmount": _eur(NUMBER_DAILY_BUDGET),
        "billingEvent": "TAPS",
        # Search Results ONLY — the Search Tab has no query behind it.
        "supplySources": ["APPSTORE_SEARCH_RESULTS"],
        "adChannelType": "SEARCH",
        "status": "ENABLED",
    }
    code, res = call("POST", "/campaigns", tok, org, body=body)
    if code not in (200, 201):
        die(f"campaign '{spec['name']}' create failed HTTP {code}: {json.dumps(res)[:500]}")
    cid = res["data"]["id"]
    print(f"campaign {cid} '{spec['name']}' created "
          f"({','.join(spec['countries'])}, {NUMBER_DAILY_BUDGET} {CURRENCY}/day)")

    code, res = call("POST", f"/campaigns/{cid}/negativekeywords/bulk", tok, org,
                     body=[{"text": t, "matchType": "BROAD"} for t in NUMBER_NEGATIVES_BROAD]
                        + [{"text": t, "matchType": "EXACT"} for t in NUMBER_NEGATIVES_EXACT])
    print(f"  negatives -> HTTP {code}")

    start = time.strftime("%Y-%m-%dT00:00:00.000")
    groups = []
    for name, bid, kws in spec["adgroups"]:
        gbody = {"name": name, "startTime": start,
                 "defaultBidAmount": _eur(bid),
                 "automatedKeywordsOptIn": False,
                 "pricingModel": "CPC", "status": "ENABLED"}
        code, res = call("POST", f"/campaigns/{cid}/adgroups", tok, org, body=gbody)
        if code not in (200, 201):
            print(f"  adgroup '{name}' FAILED HTTP {code}: {json.dumps(res)[:300]}")
            continue
        gid = res["data"]["id"]
        code, res = call(
            "POST", f"/campaigns/{cid}/adgroups/{gid}/targetingkeywords/bulk", tok, org,
            body=[{"text": t, "matchType": "EXACT", "bidAmount": _eur(bid),
                   "status": "ACTIVE"} for t in kws])
        # READ BACK — the only evidence that counts on this API.
        rc, live = call("GET", f"/campaigns/{cid}/adgroups/{gid}/targetingkeywords?limit=1000",
                        tok, org)
        live_n = len((live.get("data") or [])) if rc == 200 else -1
        print(f"  adgroup {gid} '{name}' bid {bid} {CURRENCY}: "
              f"{len(kws)} keywords sent (HTTP {code}), {live_n} live")
        groups.append((gid, name, len(kws), live_n))
    return cid, groups


def cmd_create_number_campaigns():
    """Stand up the two second-number campaigns from docs/asa-second-number-plan.md."""
    for spec in (NUMBER_US, NUMBER_EU):
        n_kw = sum(len(k) for _, _, k in spec["adgroups"])
        print(f"{spec['name']}: {','.join(spec['countries'])} · "
              f"{NUMBER_DAILY_BUDGET} {CURRENCY}/day · {len(spec['adgroups'])} ad groups · "
              f"{n_kw} exact keywords")
        for name, bid, kws in spec["adgroups"]:
            print(f"    {name:<24} bid {bid:.2f}  {len(kws):>2} kw  e.g. \"{kws[0]}\"")
    print(f"negatives: {len(NUMBER_NEGATIVES_BROAD)} broad + {len(NUMBER_NEGATIVES_EXACT)} exact, per campaign")
    total_kw = sum(len(k) for spec in (NUMBER_US, NUMBER_EU) for _, _, k in spec["adgroups"])
    total_groups = sum(len(spec["adgroups"]) for spec in (NUMBER_US, NUMBER_EU))
    if not _confirm(f"would create 2 campaigns, {total_groups} ad groups, "
                    f"{total_kw} keywords, negatives"):
        return

    tok = access_token()
    org = org_id(tok)
    code, existing = call("GET", "/campaigns?limit=1000", tok, org)
    names = {c.get("name") for c in (existing.get("data") or [])} if code == 200 else set()
    for spec in (NUMBER_US, NUMBER_EU):
        if spec["name"] in names:
            die(f"campaign '{spec['name']}' already exists — edit it, do not duplicate it")

    results = [_create_number_campaign(tok, org, spec) for spec in (NUMBER_US, NUMBER_EU)]

    # Final read-back: status + serving state per campaign, straight from the API.
    print("\nread-back:")
    code, data = call("GET", "/campaigns?limit=1000", tok, org)
    by_id = {str(c["id"]): c for c in (data.get("data") or [])} if code == 200 else {}
    bad = []
    for cid, groups in results:
        c = by_id.get(str(cid), {})
        print(f"  {cid} {c.get('name')}: status {c.get('status')} · "
              f"serving {c.get('servingStatus')} {c.get('servingStateReasons') or ''} · "
              f"daily {money(c.get('dailyBudgetAmount'))}")
        for gid, name, wanted, live in groups:
            if wanted != live:
                bad.append(f"{cid}/{gid} '{name}': sent {wanted} keywords, {live} live")
    if bad:
        print(f"  ✗ {len(bad)} discrepancy(ies):")
        for b in bad:
            print(f"      {b}")
        sys.exit(1)
    print("  ✓ every keyword read back. Check impressions tomorrow: ./scripts/asa.py report 1")


COMMANDS = {
    "doctor": cmd_doctor, "acls": cmd_acls, "campaigns": cmd_campaigns,
    "adgroups": cmd_adgroups, "keywords": cmd_keywords, "report": cmd_report,
    "consolidate": cmd_consolidate, "create-us": cmd_create_us,
    "budget": cmd_budget, "optimize-us": cmd_optimize_us,
    "rewrite-keywords": cmd_rewrite_keywords,
    "create-number-campaigns": cmd_create_number_campaigns,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(0 if len(sys.argv) < 2 else 1)
    # flags are read from sys.argv directly (see _confirm), never positionally
    args = [a for a in sys.argv[2:] if not a.startswith("--")]
    try:
        COMMANDS[sys.argv[1]](*args)
    except TypeError as e:
        die(f"bad arguments for '{sys.argv[1]}': {e}")


if __name__ == "__main__":
    main()
