#!/usr/bin/env python3
"""Create the yearly line subscription ($99.99) with a 3-day free trial.

⚠️ IT MUST GO IN THE EXISTING GROUP (22289428), not a new one. Apple allows one
active subscription per GROUP, and that is exactly the property we want: monthly
and yearly become upgrade/downgrade siblings that Apple prorates, and a user
cannot hold both. In a separate group they COULD hold both — and
`phone_lines_one_apple_line_per_user` would then refuse the second line, so they
would be paying for something they can never receive.

ORDERING IS LOAD-BEARING, and this repo has already paid for getting it wrong:
`subscriptionAvailability` must exist BEFORE any price, or pricing returns a
409 ENTITY_ERROR.RELATIONSHIP.INVALID pointing at the price point — which reads
as a bad price point, and the price point is fine.

And creating the base price does NOT propagate to other territories: the web UI
fills them from the base automatically, the API does not. Run
`asc-equalize-subscription-prices.py` afterwards (pointed at the new id) or 31
territories stay unpriced, which is an unnamed missing-metadata condition.

A created IAP product CANNOT be deleted — only removed from sale. Check the
product id before running.

    python3 scripts/asc-create-yearly-subscription.py --dry
    python3 scripts/asc-create-yearly-subscription.py
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

GROUP = "22289428"
PRODUCT_ID = "com.anthersystems.VirtualSIM.line.yearly"
REF_NAME = "Second Number Yearly"
PERIOD = "ONE_YEAR"

# Mirrors the monthly product: same 32 territories, same base (USA).
BASE_TERRITORY = "USA"

DRY = "--dry" in sys.argv


def _token():
    return jwt.encode(
        {"iss": ISS, "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
        open(KEY).read(),
        algorithm="ES256",
        headers={"kid": KID, "typ": "JWT"},
    )


def call(method, path, body=None):
    # ⚠️ `-g` (globoff) is MANDATORY. ASC filters are written `filter[territory]`
    # and curl treats `[...]` as a range glob, so without it the request is
    # never sent and the failure looks like an empty API response — which is
    # exactly how the first run of this script "found no $99.99 price point".
    args = ["curl", "-s", "-g", "-X", method,
            "-H", f"Authorization: Bearer {_token()}",
            "-H", "Content-Type: application/json", f"{BASE}{path}"]
    if body is not None:
        args += ["-d", json.dumps(body)]
    if DRY and method != "GET":
        print(f"  [dry] {method} {path}")
        if body:
            print("       " + json.dumps(body)[:300])
        return {"dry": True}
    out = subprocess.run(args, capture_output=True, text=True).stdout
    try:
        return json.loads(out) if out.strip() else {}
    except Exception:
        return {"raw": out[:500]}


def die(step, r):
    print(f"\nFAILED at {step}:")
    print(json.dumps(r, indent=1)[:1500])
    sys.exit(1)


# ── 0. Does it already exist? Creation is irreversible, so never blind-create.
existing = call("GET", f"/v1/subscriptionGroups/{GROUP}/subscriptions?limit=50")
found = None
for s in existing.get("data", []):
    if s["attributes"].get("productId") == PRODUCT_ID:
        found = s
print(f"existing {PRODUCT_ID}: {found['id'] if found else 'none'}")

if found:
    sub_id = found["id"]
    print("  already created — skipping creation, will top up the pieces below")
else:
    r = call("POST", "/v1/subscriptions", {
        "data": {
            "type": "subscriptions",
            "attributes": {
                "name": REF_NAME,
                "productId": PRODUCT_ID,
                "subscriptionPeriod": PERIOD,
                "familySharable": False,
                # Same group => Apple handles monthly<->yearly as an
                # upgrade/downgrade and blocks holding both.
                "groupLevel": 1,
            },
            "relationships": {
                "group": {"data": {"type": "subscriptionGroups", "id": GROUP}}
            },
        }
    })
    if DRY:
        sub_id = "<new>"
    elif "data" not in r:
        die("create subscription", r)
    else:
        sub_id = r["data"]["id"]
    print("created subscription:", sub_id)

# ── 1. AVAILABILITY FIRST. Pricing before this returns a misleading 409.
# The relationship is `subscriptionAvailability`. `availability` 404s with
# PATH_ERROR, which reads as "not set" rather than "you asked wrongly".
avail = call("GET", f"/v1/subscriptions/{sub_id}/subscriptionAvailability") if not DRY else {}
if not avail.get("data"):
    r = call("POST", "/v1/subscriptionAvailabilities", {
        "data": {
            "type": "subscriptionAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                "availableTerritories": {
                    "data": [{"type": "territories", "id": BASE_TERRITORY}]
                },
            },
        }
    })
    if not DRY and "data" not in r:
        die("create availability", r)
    print("availability created (base territory only — equalize afterwards)")
else:
    print("availability already present")

# ── 2. The base price. The price POINT id encodes (subscription, territory),
#      so it can only be read AFTER the subscription exists.
existing_prices = call("GET", f"/v1/subscriptions/{sub_id}/prices?limit=200") if not DRY else {}
if existing_prices.get("data"):
    print(f"price already set ({len(existing_prices['data'])} record(s)) — skipping")
elif not DRY:
    # PAGINATED, and the tiers start at $0.29 — $99.99 is nowhere near the
    # first page. Walk `links.next` rather than assuming one `limit=200` covers
    # it, which is how this first "found no $99.99 price point".
    target = None
    path = (f"/v1/subscriptions/{sub_id}/pricePoints"
            f"?filter[territory]={BASE_TERRITORY}&limit=200")
    seen = 0
    while path and not target:
        pts = call("GET", path)
        if "data" not in pts:
            die("list price points", pts)
        seen += len(pts["data"])
        for p in pts["data"]:
            if p["attributes"].get("customerPrice") == "99.99":
                target = p["id"]
                break
        nxt = pts.get("links", {}).get("next")
        path = nxt[len(BASE):] if nxt else None
    if not target:
        die("find a $99.99 price point", {"scanned": seen})
    print(f"price point: {target} (scanned {seen} tiers)")

    r = call("POST", "/v1/subscriptionPrices", {
        "data": {
            "type": "subscriptionPrices",
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                "subscriptionPricePoint": {
                    "data": {"type": "subscriptionPricePoints", "id": target}
                },
            },
        }
    })
    if "data" not in r:
        die("create price", r)
    print("base price created: $99.99 USA")
else:
    print("  [dry] would look up the $99.99 USA price point and create the price")

# ── 3. The 3-day free trial.
#      FREE_TRIAL + THREE_DAYS. Apple enforces one introductory offer per
#      Apple ID per GROUP, which is what bounds trial abuse — we do not have to.
# ⚠️ `territory` is a REQUIRED relationship — an introductory offer is
# PER-TERRITORY, not per-subscription. Omitting it returns a 409
# ENTITY_ERROR.RELATIONSHIP.REQUIRED that at least names the field, unlike the
# availability-before-pricing 409 which points at the wrong thing entirely.
# One offer per territory: the trial has to be created everywhere the
# subscription is sold, or it silently exists only in the USA.
r = call("POST", "/v1/subscriptionIntroductoryOffers", {
    "data": {
        "type": "subscriptionIntroductoryOffers",
        "attributes": {
            "duration": "THREE_DAYS",
            "offerMode": "FREE_TRIAL",
            "numberOfPeriods": 1,
        },
        "relationships": {
            "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
            "territory": {"data": {"type": "territories", "id": BASE_TERRITORY}},
        },
    }
})
if not DRY and "data" not in r:
    print("NOTE: introductory offer not created — inspect below. It can also be")
    print("      added in the web UI; everything else above is done.")
    print(json.dumps(r, indent=1)[:900])
else:
    print("3-day free trial created")

print(f"""
NEXT:
  1. python3 scripts/asc-equalize-subscription-prices.py   # point SUB at {sub_id}
     — 31 territories are otherwise unpriced, which blocks submission.
  2. Add the en-US localization (name + description) in ASC.
  3. Attach the review screenshot.
  4. Client: add the yearly option to LineCheckoutScreen and
     LineProduct.yearlyId, and handle offerType (trial) in the line state
     machine — it is decoded in _shared/iap.ts and acted on NOWHERE today.
""")
