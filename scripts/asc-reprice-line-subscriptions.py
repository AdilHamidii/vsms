#!/usr/bin/env python3
"""Reprice the Second Number subscriptions (owner decision 2026-09-01):
line.monthly $9.99 -> $5.99, line.yearly $99.99 -> $59.99, in every territory.

Same-numeral rule as `asc-mail-territories-and-prices.py`: USD and EUR (and any
currency that can express it) carry the SAME NUMERAL via the price point with
the same tier index as the USA base; everything else takes Apple's equalized
price of the USA point. This is a DECREASE, so `preserveCurrentPrice` is False
— every existing subscriber pays the new, lower price at their next renewal
(Apple applies decreases to all; a preserved price would only matter on a rise).

Dry-run by default; pass --apply to write. Reads every price back afterwards.
Needs PyJWT. The ASC key lives outside the repo at ~/.appstoreconnect/.
"""
import base64
import json
import subprocess
import sys
import time

import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
ISS = "4644ed13-4d98-489e-a94b-687f63946f46"
KID = "R5ZVLBTUR6"
BASE = "https://api.appstoreconnect.apple.com"

# (subscription id, productId, target USA numeral)
TARGETS = [
    ("6798378879", "com.anthersystems.VirtualSIM.line.monthly", "5.99"),
    ("6798759539", "com.anthersystems.VirtualSIM.line.yearly", "59.99"),
]
APPLY = "--apply" in sys.argv

# 🔴 An APPROVED subscription cannot take a price with no startDate — every
# such POST is 409 "Initial price cannot be created again after subscription
# is approved" — and startDate = today is 409 "Invalid startDate". The
# earliest Apple accepts is TOMORROW (probed 2026-09-01). So a reprice is a
# scheduled change that lands at 00:00 the next day, in every territory.
import datetime
START_DATE = (datetime.date.today() + datetime.timedelta(days=1)).isoformat()


def _token():
    return jwt.encode(
        {"iss": ISS, "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
        open(KEY).read(), algorithm="ES256", headers={"kid": KID, "typ": "JWT"})


def call(method, path, body=None):
    args = ["curl", "-s", "-g", "-X", method,
            "-H", f"Authorization: Bearer {_token()}",
            "-H", "Content-Type: application/json",
            "-w", "\n__HTTP__%{http_code}"]
    if body is not None:
        args += ["-d", json.dumps(body)]
    args.append(path if path.startswith("http") else BASE + path)
    out = subprocess.run(args, capture_output=True, text=True).stdout
    txt, _, code = out.rpartition("__HTTP__")
    try:
        data = json.loads(txt.rstrip("\n")) if txt.strip() else {}
    except Exception:
        data = {"_raw": txt[:2000]}
    return int(code), data


def paged(path):
    out, url = [], path
    while url:
        code, d = call("GET", url)
        if code != 200:
            print("GET failed", code, json.dumps(d)[:400]); sys.exit(1)
        out += d.get("data", [])
        url = (d.get("links") or {}).get("next")
    return out


def point_id(sub, terr, tier):
    return base64.b64encode(json.dumps({"s": sub, "t": terr, "p": tier},
                            separators=(",", ":")).encode()).decode().rstrip("=")


def current_prices(sub):
    """territory -> customerPrice for the price in effect (latest startDate, or none)."""
    rows = paged(f"/v1/subscriptions/{sub}/prices?include=subscriptionPricePoint,territory&limit=200")
    # `included` is not returned by paged(); fetch price points by id lazily.
    out = {}
    for p in rows:
        terr = p["relationships"]["territory"]["data"]["id"]
        pt = p["relationships"]["subscriptionPricePoint"]["data"]["id"]
        start = p["attributes"].get("startDate") or ""
        if terr not in out or start >= out[terr][1]:
            out[terr] = (pt, start)
    prices = {}
    for terr, (pt, _) in out.items():
        _, r = call("GET", f"/v1/subscriptionPricePoints/{pt}")
        prices[terr] = (r.get("data", {}).get("attributes") or {}).get("customerPrice")
    return prices


def main():
    for sub, pid, numeral in TARGETS:
        print(f"\n== {pid} -> {numeral}")
        terrs = sorted(t["id"] for t in paged(
            f"/v1/subscriptionAvailabilities/{sub}/availableTerritories?limit=200"))
        print(f"  territories: {len(terrs)}")
        if len(terrs) < 100:
            print("  FAILED: territory read looks wrong, refusing"); sys.exit(1)

        # The USA point carrying the target numeral.
        us_points = paged(f"/v1/subscriptions/{sub}/pricePoints?filter[territory]=USA&limit=200")
        us = [p for p in us_points if (p.get("attributes") or {}).get("customerPrice") == numeral]
        if len(us) != 1:
            print(f"  FAILED: {len(us)} USA points at {numeral}"); sys.exit(1)
        us_point = us[0]["id"]
        us_tier = json.loads(base64.b64decode(us_point + "==").decode())["p"]
        print(f"  USA point {us_point} tier {us_tier}")

        eq = {}
        for p in paged(f"/v1/subscriptionPricePoints/{us_point}/equalizations?include=territory&limit=200"):
            t = ((p.get("relationships") or {}).get("territory") or {}).get("data", {}).get("id")
            if t:
                eq[t] = (p["id"], (p.get("attributes") or {}).get("customerPrice"))
        chosen = {"USA": (us_point, numeral)}
        same = 0
        for t in terrs:
            if t == "USA":
                continue
            pid_same = point_id(sub, t, us_tier)
            _, r = call("GET", f"/v1/subscriptionPricePoints/{pid_same}")
            cp = (r.get("data", {}).get("attributes") or {}).get("customerPrice")
            if cp == numeral:
                chosen[t] = (pid_same, cp); same += 1
            elif t in eq:
                chosen[t] = eq[t]
        missing = [t for t in terrs if t not in chosen]
        print(f"  same-numeral: {same + 1}, equalized: {len(chosen) - same - 1}, no point: {len(missing)} {missing[:6]}")
        for t in ("USA", "FRA", "DEU", "GBR", "CAN", "JPN", "AUS"):
            if t in chosen:
                print(f"    {t} -> {chosen[t][1]}")

        if not APPLY:
            print("  [dry] pass --apply to write"); continue

        ok = fail = 0
        for t, (pt, _) in chosen.items():
            code, r = call("POST", "/v1/subscriptionPrices", {"data": {
                "type": "subscriptionPrices",
                "attributes": {"preserveCurrentPrice": False, "startDate": START_DATE},
                "relationships": {
                    "subscription": {"data": {"type": "subscriptions", "id": sub}},
                    "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": pt}},
                }}})
            if code >= 300:
                fail += 1
                if fail <= 3:
                    print(f"    {t} FAILED {code}: {json.dumps(r)[:300]}")
            else:
                ok += 1
        print(f"  written {ok}, failed {fail}")

        # Read back — an accepted POST is not evidence on this API. The
        # scheduled row carries START_DATE, so `current_prices` (latest
        # startDate wins) reports the price that will be in effect tomorrow.
        now = current_prices(sub)
        bad = {t: v for t, v in now.items() if t in chosen and v != chosen[t][1]}
        print(f"  read back {len(now)} territories; mismatches: {len(bad)} {list(bad.items())[:5]}")
        for t in ("USA", "FRA", "DEU", "GBR", "CAN", "JPN"):
            print(f"    {t} now {now.get(t)}")


main()
