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

WHY THESE TOKENS (re-scored per storefront 2026-09-15; see the 2026-09-11
block below for the previous round, kept because its reasoning still binds)
--------------------------------------------------------------------
The app has **8 ratings** (`python3 scripts/app-ratings.py`; this said 5 for
days). Ratings cap position; keywords only buy eligibility. That decides the
whole strategy:

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

THE 2026-09-15 RE-SCORE — what changed and why
-----------------------------------------------
Every locale was re-scored in its OWN storefront. Six findings that the fields
below act on, each MEASURED unless marked:

🔴 **`ru` and `ar-SA` carried an ENGLISH field, which cannot match anything.**
Apple indexes tokens; a Cyrillic or Arabic query has no Latin token to hit. So
those two fields bought exactly zero. They are now native. `виртуальный номер`
is pop 66 / diff 40 (opportunity 40 — SimCode 189 ratings, WhatsApp-number app
413) and `временная почта` 68/47; Arabic `رقم ثاني` 55/46 and `رقم افتراضي`
40/34. ⚠️ Their NAME and SUBTITLE stay English, so this buys ELIGIBILITY, not
conversion — a matching user still lands on an English product page. The full
win needs native name+subtitle, which is a separate decision.
⚠️ Rejected: `почта` alone is 64/**82** (Яндекс Почта 640k, Почта России 1.6M).

🔴 **`telefonnummer` was the biggest single miss.** `zweite telefonnummer` is
pop 78 / diff 50, **opportunity 39 — the best score found in any locale**, and
its incumbents are beatable (2Number 3,006 · Hushed 231 · TapCall 62 · Duoline
10). It is in neither the de name (`Zweitnummer`) nor subtitle (`USA-Nummer`),
so it was genuinely unbought. It displaces `handynummer` (39/46 — strictly
worse at 2 fewer chars) and `trashmail` (29/41).

⚠️ **Three tokens were buying the wrong intent, not merely a weak one:**
  fr `activation`  46/60, and the top result is *Jupi – AI Chat Character*
  fr `boite`       "boite temporaire" 42/41 returns TEMP-WORK AGENCIES —
                   iziwork, Manpower, Randstad. *Boîte* reads as "firm" there.
  ja `ワンタイム`    ワンタイムパスワード 56/70 returns BANK TOKEN apps

⚠️ **Two tokens had no volume at all.** ja `テンポラリ`: "テンポラリメール" is
popularity **1** with **one** search result, which is vSMS itself — six
characters proving nothing. pt-BR `correio`: "correio temporario" is popularity
**10**; *Correios* is the postal service, and Brazilians search `email`.
Also dropped: pt-BR `caixa` ("caixa de entrada" 65/**78** — Mail 443k, Gmail
431k, Outlook 1.5M).

⚠️ **`us`-number intent DOES sell outside Europe.** The note below says the
US-number angle does not sell — that is confirmed FOR EUROPE (`numero
americain` fr 34/57, `numero americano` es 3/22) and is **not a general rule**:
`رقم امريكي` scores 48/44 in Saudi Arabia and `numero americano` 44/43 in
Brazil. Both fields buy it; the European ones still do not.

⚠️ **`sms activate` measures 62/54 (Good Target) in the US and is deliberately
NOT bought.** *SMS-Activate* is a competitor service in this exact space, so it
hits both the 2.3.7 third-party-name risk and the absolute standing rule
against alluding to a supplier.

⚠️ **`text` and `call` leave the English fields.** Every phrase they form is
TextNow (920k ratings) / Text Me (673k) / Text Free (603k) territory. This
further de-emphasises the SUBSCRIPTION product in search, which is a deliberate
trade: the second-number cluster is unwinnable at 8 ratings and the
verification cluster is not.

⚠️ **en-CA keeps `2nd` and the other English fields do not.** Canada is the one
English storefront where the second-number cluster is not owned by a giant —
TextNow has 79k CA ratings against 920k US, Text Free 16k against 603k — so
`second number` is 64/50 "Good Target" in CA versus 71/66 in the US.

⚠️ **en-GB was tuned partly on INDIA's scores** (`temp mail` 69/44, `burner
email` 40/29, `sms receiver` 43/32 — every token is cheap there) on the
premise that en-GB is Apple's fallback for the Indian storefront. **That
premise is INFERRED and unverified** — this file documents only that en-US is
the fallback for NL/SE/DK/NO/FI/PL. Confirm it before treating the GB field as
an India play.

NEVER RE-ADD (see the aso-listing skill):
  anonymous          unverifiable under 2.3.7 — Sign in with Apple is mandatory
  privacy / private  owned by VPNs and password managers
  data               the eSIM line is parked; that is vRoam's word now
  sms activate       a competitor's name — see above

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

# 🔴 There is no shared EN constant any more. The four English storefronts
# diverge because their DIFFICULTY does: `fake number` is 50/45 in GB and
# 62/67 in the US; `second number` is 64/50 in CA and 71/66 in the US;
# `temp inbox` is 50/46 in the US and 35/51 in AU. One string for all four
# was leaving cheap tokens unbought in three of them.

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
    # 🔴 `email` is here deliberately. 2.14 dropped it by hand for `sim` and
    # `usa` — `usa` was already in the subtitle and bought nothing, while
    # losing `email` put the app outside the top 182 for `temporary email`
    # (71/52, a good target) in the storefront that is 64% of all revenue.
    # `receive` AND `receiver` are both bought: Apple does not substring-match,
    # and "sms receiver" is 55/44 with a 153-rating leader.
    "en-US": "email,mail,temporary,disposable,virtual,online,receive,code,"
             "otp,verify,burner,receiver,instant,inbox",
    # GB difficulty is uniformly softer than US: `disposable email` 66/51 here
    # vs 65/59, `fake number` 50/45 vs 62/67. See the India caveat above.
    "en-GB": "email,mail,temporary,disposable,virtual,online,receive,code,"
             "otp,verify,burner,receiver,fake,instant",
    # ⚠️ `2nd` is bought HERE ONLY — Canada is the one English storefront where
    # the second-number cluster is not owned by a giant (TextNow 79k CA
    # ratings vs 920k US). 5 chars are deliberately unspent: every remaining
    # CA candidate scored difficulty >= 50, and padding with one buys nothing.
    "en-CA": "email,mail,temporary,disposable,virtual,online,receive,code,"
             "otp,verify,burner,receiver,fake,2nd",
    # ⚠️ `inbox` is deliberately NOT here — "temp inbox" is 35/51 in AU, its
    # worst reading of the four English storefronts (US 50/46, CA 41/50).
    "en-AU": "email,mail,temporary,disposable,virtual,online,receive,code,"
             "otp,verify,burner,receiver,throwaway",
    # 🔴 ru and ar-SA were carrying the ENGLISH field, which cannot match a
    # Cyrillic or Arabic query at all. Native now. Their name+subtitle stay
    # English, so this buys eligibility, not conversion — see above.
    "ru":    "виртуальный,номер,временная,временный,почта,смс,код,второй,"
             "получить,одноразовая,телефона,онлайн",
    # 18 chars unspent on purpose: Arabic morphological variants (ارقام,
    # امريكا) were not scored, and this file does not guess.
    "ar-SA": "رقم,ثاني,مؤقت,وهمي,افتراضي,امريكي,بريد,ايميل,كود,تحقق,تفعيل,"
             "استقبال,رسائل,سمس,هاتف",
    # `activation` and `boite` removed — both bought the WRONG intent (AI-chat
    # apps and temp-work agencies respectively), and `activation` was the most
    # expensive token in the field at 11 chars. `number` is bought because
    # French users search the English phrase: "temp number" 54/48.
    "fr-FR": "recevoir,mail,verification,virtuel,jetable,deuxieme,code,email,"
             "otp,temp,number,telephone,faux",
    # 🔴 `telefonnummer` unlocks "zweite telefonnummer" 78/50, opportunity 39 —
    # the best score in any locale. It displaces `handynummer` (39/46, worse at
    # 2 fewer chars) and `trashmail` (29/41; `wegwerf` already serves that
    # cluster at "wegwerf mail" 38/30).
    "de-DE": "virtuelle,empfangen,verifizierung,zweite,mail,email,wegwerf,"
             "telefonnummer,online,otp,fake,temporare",
    # `telefono` completes "numero telefono" 47/45 and "telefono virtual"
    # 43/40. ⚠️ `temporal` is in the SUBTITLE and correctly absent — "correo
    # temporal" (48/25 Sweet Spot) is already formable from `correo` alone.
    # `desechable` survives its 11 chars because "correo desechable" is 30/19,
    # a Hidden Gem whose entire top 5 is 0–1-rating apps.
    "es-ES": "correo,recibir,virtual,verificacion,codigo,desechable,email,"
             "online,telefono,mail,falso,movil,otp",
    # 🔴 es-MX is IDENTICAL to es-ES on purpose, not by oversight. The two
    # share name and subtitle character-for-character and the scorer returns
    # the same competitor set for both, so a manufactured difference would
    # mean spending characters on a token neither storefront justifies.
    "es-MX": "correo,recibir,virtual,verificacion,codigo,desechable,email,"
             "online,telefono,mail,falso,movil,otp",
    # 🔴 The it subtitle's `temporanei` is PLURAL and does NOT cover the
    # singular forms people search — `temporanea` (mail temporanea 59/32,
    # opportunity 40, the best-scoring term in any locale) and `temporaneo`.
    # Bought deliberately, and the 2026-09-15 re-score confirmed the call.
    # `telefono` adds "numero di telefono" 68/49, the highest-popularity
    # Italian term measured. Removed: `spam` (pulls anti-spam BLOCKERS, the
    # same trap this file already documents for en — it was applied
    # inconsistently) and `numeri` (plural, and "numeri virtuali" also needs
    # the plural adjective `virtuali`, which the field does not carry, so it
    # completed nothing — 7 dead chars).
    # ⚠️ `getta` is load-bearing: `usa` sits in the it SUBTITLE, so `getta`
    # alone completes "mail usa e getta" 48/44.
    "it":    "mail,temporanea,temporaneo,virtuale,verifica,ricevere,codice,"
             "email,getta,ricevi,telefono,falso,otp",
    # `correio` removed at popularity 10 — *Correios* is the postal service and
    # Brazilians search `email`. `caixa` removed at 65/78 (Mail 443k, Gmail
    # 431k, Outlook 1.5M). `americano` bought at 44/43: the US-number angle
    # does not sell in EUROPE but it does sell here.
    # ⚠️ Rejected after scoring: `chip` ("chip virtual" 65/55 but the results
    # are Meu TIM 780k and Airalo — carrier and eSIM intent, vRoam's lane) and
    # `celular` ("celular virtual" 61/75, results are Nubank and Neon).
    "pt-BR": "receber,virtual,verificacao,codigo,descartavel,email,online,"
             "otp,mail,falso,telefone,temp,americano",
    # ⚠️ ja is STILL the least confident field. Apple segments Japanese
    # morphologically, so a comma-split check cannot prove a token is free —
    # 使い捨て was caught only by substring against the NAME. 番号 / 認証 /
    # コード / 受信 / 電話番号 / 米国 are all in the name or subtitle and
    # excluded; 仮想 suffices for 仮想番号. 無料 ("free") is omitted on the same
    # 2.3.7 reasoning that removed `anonymous`.
    #
    # 🔴 Two tokens deleted for cause. `テンポラリ`: "テンポラリメール" is
    # popularity **1** with exactly ONE search result, which is vSMS itself —
    # six characters proving nothing. `ワンタイム`: ワンタイムパスワード is
    # 56/70 and returns BANK TOKEN apps (PayPay 15k, しんきん), not this
    # product.
    #
    # 🔴 `使い捨てメール` is deliberately NOT bought, though it scores 38/46.
    # It CONTAINS 使い捨て, which is already in the app NAME, and メール, which
    # is already in this field — so if Apple's segmenter splits it, all 7
    # characters are wasted. It was also the WEAKEST of the four e-mail terms
    # available (opportunity 21) while costing the most. `一時メール` is the
    # one to hold instead: 39/**31 Easy**, opportunity 27, 5 chars, and its
    # leader "Temp Mail - 一時メール" has 206 ratings.
    #
    # ⚠️ 32 of 100 characters are UNSPENT, on purpose. The last five tokens
    # (アドレス, アメリカ, 海外, 携帯, アカウント) are INFERRED, not scored: the
    # scorer returns figures only for full phrases. **This field needs a
    # native-speaker pass, not more guessing.**
    "ja":    "仮想,メール,メアド,捨てメアド,一時,一時的,一時メール,アドレス,"
             "サブ垢,アメリカ,海外,携帯,アカウント,迷惑メール,スパム,登録",
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
