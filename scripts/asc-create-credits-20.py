#!/usr/bin/env python3
"""Create the `credits.20` consumable ($8.99 / €8.99) and submit it for review.

WHY THIS PACK EXISTS. Measured over the 7 days to 2026-09-21, the largest
paywall shortfall after 4 credits was **24** — 76 `paywall_shown` events
across 40 distinct users. Nothing sat between `credits.12` ($5.49) and
`credits.30` ($12.99), so everyone short ~24 credits was asked for $12.99.
Credit packs are the only high-margin line in the product (91% contribution
against 42% and 50% for the two subscriptions), so the gap is the single
best-evidenced revenue lever in the data.

WHY $8.99. The ladder must improve strictly per credit or a bigger pack stops
being a better deal, which has silently inverted in production before.
$8.99/20 = 0.4495/credit, strictly between `credits.12` (0.4575) and
`credits.30` (0.433). `CreditPack.assertLadderImproves()` asserts the same
thing client-side.

🔴 BOTH USA AND FRA GET A MANUAL PRICE AT THE SAME NUMERAL. Setting only the
base territory and trusting Apple's FX equalization is the documented
ladder-inverting trap: it put €29.99/€69.99 against $24.99/$59.99 on the two
big packs and made the 30-pack the best per-credit deal in euros. Every
existing pack carries manual USA + FRA rows for exactly this reason.

⚠️ An IAP is a SEPARATE review track from the app version and cannot ride
along with it (`reviewSubmissionItems` rejects an `inAppPurchaseV2`
relationship outright). The in-flight cap is TWO submissions per platform;
this script checks it and says so rather than failing opaquely.

⚠️ Cancelling an IAP submission is close to a one-way door — it leaves the
version `DEVELOPER_REJECTED`, recoverable only in the ASC web UI. So this
script creates and submits, and never cancels.

Usage:
    python3 scripts/asc-create-credits-20.py           # dry run, writes nothing
    python3 scripts/asc-create-credits-20.py --apply
"""
import json, sys, time, urllib.request, urllib.error
import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS, APP = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46", "6774768570"

PRODUCT_ID   = "com.anthersystems.VirtualSIM.credits.20"
REFERENCE    = "20 Credits - Verification Codes"
LOC_NAME     = "20 OTP Credits"
# 🔴 No price may appear in any listing field, in any locale — the rule binds
# IAP copy exactly as it binds release notes. StoreKit renders the real,
# localized price at the sheet.
LOC_DESC     = "Get 20 SMS verification codes"
REVIEW_NOTE  = ("Consumable credit pack. Credits are spent to receive SMS "
                "verification codes on temporary numbers.")
PRICE        = "8.99"           # same numeral in USD and EUR
TERRITORIES  = ["USA", "FRA"]   # FRA is the base territory on every other pack

APPLY = "--apply" in sys.argv

tok = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1200,
                  "aud": "appstoreconnect-v1"}, open(KEY).read(), algorithm="ES256",
                 headers={"kid": KID})
H = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}


def call(method, path, body=None, allow=()):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 data=data, method=method, headers=H)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r) if r.status != 204 else {}
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            if e.code >= 500 and method == "GET" and attempt < 3:
                time.sleep(2 * (attempt + 1))
                continue
            if e.code in allow:
                return {"__error": e.code, "__body": txt}
            print(f"HTTP {e.code} on {method} {path}\n{txt[:900]}")
            sys.exit(1)


def get_all(path):
    out, nxt = [], path
    while nxt:
        r = call("GET", nxt)
        out.extend(r.get("data", []))
        nxt = r.get("links", {}).get("next")
        if nxt:
            nxt = nxt.replace("https://api.appstoreconnect.apple.com", "")
    return out


print(f"{'APPLY' if APPLY else 'DRY RUN'} — {PRODUCT_ID} at {PRICE}\n")

# ── 0. Does it already exist? This script is idempotent on re-run. ──────────
existing = [p for p in get_all(f"/v1/apps/{APP}/inAppPurchasesV2?limit=200")
            if p["attributes"]["productId"] == PRODUCT_ID]
if existing:
    iap_id = existing[0]["id"]
    print(f"already exists: id={iap_id} state={existing[0]['attributes'].get('state')}")
else:
    iap_id = None
    print("does not exist yet")

# ── 1. In-flight submission slots. The cap is 2 per platform and hitting it ──
#      reads as a broken submission rather than a full queue.
subs = get_all("/v1/reviewSubmissions"
               f"?filter[app]={APP}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW")
print(f"in-flight review submissions: {len(subs)} of 2")

