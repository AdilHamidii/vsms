#!/usr/bin/env python3
"""Widen the mail subscriptions to every territory the line sells in, then
price them there.

    python3 scripts/asc-mail-territories-and-prices.py --dry
    python3 scripts/asc-mail-territories-and-prices.py

TWO STEPS, IN THIS ORDER, AND THE ORDER IS THE POINT.

`asc-create-mail-subscriptions.py` deliberately creates availability for the
BASE TERRITORY ONLY, because a price cannot be created before an availability
exists and pricing 175 territories up front would mean guessing 175 price
points. So the products land available in the USA and nowhere else.

Equalization can only price territories the subscription is AVAILABLE in — so
widening has to happen first, or the equalizer finds nothing to do and reports
success.

⚠️ Creating a base price does NOT propagate. The App Store Connect web UI fills
other territories from the base automatically; the API does not, and a
subscription available in 175 territories with 1 price is an unnamed
MISSING_METADATA condition. Measured on this app before: 32 available, 1
priced, and `?filter[territory]=FRA` returned `total: 0` rather than an error.

The territory set is COPIED FROM THE LINE SUBSCRIPTION rather than typed out,
so the two subscription products cannot drift apart, and so this script keeps
working when the app's territories change.
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

# The reference: whatever the live line subscription sells in.
LINE_SUB = "6798378879"

# (subscription id, base-territory price point id). The point ids are printed
# by asc-create-mail-subscriptions.py; they encode (subscription, territory),
# so they are only valid for their own subscription. Re-read them from
#   GET /v1/subscriptions/{id}/prices?include=subscriptionPricePoint
# if a base price is ever re-created.
MAIL = [
    ("com.anthersystems.VirtualSIM.mail.monthly", "6803258564",
     "eyJzIjoiNjgwMzI1ODU2NCIsInQiOiJVU0EiLCJwIjoiMTAwMzYifQ"),
    ("com.anthersystems.VirtualSIM.mail.yearly", "6803258736",
     "eyJzIjoiNjgwMzI1ODczNiIsInQiOiJVU0EiLCJwIjoiMTAyMjcifQ"),
]

# The base-territory numeral each subscription must keep wherever the currency
# can express it. See the override block in main().
MAIL_PRICE = [("6803258564", "2.99"), ("6803258736", "29.99")]

DRY = "--dry" in sys.argv


def _token():
    return jwt.encode(
        {"iss": ISS, "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
        open(KEY).read(), algorithm="ES256",
        headers={"kid": KID, "typ": "JWT"})


def call(method, path, body=None):
    # `-g` is MANDATORY: ASC filters are written `filter[territory]` and curl
    # treats `[...]` as a range glob, so without it the request is never sent.
    args = ["curl", "-s", "-g", "-w", "\n%{http_code}", "-X", method,
            "-H", f"Authorization: Bearer {_token()}",
            "-H", "Content-Type: application/json", f"{BASE}{path}"]
    if body is not None:
        args += ["-d", json.dumps(body)]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    body_txt, _, code = out.rpartition("\n")
    try:
        return int(code), (json.loads(body_txt) if body_txt.strip() else {})
    except Exception:
        return int(code or 0), {"raw": body_txt[:400]}


def paged(path):
    items = []
    while path:
        _, r = call("GET", path)
        items += r.get("data", [])
        nxt = r.get("links", {}).get("next")
        path = nxt[len(BASE):] if nxt else None
    return items


def main():
    line_terr = sorted(t["id"] for t in paged(
        f"/v1/subscriptionAvailabilities/{LINE_SUB}/availableTerritories?limit=200"))
    print(f"line sells in {len(line_terr)} territories")
    if not line_terr:
        print("FAILED: could not read the line's territories — refusing to guess")
        sys.exit(1)

    for pid, sub, point in MAIL:
        print(f"\n-- {pid}")
        have = sorted(t["id"] for t in paged(
            f"/v1/subscriptionAvailabilities/{sub}/availableTerritories?limit=200"))
        missing = [t for t in line_terr if t not in have]
        print(f"  available in {len(have)}, adding {len(missing)}")

        if missing and not DRY:
            # Added in chunks: the relationship endpoint takes a list, and a
            # single 175-item body is the kind of request that fails as one
            # opaque 4xx rather than telling you which territory it disliked.
            for i in range(0, len(missing), 50):
                chunk = missing[i:i + 50]
                code, r = call(
                    "POST",
                    f"/v1/subscriptionAvailabilities/{sub}/relationships/availableTerritories",
                    {"data": [{"type": "territories", "id": t} for t in chunk]})
                if code >= 300:
                    print(f"  FAILED adding {len(chunk)} territories (HTTP {code}):")
                    print(json.dumps(r, indent=1)[:800])
                    sys.exit(1)
                print(f"  added {len(chunk)}")
        elif missing:
            print(f"  [dry] would add {len(missing)} territories")

        # ── Prices.
        priced = set()
        for p in paged(f"/v1/subscriptions/{sub}/prices?include=territory&limit=200"):
            rel = (p.get("relationships") or {}).get("territory") or {}
            tid = ((rel.get("data") or {}) or {}).get("id")
            if tid:
                priced.add(tid)
        print(f"  already priced in {len(priced)}")

        eq = paged(f"/v1/subscriptionPricePoints/{point}/equalizations"
                   f"?include=territory&limit=200")
        point_for = {}
        for p in eq:
            rel = (p.get("relationships") or {}).get("territory") or {}
            tid = ((rel.get("data") or {}) or {}).get("id")
            if tid:
                point_for[tid] = (p["id"], p.get("attributes", {}).get("customerPrice"))
        print(f"  equalized points available: {len(point_for)}")

        # 🔴 EQUALIZATION IS NOT "THE SAME PRICE ELSEWHERE" — it is Apple's
        # FX conversion, and on this app it drifts the way that breaks ladders.
        # Measured here: the yearly equalizes to €34.99 against a monthly of
        # €2.99, i.e. €35.88/yr vs €34.99 — a 2.5% saving where the USD pair
        # gives 16%. Nobody would ever choose yearly in the Eurozone, which is
        # the same class of defect as the credit ladder drifting to $4.99 vs
        # €5.99.
        #
        # The fix is the repo's standing rule: USD and EUR carry the SAME
        # NUMERAL, everything else equalizes. Rather than hardcode which
        # territories use EUR — a list that rots — try the price point with the
        # SAME TIER INDEX as the USA base (the point id encodes
        # {s: subscription, t: territory, p: tier}) and accept it ONLY if it
        # reads back as the identical numeral. A territory whose currency
        # cannot express that numeral (JPY has no 29.99) simply fails the check
        # and keeps Apple's equalized price.
        us_tier = json.loads(base64.b64decode(point + "==").decode()).get("p")
        target_numeral = dict(MAIL_PRICE)[sub]
        overrides = {}
        for t in [x for x in line_terr if x not in priced]:
            pid_same = base64.b64encode(json.dumps(
                {"s": sub, "t": t, "p": us_tier},
                separators=(",", ":")).encode()).decode().rstrip("=")
            _, r = call("GET", f"/v1/subscriptionPricePoints/{pid_same}")
            cp = (r.get("data", {}).get("attributes") or {}).get("customerPrice")
            if cp == target_numeral:
                overrides[t] = (pid_same, cp)
        print(f"  same-numeral override available in {len(overrides)} territories")

        want = line_terr if not DRY else have + missing
        todo = [t for t in want if t not in priced and (t in point_for or t in overrides)]
        point_for.update(overrides)
        no_point = [t for t in want if t not in point_for and t not in priced]
        if no_point:
            print(f"  NO equalized point for {len(no_point)}: {no_point[:8]}")
        print(f"  to price: {len(todo)}")
        for t in ("FRA", "DEU", "GBR", "JPN"):
            if t in point_for:
                print(f"    {t} -> {point_for[t][1]}")
        if DRY:
            continue

        ok = fail = 0
        for t in todo:
            pt, _price = point_for[t]
            code, r = call("POST", "/v1/subscriptionPrices", {
                "data": {
                    "type": "subscriptionPrices",
                    # No startDate: effective immediately, like the base price.
                    "attributes": {"preserveCurrentPrice": False},
                    "relationships": {
                        "subscription": {"data": {"type": "subscriptions", "id": sub}},
                        "subscriptionPricePoint": {
                            "data": {"type": "subscriptionPricePoints", "id": pt}},
                    },
                }
            })
            if code >= 300:
                fail += 1
                if fail <= 3:
                    print(f"    {t} FAILED {code}: {json.dumps(r)[:200]}")
            else:
                ok += 1
        print(f"  priced {ok}, failed {fail}")


main()
