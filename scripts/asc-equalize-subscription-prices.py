#!/usr/bin/env python3
"""Price the subscription in every territory it is available in.

The subscription has ONE `subscriptionPrices` record (USA) while
`subscriptionAvailability` lists 32 territories. ASC's web UI fills the other
31 automatically from the base territory's price point via "equalizations";
creating the base price over the API does not, so the other 31 are genuinely
unpriced — which is a missing-metadata condition the API will not name.

This replicates what the UI does: take the USA price point, ask Apple for its
equivalent in each territory, and create that price. It changes NOTHING about
the product — $9.99 USA stays the anchor, and every other territory gets the
value Apple itself considers equal.

Run with --dry to inspect before writing.

Needs PyJWT: `pip3 install pyjwt`. The ASC key lives outside the repo at
~/.appstoreconnect/private_keys/ and is never committed.
"""
import json
import subprocess
import sys
import time

import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
ISS = "4644ed13-4d98-489e-a94b-687f63946f46"
KID = "R5ZVLBTUR6"
BASE = "https://api.appstoreconnect.apple.com"

SUB = "6798378879"
# The base-territory price point. Read it from
#   GET /v1/subscriptions/{id}/prices?include=subscriptionPricePoint
# if the base price is ever re-created; the id encodes (subscription, territory).
US_POINT = "eyJzIjoiNjc5ODM3ODg3OSIsInQiOiJVU0EiLCJwIjoiMTAxMjcifQ"


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
            print("GET failed", code, json.dumps(d)[:400])
            sys.exit(1)
        out += d.get("data", [])
        url = (d.get("links") or {}).get("next")
    return out


def main():
    dry = "--dry" in sys.argv

    territories = [t["id"] for t in paged(
        f"/v1/subscriptionAvailabilities/{SUB}/availableTerritories?limit=200")]
    print(f"available territories: {len(territories)}")

    existing = set()
    for p in paged(f"/v1/subscriptions/{SUB}/prices?include=territory&limit=200"):
        rel = (p.get("relationships") or {}).get("territory") or {}
        tid = ((rel.get("data") or {}) or {}).get("id")
        if tid:
            existing.add(tid)
    print(f"already priced: {sorted(existing) or '(none resolvable)'}")

    eq = paged(f"/v1/subscriptionPricePoints/{US_POINT}/equalizations"
               f"?include=territory&limit=200")
    point_for = {}
    for p in eq:
        rel = (p.get("relationships") or {}).get("territory") or {}
        tid = ((rel.get("data") or {}) or {}).get("id")
        if tid:
            point_for[tid] = (p["id"], p.get("attributes", {}).get("customerPrice"))
    print(f"equalized price points returned: {len(point_for)}")

    todo = [t for t in territories if t not in existing and t in point_for]
    missing_point = [t for t in territories if t not in point_for]
    if missing_point:
        print(f"NO equalized point for: {missing_point}")

    print(f"to create: {len(todo)}")
    for t in todo[:5]:
        print(f"   {t} -> {point_for[t][1]}")
    if dry:
        return

    ok = fail = 0
    for t in todo:
        point, price = point_for[t]
        code, d = call("POST", "/v1/subscriptionPrices", {
            "data": {
                "type": "subscriptionPrices",
                # No startDate: effective immediately, same as the base price.
                "attributes": {"preserveCurrentPrice": False},
                "relationships": {
                    "subscription": {"data": {"type": "subscriptions", "id": SUB}},
                    "subscriptionPricePoint": {
                        "data": {"type": "subscriptionPricePoints", "id": point}},
                },
            }
        })
        if code in (200, 201):
            ok += 1
        else:
            fail += 1
            if fail <= 3:
                print(f"  {t} FAILED {code}: {json.dumps(d)[:300]}")
    print(f"created {ok}, failed {fail}")

    code, s = call("GET", f"/v1/subscriptions/{SUB}")
    print("subscription state ->",
          s.get("data", {}).get("attributes", {}).get("state"))


if __name__ == "__main__":
    main()
