#!/usr/bin/env python3
"""Create the Telnyx iOS VoIP push credential from an Apple certificate.

Ran once on 2026-08-06 to produce credential
`65804c06-85e1-4467-b868-818e9e370ac8`. Kept because the certificate EXPIRES
2027-09-05 and the failure is silent — Telnyx keeps accepting the connection
and the phone simply stops ringing — so this has to be repeatable by someone
who has forgotten every detail of it.

    TELNYX_API_KEY='KEY...' python3 scripts/finish-telnyx.py ~/Downloads/voip_services.cer

Working directory for the keypair defaults to ~/Desktop/telnyx-voip and is
overridable with TELNYX_VOIP_DIR. It must contain `voip.key` — the key the CSR
was generated from. **That key cannot be recovered**: without it the
certificate is unusable and the whole Apple-portal step has to be redone.

Renewal, start to finish:

    openssl req -new -newkey rsa:2048 -nodes \\
        -keyout voip.key -out voip.csr -subj "/CN=vSMS VoIP Services/O=Anther Systems/C=US"

then developer.apple.com -> Certificates -> + -> Services -> **VoIP Services
Certificate** -> App ID `com.anthersystems.VirtualSIM` (the plain bundle id;
there is no `.voip` App ID — the topic is derived) -> upload voip.csr ->
download -> run this.

⚠️ Apple's App Store Connect API CANNOT mint this certificate. Probed
2026-08-06: `certificateType: VOIP_SERVICES` returns 409 listing the valid
values and VoIP is not among them. The web portal is the only route. The CSR
above is what removes Keychain's Certificate Assistant and the .p12 export
that Telnyx's own documentation walks through.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

WORK = os.path.expanduser(
    os.environ.get("TELNYX_VOIP_DIR", "~/Desktop/telnyx-voip"))
KEY_IN = os.path.join(WORK, "voip.key")
CERT_PEM = os.path.join(WORK, "cert.pem")
KEY_PEM = os.path.join(WORK, "key.pem")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALIAS = "com.anthersystems.VirtualSIM"

api_key = os.environ.get("TELNYX_API_KEY", "").strip()
if not api_key:
    sys.exit("TELNYX_API_KEY is not set (read from the environment so it stays "
             "out of shell history).")
if len(sys.argv) < 2:
    sys.exit("usage: %s <path-to-downloaded.cer>" % sys.argv[0])

cer = os.path.expanduser(sys.argv[1])
if not os.path.exists(cer):
    sys.exit("no such file: %s" % cer)
if not os.path.exists(KEY_IN):
    sys.exit("missing %s — that is the key the CSR was made from and it cannot "
             "be regenerated; the certificate would be useless. Set "
             "TELNYX_VOIP_DIR if it lives elsewhere." % KEY_IN)


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit("FAILED: %s\n%s" % (" ".join(cmd[:3]), (r.stderr or r.stdout)[:500]))
    return r.stdout


# Apple ships DER; some browsers hand back PEM already.
try:
    run(["openssl", "x509", "-inform", "DER", "-in", cer, "-out", CERT_PEM])
except SystemExit:
    run(["openssl", "x509", "-inform", "PEM", "-in", cer, "-out", CERT_PEM])
print("✓ certificate -> cert.pem")

# `openssl req` writes PKCS#8 ("BEGIN PRIVATE KEY"); Telnyx wants PKCS#1
# ("BEGIN RSA PRIVATE KEY"). Skipping this fails at upload, not obviously.
run(["openssl", "rsa", "-in", KEY_IN, "-out", KEY_PEM])
print("✓ private key -> PKCS#1 key.pem")

# A mismatched pair uploads FINE and then never delivers a push, which is
# indistinguishable from every other reason a call does not ring.
if run(["openssl", "x509", "-noout", "-modulus", "-in", CERT_PEM]).strip() != \
        run(["openssl", "rsa", "-noout", "-modulus", "-in", KEY_PEM]).strip():
    sys.exit("✗ certificate and private key are NOT a pair — the .cer was "
             "issued from a different CSR.")
print("✓ certificate and key match")

subject = run(["openssl", "x509", "-noout", "-subject", "-in", CERT_PEM]).strip()
print("  subject:", subject[:120])
if "voip" not in subject.lower():
    print("  ⚠️  subject does not mention VoIP — an ordinary APNs SSL "
          "certificate will NOT carry VoIP pushes.")

body = json.dumps({
    "type": "ios", "alias": ALIAS,
    "certificate": open(CERT_PEM).read(),
    "private_key": open(KEY_PEM).read(),
}).encode()
req = urllib.request.Request(
    "https://api.telnyx.com/v2/mobile_push_credentials", data=body,
    headers={"Authorization": "Bearer %s" % api_key,
             "Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req) as r:
        created = json.load(r)
except urllib.error.HTTPError as e:
    sys.exit("✗ Telnyx rejected the credential (%s):\n%s"
             % (e.code, e.read().decode()[:600]))

cred_id = created["data"]["id"]
print("✓ Telnyx push credential created: %s" % cred_id)

run(["supabase", "secrets", "set",
     "TELNYX_IOS_PUSH_CREDENTIAL_ID=%s" % cred_id], cwd=REPO)
print("✓ secret TELNYX_IOS_PUSH_CREDENTIAL_ID set")

print("… redeploying mint-line-token")
run(["supabase", "functions", "deploy", "mint-line-token"], cwd=REPO)
print("✓ mint-line-token redeployed")

print("\nDone. The next mint-line-token call should report inbound_ready: true.")
print("⚠️ Lines provisioned BEFORE this keep a push-less connection: "
      "mint-line-token only builds one when provider_connection_id is null. "
      "Clear that column on any such line and the next mint rebuilds it.")
