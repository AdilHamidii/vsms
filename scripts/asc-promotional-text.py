#!/usr/bin/env python3
"""Set `promotionalText` on the App Store listing, per locale.

WHY THIS FIELD IS DIFFERENT
---------------------------
🔴 **Promotional text is the ONLY listing field that changes WITHOUT review.**
It is editable on the version that is `READY_FOR_SALE` and updates on the live
product page within minutes. That is its entire point.

⚠️ Which means: setting it ONLY on the editable (in-review) version means
**nobody sees it until that version ships.** Both have to be written — the live
version so it is visible now, the editable one so the release does not wipe it
(a new version does NOT inherit it once its localizations already exist).

⚠️ **It is NOT indexed by Apple Search.** Name, subtitle and the 100-char
keyword field are; promotional text is not. So it is a CONVERSION lever on the
product page (tap→install), never a ranking lever. Do not spend keywords here.

COPY RULES THIS FILE OBEYS (see CLAUDE.md "Copy rules")
- never quote a credit amount or any server-owned number
- never name or allude to a supplier
- no price claims: `en-US` is the FALLBACK locale for NL/SE/DK/NO/FI/PL, so a
  "$3.99" written here would render in Sweden.

Usage:
    python3 scripts/asc-promotional-text.py            # dry run, prints + reads back
    python3 scripts/asc-promotional-text.py --apply    # writes
"""
import json
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID = "R5ZVLBTUR6"
ISS = "4644ed13-4d98-489e-a94b-687f63946f46"
APP = "6774768570"
LIMIT = 170

# One app, three jobs. Localized to the tone of each locale's existing subtitle
# (de-DE "USA-Nummer & SMS-Code", fr-FR "Ligne USA & SMS temporaire", ...).
# ⚠️ `ru` and `ar-SA` carry ENGLISH name+subtitle on this listing — they get the
# English string on purpose, not a translation of it.
EN = ("One app, three jobs: a real US number you keep for calls and texts, "
      "temp numbers for sign-up codes, and temp email addresses. "
      "No SIM, no contract.")

TEXT = {
    "en-US": EN, "en-GB": EN, "en-CA": EN, "en-AU": EN, "ru": EN, "ar-SA": EN,
    # ⚠️ Accents ARE written here. The keyword field strips them on purpose
    # (indexing); this is display copy on the product page, where "numero
    # americain" reads as a typo to the exact market it targets.
    "fr-FR": ("Une app, trois usages : un vrai numéro américain pour appels et SMS, "
              "des numéros temporaires pour vos codes, et des e-mails jetables. "
              "Sans SIM, sans engagement."),
    "de-DE": ("Eine App, drei Aufgaben: eine echte US-Nummer für Anrufe und SMS, "
              "temporäre Nummern für Anmeldecodes und Wegwerf-E-Mail-Adressen. "
              "Ohne SIM, ohne Vertrag."),
    "es-ES": ("Una app, tres funciones: un número de EE. UU. real para llamadas y SMS, "
              "números temporales para códigos de registro y correos desechables. "
              "Sin SIM, sin contrato."),
    "es-MX": ("Una app, tres funciones: un número de EE. UU. real para llamadas y SMS, "
              "números temporales para códigos de registro y correos desechables. "
              "Sin SIM, sin contrato."),
    "it": ("Un'app, tre funzioni: un vero numero USA per chiamate e SMS, numeri "
           "temporanei per i codici di registrazione ed e-mail usa e getta. "
           "Senza SIM, senza contratto."),
    "pt-BR": ("Um app, três funções: um número dos EUA real para chamadas e SMS, "
              "números temporários para códigos de cadastro e e-mails descartáveis. "
              "Sem SIM, sem contrato."),
    "ja": ("1つのアプリで3役。通話とSMSに使える本物の米国電話番号、登録コード受信用の"
           "使い捨て番号、そして使い捨てメールアドレス。SIM不要、契約不要。"),
}

APPLY = "--apply" in sys.argv


def token():
    return jwt.encode(
        {"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1000,
         "aud": "appstoreconnect-v1"},
        open(KEY).read(), algorithm="ES256", headers={"kid": KID})


def call(method, path, body=None):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": "Bearer " + token(),
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, {"_body": e.read().decode()[:400]}


def main():
    over = {k: len(v) for k, v in TEXT.items() if len(v) > LIMIT}
    if over:
        raise SystemExit(f"over {LIMIT} chars: {over}")
    print(f"{len(TEXT)} locales, longest {max(len(v) for v in TEXT.values())}/{LIMIT} chars")

    st, vers = call("GET", f"/v1/apps/{APP}/appStoreVersions?limit=10"
                           "&fields[appStoreVersions]=versionString,appStoreState")
    if st != 200:
        raise SystemExit(f"versions HTTP {st}: {vers}")

    # The LIVE version (visible today) and the editable one (so the release
    # does not wipe what we just set). Both, always.
    targets = []
    for v in vers["data"]:
        state = v["attributes"]["appStoreState"]
        if state == "READY_FOR_SALE" and not any(t[2] == "live" for t in targets):
            targets.append((v["id"], v["attributes"]["versionString"], "live"))
        elif state not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"):
            targets.append((v["id"], v["attributes"]["versionString"], "editable"))
    if not targets:
        raise SystemExit("no target versions found")

    for vid, vstr, kind in targets:
        print(f"\n=== {vstr} ({kind}) ===")
        st, locs = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"
                               "?limit=50&fields[appStoreVersionLocalizations]="
                               "locale,promotionalText")
        if st != 200:
            print(f"  read HTTP {st}: {locs}")
            continue
        for loc in locs["data"]:
            code = loc["attributes"]["locale"]
            want = TEXT.get(code)
            if not want:
                print(f"  {code:<8} SKIP (no copy written for this locale)")
                continue
            have = (loc["attributes"].get("promotionalText") or "").strip()
            if have == want:
                print(f"  {code:<8} already set")
                continue
            if not APPLY:
                print(f"  {code:<8} would set ({len(want)} chars)")
                continue
            wst, wres = call("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}",
                             {"data": {"type": "appStoreVersionLocalizations",
                                       "id": loc["id"],
                                       "attributes": {"promotionalText": want}}})
            print(f"  {code:<8} PATCH {wst}" + ("" if wst == 200 else f" {wres}"))

    if not APPLY:
        print("\nDRY RUN — nothing written. Re-run with --apply")
        return

    # 🔴 Read back. This API answers 200 for writes it does not keep.
    print("\n=== READ BACK ===")
    bad = 0
    for vid, vstr, kind in targets:
        st, locs = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"
                               "?limit=50&fields[appStoreVersionLocalizations]="
                               "locale,promotionalText")
        got = {l["attributes"]["locale"]: (l["attributes"].get("promotionalText") or "").strip()
               for l in locs["data"]}
        ok = sum(1 for c, t in TEXT.items() if got.get(c) == t)
        missing = [c for c in TEXT if c in got and got.get(c) != TEXT[c]]
        bad += len(missing)
        print(f"  {vstr} ({kind}): {ok}/{len(TEXT)} locales match"
              + (f"  MISMATCH: {missing}" if missing else ""))
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
