#!/usr/bin/env python3
"""Headless App Store release steps for vSMS, each idempotent and read back.

    python3 scripts/asc-release.py version 2.3            # ensure the version exists
    python3 scripts/asc-release.py listing 2.3 <dir>      # PATCH description+whatsNew per locale from <dir>/<locale>.json
    python3 scripts/asc-release.py build 2.3 43           # attach build 43 (waits for VALID)
    python3 scripts/asc-release.py submit 2.3             # reviewSubmission + item + submitted:true
    python3 scripts/asc-release.py status 2.3             # state, build, localizations, submissions

Add --apply to any mutating step; without it the step prints what it would do.
Every mutation is read back before the script reports success — an accepted
PATCH is not evidence on this API (see CLAUDE.md, "a 200 here means nothing").

Locale JSON shape: {"locale": "fr-FR", "whatsNew": "...", "description": "..."}.
A locale with no file is left untouched and named in the output, because a
version whose 13 localizations disagree ships the old claims to 12 stores.
"""
import glob, json, os, sys, time, urllib.parse, urllib.request
import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS, APP = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46", "6774768570"
APPLY = "--apply" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]

tok = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1000,
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
            txt = e.read().decode()[:800]
            if e.code >= 500 and method == "GET" and attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            print(f"HTTP {e.code} {method} {path}\n{txt}")
            raise


def find_version(vs):
    for v in call("GET", f"/v1/apps/{APP}/appStoreVersions?limit=10"
                         "&fields[appStoreVersions]=versionString,appStoreState,platform")["data"]:
        if v["attributes"]["versionString"] == vs and v["attributes"]["platform"] == "IOS":
            return v
    return None


def cmd_version(vs):
    v = find_version(vs)
    if v:
        print(f"version {vs} exists: {v['id']} {v['attributes']['appStoreState']}"); return v
    print(f"version {vs} does not exist")
    if not APPLY:
        print("  DRY: would POST /v1/appStoreVersions"); return None
    r = call("POST", "/v1/appStoreVersions", {"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": "IOS", "versionString": vs},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    v = find_version(vs)
    print(f"  created {v['id']} {v['attributes']['appStoreState']}"); return v


def localizations(vid):
    return call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=20")["data"]


def cmd_listing(vs, d):
    v = find_version(vs)
    if not v:
        print(f"version {vs} missing — run `version {vs} --apply` first"); sys.exit(1)
    files = {json.load(open(f))["locale"]: json.load(open(f)) for f in glob.glob(os.path.join(d, "*.json"))}
    locs = localizations(v["id"])
    have = {l["attributes"]["locale"]: l for l in locs}
    print(f"version {vs}: {len(locs)} localizations on ASC, {len(files)} files in {d}")
    missing_files = sorted(set(have) - set(files))
    if missing_files:
        print("  ⚠️ NO FILE for:", ", ".join(missing_files), "— these keep their current text")
    for loc, payload in sorted(files.items()):
        desc, notes = payload["description"], payload["whatsNew"]
        assert len(desc) <= 4000 and len(notes) <= 4000, loc
        row = have.get(loc)
        if not row:
            print(f"  {loc}: not on ASC yet — would POST localization")
            if APPLY:
                call("POST", "/v1/appStoreVersionLocalizations", {"data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {"locale": loc, "description": desc, "whatsNew": notes},
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
            continue
        cur = row["attributes"]
        same = (cur.get("description") == desc and cur.get("whatsNew") == notes)
        print(f"  {loc}: {'unchanged' if same else 'PATCH'} (desc {len(desc)} chars, notes {len(notes)})")
        if APPLY and not same:
            call("PATCH", f"/v1/appStoreVersionLocalizations/{row['id']}", {"data": {
                "type": "appStoreVersionLocalizations", "id": row["id"],
                "attributes": {"description": desc, "whatsNew": notes}}})
    if APPLY:
        back = {l["attributes"]["locale"]: l["attributes"] for l in localizations(v["id"])}
        bad = [loc for loc, p in files.items()
               if back.get(loc, {}).get("description") != p["description"]
               or back.get(loc, {}).get("whatsNew") != p["whatsNew"]]
        print("  read-back:", "all match" if not bad else f"MISMATCH {bad}")
        stale = [loc for loc, a in back.items() if "in and out" in (a.get("description") or "")]
        print("  locales still saying 'in and out':", stale or "none")


def cmd_build(vs, build_no):
    v = find_version(vs)
    for _ in range(40):
        bs = call("GET", f"/v1/builds?filter[app]={APP}&filter[version]={build_no}&limit=5")["data"]
        if bs:
            b = bs[0]; st = b["attributes"]["processingState"]
            print(f"build {build_no}: {b['id']} {st}")
            if st == "VALID": break
        else:
            print(f"build {build_no}: not visible yet")
        if not APPLY: return
        time.sleep(30)
    else:
        print("gave up waiting for VALID"); sys.exit(1)
    if not APPLY:
        print("  DRY: would attach"); return
    call("PATCH", f"/v1/appStoreVersions/{v['id']}/relationships/build",
         {"data": {"type": "builds", "id": b["id"]}})
    got = call("GET", f"/v1/appStoreVersions/{v['id']}/build")["data"]
    print("  attached, read back:", got["id"] if got else None, "→", "OK" if got and got["id"] == b["id"] else "MISMATCH")


def cmd_submit(vs):
    v = find_version(vs)
    print(f"version {vs}: {v['attributes']['appStoreState']}")
    if not APPLY:
        print("  DRY: would create reviewSubmission + item + submit"); return
    rs = call("POST", "/v1/reviewSubmissions", {"data": {
        "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    call("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rs["id"]}},
                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
    call("PATCH", f"/v1/reviewSubmissions/{rs['id']}", {"data": {
        "type": "reviewSubmissions", "id": rs["id"], "attributes": {"submitted": True}}})
    back = call("GET", f"/v1/reviewSubmissions/{rs['id']}")["data"]["attributes"]
    v2 = find_version(vs)
    print(f"  submission {rs['id']}: state {back.get('state')} submitted {back.get('submittedDate')}; "
          f"version now {v2['attributes']['appStoreState']}")


def cmd_status(vs):
    v = find_version(vs)
    if not v:
        print(f"version {vs}: absent"); return
    print(f"version {vs}: {v['id']} {v['attributes']['appStoreState']}")
    b = call("GET", f"/v1/appStoreVersions/{v['id']}/build")["data"]
    print("  build:", (b["attributes"].get("version"), b["attributes"].get("processingState")) if b else None)
    for l in localizations(v["id"]):
        a = l["attributes"]
        print(f"  {a['locale']}: desc {len(a.get('description') or '')} notes {len(a.get('whatsNew') or '')}"
              f"{'  ⚠️ in and out' if 'in and out' in (a.get('description') or '') else ''}")
    subs = call("GET", f"/v1/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS&limit=5")["data"]
    for s in subs:
        print("  submission", s["id"], s["attributes"].get("state"), s["attributes"].get("submittedDate"))


cmds = {"version": lambda: cmd_version(args[1]),
        "listing": lambda: cmd_listing(args[1], args[2]),
        "build": lambda: cmd_build(args[1], args[2]),
        "submit": lambda: cmd_submit(args[1]),
        "status": lambda: cmd_status(args[1])}
if not args or args[0] not in cmds:
    print(__doc__); sys.exit(2)
cmds[args[0]]()
