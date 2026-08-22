#!/usr/bin/env python3
"""Give credits.60 / credits.150 a manual EUR price with the SAME NUMERAL as USD.

Why: both packs carry a manual price in the USA only, so every other
territory gets Apple's FX-equalized price — €29.99 / €69.99 against
$24.99 / $59.99 — which inverts the per-credit ladder in euros (the 30-pack
at €0.43/cr beats the 60 at €0.50 and the 150 at €0.47). Found 2026-08-22
from the owner's own phone. The other four packs already follow the
same-numeral rule via a manual FRA price; this does it for every EUR
territory, not just France.

Mechanism: an IAP price schedule can only be REPLACED, not patched — a new
`inAppPurchasePriceSchedules` POST carries the base territory plus the full
manual price list, and it supersedes the old schedule. So this script reads
the current manual prices, adds one per EUR territory at the same-numeral
price point, and posts the union. `--dry` prints the plan and posts nothing.

Usage: python3 scripts/asc-fix-eur-pack-prices.py [--dry]
"""
import base64, json, sys, time, urllib.request
import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS, APP = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46", "6774768570"
TARGETS = {"com.anthersystems.VirtualSIM.credits.60": "24.99",
           "com.anthersystems.VirtualSIM.credits.150": "59.99"}
DRY = "--dry" in sys.argv

tok = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1200,
                  "aud": "appstoreconnect-v1"}, open(KEY).read(), algorithm="ES256",
                 headers={"kid": KID})
H = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 data=data, method=method, headers=H)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r) if r.status != 204 else {}
        except urllib.error.HTTPError as e:
            body_txt = e.read().decode()[:600]
            # ASC reads 500 intermittently under load; a GET is safe to retry.
            if e.code >= 500 and method == "GET" and attempt < 3:
                time.sleep(2 * (attempt + 1))
                continue
            print("HTTP", e.code, body_txt)
            raise


def get_all(path):
    out, nxt = [], path
    while nxt:
        r = call("GET", nxt)
        out.extend(r["data"])
        nxt = r.get("links", {}).get("next")
        if nxt:
            nxt = nxt.replace("https://api.appstoreconnect.apple.com", "")
        inc = r.get("included")
        if inc:
            out.extend([{"_included": i} for i in inc])
    return out


iaps = {i["attributes"]["productId"]: i["id"]
        for i in call("GET", f"/v1/apps/{APP}/inAppPurchasesV2?limit=50")["data"]}

# EUR territories, from the territories resource (currency attribute).
terrs = call("GET", "/v1/territories?limit=200")["data"]
eur = sorted(t["id"] for t in terrs if t["attributes"].get("currency") == "EUR")
print(f"EUR territories: {len(eur)} -> {' '.join(eur)}")

for pid, numeral in TARGETS.items():
    iap = iaps[pid]
    sched = call("GET", f"/v2/inAppPurchases/{iap}/iapPriceSchedule?include=baseTerritory")
    base = sched["data"]["relationships"]["baseTerritory"]["data"]["id"]
    sid = sched["data"]["id"]
    cur = call("GET", f"/v1/inAppPurchasePriceSchedules/{sid}/manualPrices"
                      "?include=inAppPurchasePricePoint,territory&limit=200")
    pts = {i["id"]: i["attributes"] for i in cur.get("included", [])
           if i["type"] == "inAppPurchasePricePoints"}
    existing = {}  # territory -> price point id
    for p in cur["data"]:
        t = p["relationships"]["territory"]["data"]["id"]
        pp = p["relationships"]["inAppPurchasePricePoint"]["data"]["id"]
        existing[t] = pp
    print(f"\n{pid}: base {base}, existing manual: "
          + ", ".join(f"{t}={pts[pp]['customerPrice']}" for t, pp in existing.items()))

    # Find the same-numeral price point per EUR territory.
    plan = dict(existing)
    for t in eur:
        if t in existing:
            continue
        pps = [x for x in get_all(f"/v2/inAppPurchases/{iap}/pricePoints?filter[territory]={t}&limit=200")
               if "_included" not in x]
        match = [p for p in pps if p["attributes"]["customerPrice"] == numeral]
        if not match:
            print(f"  {t}: no price point at {numeral} — left to equalization")
            continue
        plan[t] = match[0]["id"]
        print(f"  {t}: {numeral} (proceeds {match[0]['attributes']['proceeds']})")

    if DRY:
        print(f"  DRY: would post schedule with {len(plan)} manual prices "
              f"({len(plan) - len(existing)} new)")
        continue
    if len(plan) == len(existing):
        print("  nothing new — schedule left as is")
        continue

    included = []
    rel = []
    for n, (t, pp) in enumerate(plan.items()):
        tmp = f"${{price{n}}}"
        included.append({"id": tmp, "type": "inAppPurchasePrices",
                         "attributes": {"startDate": None},
                         "relationships": {
                             "inAppPurchasePricePoint": {"data": {"id": pp, "type": "inAppPurchasePricePoints"}},
                             "territory": {"data": {"id": t, "type": "territories"}}}})
        rel.append({"id": tmp, "type": "inAppPurchasePrices"})
    body = {"data": {"type": "inAppPurchasePriceSchedules",
                     "relationships": {
                         "inAppPurchase": {"data": {"id": iap, "type": "inAppPurchases"}},
                         "baseTerritory": {"data": {"id": base, "type": "territories"}},
                         "manualPrices": {"data": rel}}},
            "included": included}
    r = call("POST", "/v1/inAppPurchasePriceSchedules", body)
    nsid = r["data"]["id"]
    back = call("GET", f"/v1/inAppPurchasePriceSchedules/{nsid}/manualPrices"
                       "?include=inAppPurchasePricePoint,territory&limit=200")
    bpts = {i["id"]: i["attributes"]["customerPrice"] for i in back.get("included", [])
            if i["type"] == "inAppPurchasePricePoints"}
    got = {p["relationships"]["territory"]["data"]["id"]:
           bpts[p["relationships"]["inAppPurchasePricePoint"]["data"]["id"]] for p in back["data"]}
    print(f"  POSTED schedule {nsid}; read back {len(got)} manual prices; "
          f"FRA={got.get('FRA')} DEU={got.get('DEU')} USA={got.get('USA')}")
