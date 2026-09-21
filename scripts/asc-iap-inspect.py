#!/usr/bin/env python3
"""Read the live in-app-purchase catalogue: state, localizations, prices.

Read-only. Exists because the product-level `state` LIES about submittability
— `credits.60` and `credits.150` both read `READY_TO_SUBMIT` on 2026-07-25
while being in completely different situations — so the truth has to be read
from the VERSION and the price schedule, not the product row.

Usage: python3 scripts/asc-iap-inspect.py [productId-substring]
"""
import json, sys, time, urllib.request, urllib.error
import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS, APP = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46", "6774768570"
WANT = sys.argv[1] if len(sys.argv) > 1 else ""

tok = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1200,
                  "aud": "appstoreconnect-v1"}, open(KEY).read(), algorithm="ES256",
                 headers={"kid": KID})
H = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 data=data, method=method, headers=H)
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r) if r.status != 204 else {}
    except urllib.error.HTTPError as e:
        return {"__error": e.code, "__body": e.read().decode()[:400]}


iaps = call("GET", f"/v1/apps/{APP}/inAppPurchasesV2?limit=200").get("data", [])
for p in sorted(iaps, key=lambda x: x["attributes"]["productId"]):
    a, pid, iid = p["attributes"], p["attributes"]["productId"], p["id"]
    if WANT and WANT not in pid:
        continue
    print(f"\n=== {pid}")
    print(f"    id={iid} name={a.get('name')!r} type={a.get('inAppPurchaseType')} "
          f"state={a.get('state')}")

    v = call("GET", f"/v2/inAppPurchases/{iid}/iapPriceSchedule"
                    "?include=manualPrices&limit[manualPrices]=50")
    inc = v.get("included", [])
    mp = [i for i in inc if i["type"] == "inAppPurchasePrices"]
    print(f"    manual price rows: {len(mp)}")

    loc = call("GET", f"/v1/inAppPurchases/{iid}/inAppPurchaseLocalizations?limit=10")
    for l in loc.get("data", []):
        la = l["attributes"]
        print(f"    loc {la.get('locale')}: {la.get('name')!r} / {la.get('description')!r}")

    # ⚠️ MUST be /v2 — the v1 path 404s `PATH_ERROR: the relationship does not
    # exist`, and because this printed the 404 as "none" it read as "no pack
    # has a review screenshot, so they must be optional". They are NOT: a new
    # IAP cannot be submitted without one. A 404 is not an empty result.
    shot = call("GET", f"/v2/inAppPurchases/{iid}/appStoreReviewScreenshot")
    if "__error" in shot:
        print(f"    review screenshot: UNREADABLE (HTTP {shot['__error']})")
    else:
        sd = shot.get("data")
        print(f"    review screenshot: {'YES ' + str(sd.get('id')) if sd else 'none'}")

    ver = call("GET", f"/v2/inAppPurchases/{iid}/versions?limit=3")
    for vv in ver.get("data", []):
        print(f"    version {vv['id']}: {vv['attributes']}")
