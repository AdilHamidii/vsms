#!/usr/bin/env python3
"""Create the PAY_AS_YOU_GO introductory offer on line.monthly (6798378879):
the FIRST MONTH at $3.99, then the regular $5.99 — in EVERY territory the
subscription is sold in. Owner decision 2026-09-10 ("genuinely the best I can
do"); a FREE trial was declined on 09-09 because each number costs $1 upfront
and 9 of 9 trial takers never converted. A paid intro covers that dollar.

Why this shape and not another:
- Offers are PER TERRITORY (the 2026-08-19 mail trial covered the base
  territory only and had to be re-run), so this loops all of them.
- A PAY_AS_YOU_GO offer needs a `subscriptionPricePoint`; same-numeral rule as
  the reprice script: USD and EUR carry 3.99 via the price point with the
  USA tier index, everything else takes Apple's equalization of the USA point.
- `duration` must equal the subscription period for PAY_AS_YOU_GO, so
  ONE_MONTH × numberOfPeriods 1.

Dry-run by default; pass --apply to write. Idempotent: territories already
holding an offer are skipped. The result is READ BACK — an accepted POST is
not evidence on this API. Needs PyJWT; the key lives outside the repo.

Eligibility is Apple's: ONE introductory offer per subscription GROUP per
Apple ID, so nobody who ever held a line subscription (including the 2026-08
yearly trial takers) sees it. The client renders the intro price only after
`isEligibleForIntroOffer` confirms it (`SubscriptionStore.monthlyIntroOffer`).
"""
import base64
import json
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
ISS = "4644ed13-4d98-489e-a94b-687f63946f46"
KID = "R5ZVLBTUR6"
BASE = "https://api.appstoreconnect.apple.com"

SUB = "6798378879"  # com.anthersystems.VirtualSIM.line.monthly
NUMERAL = "3.99"
APPLY = "--apply" in sys.argv


def _token():
    return jwt.encode(
        {"iss": ISS, "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
        open(KEY).read(), algorithm="ES256", headers={"kid": KID, "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(
        path if path.startswith("http") else BASE + path,
        data=json.dumps(body).encode() if body is not None else None, method=method,
        headers={"Authorization": f"Bearer {_token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {}


def paged(path, include=None):
    """All `data` rows plus every `included` row across pages."""
    data, included, url = [], [], path
    while url:
        code, d = call("GET", url)
        if code != 200:
            print("GET failed", code, json.dumps(d)[:400]); sys.exit(1)
        data += d.get("data", [])
        included += d.get("included", [])
        url = (d.get("links") or {}).get("next")
    return data, included


def point_id(terr, tier):
    return base64.b64encode(json.dumps({"s": SUB, "t": terr, "p": tier},
                            separators=(",", ":")).encode()).decode().rstrip("=")


def offers_by_territory():
    """territory -> customerPrice of the offer's price point (None for a trial)."""
    rows, inc = paged(f"/v1/subscriptions/{SUB}/introductoryOffers"
                      "?limit=200&include=territory,subscriptionPricePoint")
    points = {i["id"]: (i.get("attributes") or {}).get("customerPrice")
              for i in inc if i["type"] == "subscriptionPricePoints"}
    out = {}
    for o in rows:
        rel = o.get("relationships") or {}
        t = ((rel.get("territory") or {}).get("data") or {}).get("id")
        p = ((rel.get("subscriptionPricePoint") or {}).get("data") or {}).get("id")
        if t:
            out[t] = (points.get(p), (o.get("attributes") or {}).get("offerMode"))
    return out


def main():
    terrs, _ = paged(f"/v1/subscriptionAvailabilities/{SUB}/availableTerritories?limit=200")
    terrs = sorted(t["id"] for t in terrs)
    print(f"territories: {len(terrs)}")
    if len(terrs) < 100:
        print("FAILED: territory read looks wrong, refusing"); sys.exit(1)

    have = offers_by_territory()
    print(f"territories already holding an offer: {len(have)}")

    # The USA point carrying the target numeral, and its tier index.
    us_points, _ = paged(f"/v1/subscriptions/{SUB}/pricePoints?filter[territory]=USA&limit=200")
    us = [p for p in us_points if (p.get("attributes") or {}).get("customerPrice") == NUMERAL]
    if len(us) != 1:
        print(f"FAILED: {len(us)} USA points at {NUMERAL}"); sys.exit(1)
    us_point = us[0]["id"]
    us_tier = json.loads(base64.b64decode(us_point + "==").decode())["p"]
    print(f"USA point {us_point} tier {us_tier}")

    eq = {}
    rows, _ = paged(f"/v1/subscriptionPricePoints/{us_point}/equalizations?include=territory&limit=200")
    for p in rows:
        t = ((p.get("relationships") or {}).get("territory") or {}).get("data", {}).get("id")
        if t:
            eq[t] = (p["id"], (p.get("attributes") or {}).get("customerPrice"))

    chosen = {"USA": (us_point, NUMERAL)}
    same = 0
    for t in terrs:
        if t == "USA" or t in have:
            continue
        code, r = call("GET", f"/v1/subscriptionPricePoints/{point_id(t, us_tier)}")
        cp = (r.get("data", {}).get("attributes") or {}).get("customerPrice") if code == 200 else None
        if cp == NUMERAL:
            chosen[t] = (point_id(t, us_tier), cp); same += 1
        elif t in eq:
            chosen[t] = eq[t]
    todo = {t: v for t, v in chosen.items() if t not in have}
    missing = [t for t in terrs if t not in chosen and t not in have]
    print(f"to create: {len(todo)} (same-numeral {same + (0 if 'USA' in have else 1)}, "
          f"equalized {len(todo) - same - (0 if 'USA' in have else 1)}); no point: {len(missing)} {missing[:6]}")
    for t in ("USA", "FRA", "DEU", "GBR", "CAN", "JPN", "AUS", "IND", "BRA"):
        if t in chosen:
            print(f"  {t} -> {chosen[t][1]}")

    if not APPLY:
        print("[dry] pass --apply to write"); return

    ok, fail = 0, []
    for t, (pt, _) in todo.items():
        code, r = call("POST", "/v1/subscriptionIntroductoryOffers", {"data": {
            "type": "subscriptionIntroductoryOffers",
            "attributes": {"duration": "ONE_MONTH", "offerMode": "PAY_AS_YOU_GO",
                           "numberOfPeriods": 1},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": SUB}},
                "territory": {"data": {"type": "territories", "id": t}},
                "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": pt}},
            }}})
        if code < 300:
            ok += 1
        else:
            fail.append((t, code, json.dumps(r)[:200]))
        time.sleep(0.15)
    print(f"created {ok}, failed {len(fail)}")
    for f in fail[:5]:
        print("  FAIL", f)

    # Read back — the only evidence.
    back = offers_by_territory()
    bad = {t: v for t, v in back.items() if t in chosen and v[0] != chosen[t][1]}
    print(f"read-back: offers now cover {len(back)} of {len(terrs)} territories; "
          f"price mismatches: {len(bad)} {list(bad.items())[:5]}")
    for t in ("USA", "FRA", "DEU", "GBR", "CAN", "JPN"):
        print(f"  {t} now {back.get(t)}")
    still = sorted(set(terrs) - set(back))
    print("missing:", still if still else "none")


main()
