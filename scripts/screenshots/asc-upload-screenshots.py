"""Replace the en-US screenshot sets on version 2.10 with the files in a manifest.

usage: asc-upload-screenshots.py <manifest.json> <appStoreVersionId> [--apply]
manifest: {"APP_IPHONE_67": ["/abs/01.png", ...], "APP_IPHONE_65": [...]}
Order in the list = order on the store.
"""
import json, time, urllib.request, urllib.error, jwt, sys, os, hashlib

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS, APP = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46", "6774768570"
VID = [a for a in sys.argv[1:] if not a.startswith("--")][1]   # appStoreVersion id, second positional arg
APPLY = "--apply" in sys.argv
manifest = json.load(open([a for a in sys.argv[1:] if not a.startswith("--")][0]))
tok = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1100,
                  "aud": "appstoreconnect-v1"}, open(KEY).read(), algorithm="ES256", headers={"kid": KID})
H = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, data=data, method=method, headers=H)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r) if r.status != 204 else {}
        except urllib.error.HTTPError as e:
            txt = e.read().decode()[:400]
            if e.code >= 500 and attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            print("HTTP", e.code, method, path, txt); raise

locs = call("GET", f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations?limit=20")["data"]
en = next(l for l in locs if l["attributes"]["locale"] == "en-US")
sets = {s["attributes"]["screenshotDisplayType"]: s
        for s in call("GET", f"/v1/appStoreVersionLocalizations/{en['id']}/appScreenshotSets?limit=20")["data"]}
print("existing sets on 2.10 en-US:", {k: v["id"][:8] for k, v in sets.items()})

for dt, files in manifest.items():
    for f in files:
        assert os.path.exists(f), f
    s = sets.get(dt)
    if not s:
        print(f"{dt}: no set" + ("" if APPLY else " (dry: would create)"))
        if not APPLY: continue
        s = call("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": dt},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": en["id"]}}}}})["data"]
    old = call("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots?limit=20")["data"]
    print(f"{dt}: {len(old)} existing -> {len(files)} new" + ("" if APPLY else " (dry)"))
    if not APPLY: continue
    for o in old:
        call("DELETE", f"/v1/appScreenshots/{o['id']}")
    ids = []
    for f in files:
        blob = open(f, "rb").read()
        r = call("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(f), "fileSize": len(blob)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": s["id"]}}}}})["data"]
        for op in r["attributes"]["uploadOperations"]:
            part = blob[op["offset"]:op["offset"] + op["length"]]
            hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            req = urllib.request.Request(op["url"], data=part, method=op["method"], headers=hdrs)
            with urllib.request.urlopen(req) as resp:
                assert resp.status in (200, 201, 204), resp.status
        call("PATCH", f"/v1/appScreenshots/{r['id']}", {"data": {
            "type": "appScreenshots", "id": r["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
        ids.append(r["id"]); print("  uploaded", os.path.basename(f))
    call("PATCH", f"/v1/appScreenshotSets/{s['id']}/relationships/appScreenshots",
         {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
    # read back: order + delivery state (COMPLETE may take a minute)
    for attempt in range(12):
        back = call("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots?limit=20")["data"]
        states = [(b["attributes"].get("fileName"), (b["attributes"].get("assetDeliveryState") or {}).get("state")) for b in back]
        if all(st == "COMPLETE" for _, st in states): break
        time.sleep(10)
    print(f"  {dt} read-back:", states)
print("DONE")
