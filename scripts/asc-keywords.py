#!/usr/bin/env python3
"""Set the 100-char keyword field, per locale.

🔴 **KEYWORDS NEED REVIEW.** Unlike `promotionalText`, this field only ships
with a new version. This script therefore REFUSES to write to a version that is
waiting for or in review — editing metadata there risks the queue position, and
the owner submits by hand. Run it against a `PREPARE_FOR_SUBMISSION` version.

HOW APPLE INDEXES THIS (the thing that decides every token below)
-----------------------------------------------------------------
🔴 **Name + subtitle + keyword field are ONE pool.** Apple composes multi-word
queries from tokens across all three, so a token already in the name or
subtitle is WASTED here.

    name     "vSMS: Second Number & Temp SMS"  -> vsms second number temp sms
    subtitle "USA Phone Line & Verification"   -> usa phone line verification

⚠️ **So `usa` does NOT belong in this field, and never did.** CLAUDE.md called
its absence the app's big ASO gap; it has been indexed via the subtitle since
2.10 (2026-09-06). Same for `second` and `number` — the second-number intent is
already carried by the NAME, the highest-weight field there is.

⚠️ Apple does not substring-match: `email` does NOT match a search for "mail",
and `verification` does not match "verify". Those are separate tokens and each
has to be bought separately.

WHY THESE TOKENS (scored via aso-connect, us storefront, 2026-09-11)
--------------------------------------------------------------------
The app has **5 ratings**. Ratings cap position; keywords only buy eligibility.
That decides the whole strategy:

  UNWINNABLE, so not bought here:
    second phone number  pop 92  diff 73   TextNow 919k ratings, Text Free 602k
    fake number          pop 62  diff 67   same giants
    spam                                   pulls spam-BLOCKER intent, not buyers

  WINNABLE, and the same "temp SMS" intent the owner named:
    receive sms          pop 83  diff 56   top rivals 153 / 7.2k / 28k ratings
    receive sms online   pop 65  diff 46   top rival has 153 ratings
    sms verification     pop 68  diff 54   UCODE has 10 ratings
    sms code             pop 62  diff 52
    temporary email      pop 70  diff 54
    temp mail            pop 82  diff 65   rivals 20k / 551 / 95 / 33

🔴 `mail` is the token that was missing. "temp mail" is pop 82 — higher than
"second number" — and was UNFORMABLE despite `Temp` sitting in the app name,
because the field carried `email` and Apple will not match `mail` against it.

⚠️ `burner` is kept at the OWNER'S EXPLICIT INSTRUCTION (2026-09-11), against
the scoring: pop 61 but difficulty 67, with Burner.app at 93k ratings, and the
owner had paused it as an ASA keyword on 2026-09-07 for drawing two-way-texting
intent this product cannot serve (outbound SMS outside NANP is blocked). It
displaced `inbox`, whose email-cluster job is still covered by `email`+`mail`.

NEVER RE-ADD (see the aso-listing skill):
  anonymous          unverifiable under 2.3.7 — Sign in with Apple is mandatory
  privacy / private  owned by VPNs and password managers
  data               the eSIM line is parked; that is vRoam's word now

Usage:
    python3 scripts/asc-keywords.py            # dry run
    python3 scripts/asc-keywords.py --apply    # writes, then reads back
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
LIMIT = 100

EN = ("email,virtual,disposable,temporary,online,otp,code,burner,"
      "mail,verify,receive,text,call,2nd,get")

# ⚠️ No spaces after commas — a space costs a character and buys nothing.
#
# 🔴 EVERY LOCALE IS CHECKED AGAINST ITS OWN NAME + SUBTITLE, which differ.
# de-DE's subtitle carries `Nummer`, fr-FR's carries `temporaire`, it's carries
# the PLURAL `temporanei` — so the wasted-duplicate set differs per locale and
# a field cannot be copied between them.
#
# Scored via aso-connect per storefront on 2026-09-11 (popularity/difficulty):
#   fr  mail temporaire 58/34 SWEET · recevoir sms 55/36 · numero virtuel 54/47
#       verification sms 48/40 · recevoir code 40/30 SWEET
#   de  virtuelle nummer 71/46 GOOD · sms empfangen 71/58 · temp mail 67/61
#       sms verifizierung 42/29 SWEET · zweite nummer 58/51
#   es  recibir sms 64/49 GOOD · correo temporal 53/26 SWEET
#       numero virtual 52/42 · verificacion sms 38/25 HIDDEN GEM
#   it  numero virtuale 64/44 GOOD · secondo numero 63/47 GOOD
#       mail temporanea 59/31 SWEET (opportunity 41 — best of any locale)
#       verifica sms 53/33 SWEET · sms temporaneo 40/30 SWEET
#
# ⚠️ `numero americain` (fr) scores 34/57 and `numero americano` (es) 3/22.
# **The US-number angle does NOT sell in Europe.** These fields buy
# verification and temp-mail intent instead, which is what Europe searches.
KEYWORDS = {
    # en-US is also the fallback locale for NL/SE/DK/NO/FI/PL.
    # ru and ar-SA carry ENGLISH name+subtitle on this listing, so they get the
    # English field — better than the `generator,throwaway,trash,minute` padding
    # they held, though a native field would beat both. Neither is a real
    # market yet (single-digit installs).
    "en-US": EN, "en-GB": EN, "en-CA": EN, "en-AU": EN, "ru": EN, "ar-SA": EN,
    "fr-FR": "recevoir,mail,verification,virtuel,jetable,deuxieme,code,email,"
             "otp,temp,boite,activation",
    "de-DE": "virtuelle,empfangen,verifizierung,zweite,mail,email,wegwerf,"
             "handynummer,online,otp,trashmail",
    "es-ES": "correo,recibir,virtual,verificacion,codigo,desechable,email,"
             "online,otp,mail,falso,movil",
    "es-MX": "correo,recibir,virtual,verificacion,codigo,desechable,email,"
             "online,otp,mail,falso,movil",
    # 🔴 The it subtitle's `temporanei` is PLURAL and does NOT cover the
    # singular forms people search — `temporanea` (mail temporanea, the single
    # best-scoring term in any locale) and `temporaneo`. Bought deliberately.
    "it":    "mail,temporanea,temporaneo,virtuale,verifica,ricevere,codice,"
             "email,getta,ricevi,numeri,spam",
    "pt-BR": "correio,receber,virtual,verificacao,codigo,descartavel,email,"
             "online,otp,mail,caixa,falso",
    # ⚠️ ja is the LEAST confident field here. Apple segments Japanese
    # morphologically, so a comma-split check cannot prove a token is not
    # already covered — 使い捨て was caught only by substring against the NAME.
    # 番号 / 認証 / コード / 受信 / 電話番号 / 米国 are all in the name or
    # subtitle and excluded; 仮想 suffices for 仮想番号. Japan is ~164 installs
    # in 40 days, so this stays deliberately conservative. 無料 ("free") is
    # omitted on the same 2.3.7 reasoning that removed `anonymous`.
    "ja":    "仮想,ワンタイム,メール,一時的,スパム,テンポラリ,迷惑メール,登録",
}

# A version in either of these states must not be edited.
REVIEW_STATES = {
    "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE",
    "PROCESSING_FOR_APP_STORE", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION",
}

APPLY = "--apply" in sys.argv


def token():
    return jwt.encode(
        {"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1000,
         "aud": "appstoreconnect-v1"},
        open(KEY).read(), algorithm="ES256", headers={"kid": KID})


def call(method, path, body=None):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path, method=method,
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
    over = {k: len(v) for k, v in KEYWORDS.items() if len(v) > LIMIT}
    if over:
        raise SystemExit(f"over {LIMIT} chars: {over}")
    for k, v in KEYWORDS.items():
        print(f"  {k:<8} {len(v):>3}/{LIMIT}  {v}")

    st, vers = call("GET", f"/v1/apps/{APP}/appStoreVersions?limit=10"
                           "&fields[appStoreVersions]=versionString,appStoreState")
    if st != 200:
        raise SystemExit(f"versions HTTP {st}: {vers}")

    editable = [v for v in vers["data"]
                if v["attributes"]["appStoreState"] not in REVIEW_STATES]
    if not editable:
        states = ", ".join(f"{v['attributes']['versionString']}="
                           f"{v['attributes']['appStoreState']}"
                           for v in vers["data"][:3])
        raise SystemExit(
            "\n🔴 No editable version. Keywords need REVIEW, so they cannot be\n"
            "   changed on a version already waiting for it without risking the\n"
            "   queue position. Create the next version first.\n"
            f"   Current: {states}")

    v = editable[0]
    vid, vstr = v["id"], v["attributes"]["versionString"]
    print(f"\ntarget: {vstr} ({v['attributes']['appStoreState']})")

    st, locs = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"
                           "?limit=50&fields[appStoreVersionLocalizations]=locale,keywords")
    if st != 200:
        raise SystemExit(f"localizations HTTP {st}: {locs}")

    for loc in locs["data"]:
        code = loc["attributes"]["locale"]
        want = KEYWORDS.get(code)
        if not want:
            continue
        have = (loc["attributes"].get("keywords") or "").strip()
        if have == want:
            print(f"  {code:<8} already set")
            continue
        print(f"  {code:<8} was: {have}")
        if not APPLY:
            print(f"  {code:<8} now: {want}   (dry run)")
            continue
        wst, wres = call("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}",
                         {"data": {"type": "appStoreVersionLocalizations",
                                   "id": loc["id"],
                                   "attributes": {"keywords": want}}})
        print(f"  {code:<8} PATCH {wst}" + ("" if wst == 200 else f" {wres}"))

    if not APPLY:
        print("\nDRY RUN — nothing written. Re-run with --apply")
        return

    # 🔴 Read back: this API answers 200 for writes it silently ignores.
    st, locs = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"
                           "?limit=50&fields[appStoreVersionLocalizations]=locale,keywords")
    got = {l["attributes"]["locale"]: (l["attributes"].get("keywords") or "").strip()
           for l in locs["data"]}
    bad = [c for c, t in KEYWORDS.items() if got.get(c) != t]
    print(f"\nREAD BACK: {len(KEYWORDS) - len(bad)}/{len(KEYWORDS)} match"
          + (f"  MISMATCH: {bad}" if bad else ""))
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
