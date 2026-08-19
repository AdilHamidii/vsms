#!/usr/bin/env python3
"""Create the temp-e-mail subscription group and its two products.

    python3 scripts/asc-create-mail-subscriptions.py --dry
    python3 scripts/asc-create-mail-subscriptions.py

⚠️ A NEW GROUP IS THE WHOLE POINT, and it is the opposite of what
`asc-create-yearly-subscription.py` insists on for the line. Apple allows one
active subscription per GROUP. The line's monthly and yearly belong together in
22289428 precisely so a user cannot hold both. Mail must NOT go there: a mail
purchase would then REPLACE somebody's $9.99 rented phone number. Separate
groups also mean a user may legitimately hold a line and a mail plan at once —
`_shared/iap.ts` documents that, and nothing may assume otherwise.

ORDERING IS LOAD-BEARING and this repo has already paid for getting it wrong:
`subscriptionAvailability` must exist BEFORE any price, or pricing returns a
409 ENTITY_ERROR.RELATIONSHIP.INVALID pointing at the price point — which reads
as a bad price point, and the price point is fine.

Creating a base price does NOT propagate to other territories. The web UI fills
them from the base; the API does not. Run the equalizer afterwards or 30-odd
territories stay unpriced, which is an unnamed missing-metadata condition.

A created IAP product CANNOT be deleted — only removed from sale. Every step
below checks for an existing object first, so re-running is safe.
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

APP_ID = "6774768570"           # com.anthersystems.VirtualSIM
GROUP_REF = "vSMS Mail"
GROUP_DISPLAY = "vSMS Mail"
BASE_TERRITORY = "USA"

# name <= 30 chars, description <= 45 chars (ASC limits).
#
# ⚠️ COPY RULES, all three load-bearing: name outlook.com and hotmail.com
# rather than promising "unlimited" (subscribers are capped by
# `app_config.email_sub_daily_cap`, and free-domain stock genuinely runs dry —
# an unlimited claim is an App Store 2.3.1 accurate-metadata risk); never name
# or allude to the wholesaler; gmail.com is NOT included and stays a 1-credit
# purchase.
PRODUCTS = [
    {
        "product_id": "com.anthersystems.VirtualSIM.mail.monthly",
        "ref_name": "vSMS Mail Monthly",
        "period": "ONE_MONTH",
        "price": "2.99",
        "loc_name": "vSMS Mail - Monthly",
        "loc_desc": "More Outlook & Hotmail addresses each day",
        "trial": False,
    },
    {
        "product_id": "com.anthersystems.VirtualSIM.mail.yearly",
        "ref_name": "vSMS Mail Yearly",
        "period": "ONE_YEAR",
        "price": "29.99",
        "loc_name": "vSMS Mail - Yearly",
        "loc_desc": "More Outlook & Hotmail addresses each day",
        "trial": True,
    },
]

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
    # never sent and the failure looks like an empty API response.
    args = ["curl", "-s", "-g", "-X", method,
            "-H", f"Authorization: Bearer {_token()}",
            "-H", "Content-Type: application/json", f"{BASE}{path}"]
    if body is not None:
        args += ["-d", json.dumps(body)]
    if DRY and method != "GET":
        print(f"    [dry] {method} {path}")
        if body:
            print("          " + json.dumps(body)[:260])
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


# ── 0. The group. Never blind-create: groups cannot be deleted either.
groups = call("GET", f"/v1/apps/{APP_ID}/subscriptionGroups?limit=50")
if "data" not in groups:
    die("list groups", groups)
group_id = None
for g in groups["data"]:
    if g["attributes"].get("referenceName") == GROUP_REF:
        group_id = g["id"]
print(f"group '{GROUP_REF}': {group_id or 'none'}")

if not group_id:
    r = call("POST", "/v1/subscriptionGroups", {
        "data": {
            "type": "subscriptionGroups",
            "attributes": {"referenceName": GROUP_REF},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
        }
    })
    if DRY:
        group_id = "<new-group>"
    elif "data" not in r:
        die("create group", r)
    else:
        group_id = r["data"]["id"]
    print("  created group:", group_id)

# ── 0b. Group localization. Without it the group has no customer-facing name,
#        which is one of the unnamed MISSING_METADATA conditions.
if not DRY:
    locs = call("GET", f"/v1/subscriptionGroups/{group_id}/subscriptionGroupLocalizations?limit=20")
    have = {l["attributes"].get("locale") for l in locs.get("data", [])}
else:
    have = set()
if "en-US" not in have:
    r = call("POST", "/v1/subscriptionGroupLocalizations", {
        "data": {
            "type": "subscriptionGroupLocalizations",
            "attributes": {"name": GROUP_DISPLAY, "locale": "en-US"},
            "relationships": {
                "subscriptionGroup": {
                    "data": {"type": "subscriptionGroups", "id": group_id}}
            },
        }
    })
    if not DRY and "data" not in r:
        die("create group localization", r)
    print("  group localization en-US created")
else:
    print("  group localization already present")

created = {}

for p in PRODUCTS:
    pid = p["product_id"]
    print(f"\n-- {pid}")

    # ── 1. The subscription itself.
    existing = call("GET", f"/v1/subscriptionGroups/{group_id}/subscriptions?limit=50") \
        if group_id != "<new-group>" else {}
    found = None
    for s in existing.get("data", []):
        if s["attributes"].get("productId") == pid:
            found = s
    if found:
        sub_id = found["id"]
        print(f"  exists: {sub_id} — topping up the pieces below")
    else:
        r = call("POST", "/v1/subscriptions", {
            "data": {
                "type": "subscriptions",
                "attributes": {
                    "name": p["ref_name"],
                    "productId": pid,
                    "subscriptionPeriod": p["period"],
                    "familySharable": False,
                    # Same level for both: monthly and yearly are the same tier
                    # of the same product, so Apple treats a switch as a
                    # crossgrade rather than an upgrade.
                    "groupLevel": 1,
                },
                "relationships": {
                    "group": {"data": {"type": "subscriptionGroups", "id": group_id}}
                },
            }
        })
        if DRY:
            sub_id = f"<new-{p['period']}>"
        elif "data" not in r:
            die(f"create subscription {pid}", r)
        else:
            sub_id = r["data"]["id"]
        print("  created:", sub_id)
    created[pid] = sub_id

    # ── 2. AVAILABILITY BEFORE PRICE. See the header.
    avail = call("GET", f"/v1/subscriptions/{sub_id}/subscriptionAvailability") \
        if not DRY else {}
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
        print("  availability created (base territory only — equalize after)")
    else:
        print("  availability already present")

    # ── 3. The base price.
    existing_prices = call("GET", f"/v1/subscriptions/{sub_id}/prices?limit=200") \
        if not DRY else {}
    if existing_prices.get("data"):
        print(f"  price already set ({len(existing_prices['data'])} record(s))")
    elif not DRY:
        # PAGINATED, and tiers start at $0.29 — walk `links.next` rather than
        # assuming one page covers it.
        target = None
        path = (f"/v1/subscriptions/{sub_id}/pricePoints"
                f"?filter[territory]={BASE_TERRITORY}&limit=200")
        seen = 0
        while path and not target:
            pts = call("GET", path)
            if "data" not in pts:
                die("list price points", pts)
            seen += len(pts["data"])
            for pp in pts["data"]:
                if pp["attributes"].get("customerPrice") == p["price"]:
                    target = pp["id"]
                    break
            nxt = pts.get("links", {}).get("next")
            path = nxt[len(BASE):] if nxt else None
        if not target:
            die(f"find a ${p['price']} price point", {"scanned": seen})
        print(f"  price point: {target} (scanned {seen} tiers)")
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
        print(f"  base price created: ${p['price']} {BASE_TERRITORY}")
    else:
        print(f"  [dry] would find the ${p['price']} {BASE_TERRITORY} price point")

    # ── 4. Localization. Missing => MISSING_METADATA, and a product in that
    #      state is NOT returned by StoreKit even in Sandbox, which from the
    #      phone looks like a bug in our own code.
    if not DRY:
        slocs = call("GET", f"/v1/subscriptions/{sub_id}/subscriptionLocalizations?limit=20")
        shave = {l["attributes"].get("locale") for l in slocs.get("data", [])}
    else:
        shave = set()
    if "en-US" not in shave:
        r = call("POST", "/v1/subscriptionLocalizations", {
            "data": {
                "type": "subscriptionLocalizations",
                "attributes": {
                    "name": p["loc_name"],
                    "description": p["loc_desc"],
                    "locale": "en-US",
                },
                "relationships": {
                    "subscription": {"data": {"type": "subscriptions", "id": sub_id}}
                },
            }
        })
        if not DRY and "data" not in r:
            die("create subscription localization", r)
        print("  localization en-US created")
    else:
        print("  localization already present")

    # ── 5. The 3-day trial, YEARLY ONLY.
    #      An introductory offer is PER TERRITORY — `territory` is a required
    #      relationship. Created for the base territory here; the equalizer
    #      does not carry offers, so widen them when the territories widen.
    if p["trial"]:
        offers = call("GET", f"/v1/subscriptions/{sub_id}/introductoryOffers?limit=50") \
            if not DRY else {}
        if offers.get("data"):
            print(f"  introductory offer already present ({len(offers['data'])})")
        else:
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
                print("  NOTE: introductory offer not created — inspect:")
                print(json.dumps(r, indent=1)[:800])
            else:
                print("  3-day free trial created")

print("\nCREATED / CONFIRMED:")
for k, v in created.items():
    print(f"  {k}  ->  {v}")
print(f"  group -> {group_id}")
print("""
NEXT:
  1. Equalize prices to every territory (the API does not propagate a base
     price), then READ BACK the EUR price and confirm it did not drift — ASC
     equalization has inverted this app's ladders before.
  2. Attach a review screenshot to each product, or both stay
     MISSING_METADATA and StoreKit returns NOTHING even in Sandbox.
  3. Leave `app_config.email_subscription_enforced` FALSE until the client
     shipping these products is live and adopted.
""")
