#!/usr/bin/env python3
import json, sys, time, urllib.request, urllib.error
import jwt
KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46"
tok = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1000,
                  "aud": "appstoreconnect-v1"}, open(KEY).read(), algorithm="ES256",
                 headers={"kid": KID})
H = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}


def get(p):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + p, headers=H, method="GET")
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"__error": e.code, "__body": e.read().decode()[:2000]}


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print("### " + p)
        print(json.dumps(get(p), indent=1)[:20000])
