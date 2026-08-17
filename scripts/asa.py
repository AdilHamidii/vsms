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
    # navigational — the searcher wants that app, not ours
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


COMMANDS = {
    "doctor": cmd_doctor, "acls": cmd_acls, "campaigns": cmd_campaigns,
    "adgroups": cmd_adgroups, "keywords": cmd_keywords, "report": cmd_report,
    "consolidate": cmd_consolidate, "create-us": cmd_create_us,
    "budget": cmd_budget,
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
