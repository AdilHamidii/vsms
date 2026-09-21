#!/usr/bin/env python3
"""Upload an App Store review screenshot for an in-app purchase.

🔴 A NEW IAP CANNOT BE SUBMITTED WITHOUT ONE. The submit fails 409
`STATE_ERROR.INVALID_REQUEST_ENTITY_STATE_INVALID` whose top-level detail says
only "please check associated errors" — the real cause is in
`meta.associatedErrors`, as `ENTITY_ERROR.RELATIONSHIP.REQUIRED` pointing at
`/data/relationships/appStoreReviewScreenshot`. Read that array, never the
detail string.

⚠️ The older packs read `appStoreReviewScreenshot: none` and are APPROVED, so
do not conclude from them that the screenshot is optional. Whatever let them
through does not apply to a product created today.

Upload is Apple's three-step reservation protocol, not a plain POST: reserve
(which returns `uploadOperations`), PUT the bytes exactly as each operation
dictates, then PATCH `uploaded: true` with an MD5 of the file. Skipping the
final PATCH leaves a reserved-but-empty asset that reads as present and is
not.

Usage:
    python3 scripts/asc-upload-iap-screenshot.py <iap-id> <file.png> [--apply]
"""
import hashlib, json, os, sys, time, urllib.request, urllib.error
import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46"

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)
IAP_ID, PATH = sys.argv[1], sys.argv[2]
APPLY = "--apply" in sys.argv

blob = open(PATH, "rb").read()
name = os.path.basename(PATH)
print(f"{'APPLY' if APPLY else 'DRY RUN'} — {name} ({len(blob)} bytes) -> IAP {IAP_ID}")

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
        print(f"HTTP {e.code} on {method} {path}\n{e.read().decode()[:900]}")
        sys.exit(1)


existing = call("GET", f"/v2/inAppPurchases/{IAP_ID}/appStoreReviewScreenshot")
if existing.get("data"):
    print(f"already has a screenshot: {existing['data']['id']} — nothing to do")
    sys.exit(0)

if not APPLY:
    print("would reserve, PUT the bytes, then PATCH uploaded:true")
    sys.exit(0)

# ── 1. Reserve ──────────────────────────────────────────────────────────────
res = call("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots",
           {"data": {"type": "inAppPurchaseAppStoreReviewScreenshots",
                     "attributes": {"fileName": name, "fileSize": len(blob)},
                     "relationships": {"inAppPurchaseV2": {
                         "data": {"type": "inAppPurchases", "id": IAP_ID}}}}})
sid = res["data"]["id"]
ops = res["data"]["attributes"]["uploadOperations"]
print(f"reserved {sid}, {len(ops)} upload operation(s)")

# ── 2. PUT the bytes exactly as each operation dictates ─────────────────────
for op in ops:
    chunk = blob[op["offset"]:op["offset"] + op["length"]]
    req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
    for h in op.get("requestHeaders", []):
        req.add_header(h["name"], h["value"])
    with urllib.request.urlopen(req) as r:
        print(f"  uploaded {len(chunk)} bytes -> {r.status}")

# ── 3. Commit. Without this the asset is reserved and EMPTY. ────────────────
done = call("PATCH", f"/v1/inAppPurchaseAppStoreReviewScreenshots/{sid}",
            {"data": {"type": "inAppPurchaseAppStoreReviewScreenshots", "id": sid,
                      "attributes": {"uploaded": True,
                                     "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
print("state:", json.dumps(done.get("data", {}).get("attributes", {}))[:300])
