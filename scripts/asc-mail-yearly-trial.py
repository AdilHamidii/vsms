"""Create (or re-create) the 3-day FREE_TRIAL introductory offer on
mail.yearly (6803258736) in EVERY territory the product is priced in.
Offers are per-territory; the 2026-08-19 creation covered the base territory
only. Dry-run by default; pass --apply to mutate. Idempotent: territories
already holding an offer are skipped, and the result is read back.

History: trial removed 2026-08-25 (1/1 conversion failed to bill),
reinstated 2026-08-27 (owner decision)."""
import sys
APPLY = "--apply" in sys.argv
import json, os, time, urllib.request, urllib.error

KEY_ID = "R5ZVLBTUR6"
ISSUER = "4644ed13-4d98-489e-a94b-687f63946f46"
KEY_PATH = os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8")
SUB = "6803258736"  # com.anthersystems.VirtualSIM.mail.yearly

import jwt as pyjwt
def token():
    return pyjwt.encode({"iss": ISSUER, "iat": int(time.time()) - 60,
                         "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
                        open(KEY_PATH).read(), algorithm="ES256", headers={"kid": KEY_ID})

def call(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
        data=json.dumps(body).encode() if body else None, method=method,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        return {"_status": e.code, "_body": e.read().decode()[:400]}

# 1. Priced territories (paginate).
terrs, url = [], f"/v1/subscriptions/{SUB}/prices?limit=200&include=territory"
while url:
    r = call("GET", url)
    for inc in r.get("included", []):
        if inc["type"] == "territories":
            terrs.append(inc["id"])
    nxt = r.get("links", {}).get("next")
    url = nxt.replace("https://api.appstoreconnect.apple.com", "") if nxt else None
terrs = sorted(set(terrs))
print("priced territories:", len(terrs))

# 2. Existing offers (expect 0).
have = set()
url = f"/v1/subscriptions/{SUB}/introductoryOffers?limit=200&include=territory"
while url:
    r = call("GET", url)
    for inc in r.get("included", []):
        if inc["type"] == "territories":
            have.add(inc["id"])
    nxt = r.get("links", {}).get("next")
    url = nxt.replace("https://api.appstoreconnect.apple.com", "") if nxt else None
print("territories already holding an offer:", len(have))

# 3. Create per missing territory.
created, failed = 0, []
for t in terrs:
    if t in have:
        continue
    if not APPLY:
        created += 1
        continue
    r = call("POST", "/v1/subscriptionIntroductoryOffers", {"data": {
        "type": "subscriptionIntroductoryOffers",
        "attributes": {"duration": "THREE_DAYS", "offerMode": "FREE_TRIAL",
                       "numberOfPeriods": 1},
        "relationships": {
            "subscription": {"data": {"type": "subscriptions", "id": SUB}},
            "territory": {"data": {"type": "territories", "id": t}}}}})
    if "data" in r:
        created += 1
    else:
        failed.append((t, r.get("_status"), r.get("_body", "")[:150]))
    time.sleep(0.15)
print(("created:" if APPLY else "WOULD create:"), created, "failed:", len(failed))
for f in failed[:5]:
    print("  FAIL", f)

# 4. Read back — the only evidence.
back = set()
url = f"/v1/subscriptions/{SUB}/introductoryOffers?limit=200&include=territory"
while url:
    r = call("GET", url)
    for inc in r.get("included", []):
        if inc["type"] == "territories":
            back.add(inc["id"])
    nxt = r.get("links", {}).get("next")
    url = nxt.replace("https://api.appstoreconnect.apple.com", "") if nxt else None
print("read-back: offers now cover", len(back), "of", len(terrs), "priced territories")
missing = sorted(set(terrs) - back)
print("missing:", missing if missing else "none")