# ── 2. Create the product ───────────────────────────────────────────────────
if iap_id is None:
    body = {"data": {"type": "inAppPurchases", "attributes": {
        "name": REFERENCE, "productId": PRODUCT_ID,
        # ⚠️ `availableInAllTerritories` is NOT an attribute on this resource
        # (409 ENTITY_ERROR.ATTRIBUTE.UNKNOWN). Territory availability for a
        # consumable follows the PRICE SCHEDULE, not a flag — posting the
        # schedule below with a base territory is what makes it sellable.
        "inAppPurchaseType": "CONSUMABLE", "reviewNote": REVIEW_NOTE,
        "familySharable": False,
    }, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}}
    if not APPLY:
        print("would POST /v2/inAppPurchases:", json.dumps(body["data"]["attributes"]))
    else:
        r = call("POST", "/v2/inAppPurchases", body)
        iap_id = r["data"]["id"]
        print(f"created id={iap_id}")

# ── 3. Localization ─────────────────────────────────────────────────────────
if iap_id:
    locs = get_all(f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations")
    if any(l["attributes"]["locale"] == "en-US" for l in locs):
        print("en-US localization already present")
    else:
        body = {"data": {"type": "inAppPurchaseLocalizations", "attributes": {
            "locale": "en-US", "name": LOC_NAME, "description": LOC_DESC},
            "relationships": {"inAppPurchaseV2": {
                "data": {"type": "inAppPurchases", "id": iap_id}}}}}
        if not APPLY:
            print(f"would POST localization: {LOC_NAME!r} / {LOC_DESC!r}")
        else:
            call("POST", "/v1/inAppPurchaseLocalizations", body)
            print("localization written")
elif not APPLY:
    print(f"would POST localization: {LOC_NAME!r} / {LOC_DESC!r}")

# ── 4. Price schedule: manual USA + FRA at the SAME NUMERAL ─────────────────
if iap_id:
    points = {}
    for terr in TERRITORIES:
        pts = get_all(f"/v2/inAppPurchases/{iap_id}/pricePoints"
                      f"?filter[territory]={terr}&limit=200")
        match = [p for p in pts
                 if p["attributes"].get("customerPrice") == PRICE]
        if not match:
            near = sorted({p["attributes"].get("customerPrice") for p in pts},
                          key=lambda x: abs(float(x) - float(PRICE)))[:5]
            print(f"🔴 no {PRICE} price point in {terr}; nearest: {near}")
            sys.exit(1)
        points[terr] = match[0]["id"]
        print(f"  {terr} price point for {PRICE}: {points[terr]}")

    body = {"data": {"type": "inAppPurchasePriceSchedules",
                     "relationships": {
                         "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                         "baseTerritory": {"data": {"type": "territories", "id": "FRA"}},
                         "manualPrices": {"data": [
                             {"type": "inAppPurchasePrices", "id": f"${{{t}}}"} for t in TERRITORIES]},
                     }},
            "included": [
                {"type": "inAppPurchasePrices", "id": f"${{{t}}}",
                 "attributes": {"startDate": None, "endDate": None},
                 "relationships": {
                     "inAppPurchasePricePoint": {
                         "data": {"type": "inAppPurchasePricePoints", "id": points[t]}},
                     "territory": {"data": {"type": "territories", "id": t}}}}
                for t in TERRITORIES]}
    if not APPLY:
        print(f"would POST price schedule: base FRA, manual {TERRITORIES} at {PRICE}")
    else:
        call("POST", "/v1/inAppPurchasePriceSchedules", body)
        print(f"price schedule written: {PRICE} in {', '.join(TERRITORIES)}")
else:
    print(f"would POST price schedule: base FRA, manual {TERRITORIES} at {PRICE}")

# ── 5. Submit for review ────────────────────────────────────────────────────
if iap_id:
    vers = get_all(f"/v2/inAppPurchases/{iap_id}/versions")
    state = vers[0]["attributes"]["state"] if vers else "?"
    print(f"version state: {state}")
    if state in ("READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
        print("already submitted or approved — nothing to do")
    elif len(subs) >= 2:
        print("🔴 both in-flight slots are taken; re-run when one clears "
              "(the failed submit is a clean no-op, so this is 'retry later')")
    elif not APPLY:
        print("would POST /v1/inAppPurchaseSubmissions")
    else:
        r = call("POST", "/v1/inAppPurchaseSubmissions",
                 {"data": {"type": "inAppPurchaseSubmissions", "relationships": {
                     "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}},
                 allow=(409,))
        if r.get("__error") == 409:
            print(f"409 on submit — read the version state, not this message: {r['__body'][:300]}")
        else:
            print("submitted for review")
elif not APPLY:
    print("would POST /v1/inAppPurchaseSubmissions")

print("\ndone" + ("" if APPLY else " (dry run — nothing was written)"))
