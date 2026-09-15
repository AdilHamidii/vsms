#!/usr/bin/env python3
"""Lint a keyword field BEFORE it is approved or written.

Read-only. Exits 1 on any finding.

This is the authoring-time companion to `asc-listing-check.py`, which compares
the LIVE listing against the approved list. This one asks a different question:
**is the approved list itself any good?**

🔴 **It would have caught the mistake that shipped.** 2.14's en-US field added
`usa` while the subtitle already read "USA Phone Line & Verification" — a
wasted token, because Apple indexes name + subtitle + keyword field as ONE
pool. The characters for it came out of `email`, which was carrying the whole
e-mail cluster in the storefront that is 64% of all revenue. Nothing checked,
so nothing complained.

WHAT IT CHECKS
--------------
1. **Length ≤ 100 characters**, counted exactly. Apple rejects a longer field
   outright.
2. **No token already in that locale's own name or subtitle** — fetched live
   from ASC, per locale, because the wasted set differs per locale and a field
   cannot be copied between them.
3. **No banned token.** `anonymous` is unverifiable under Guideline 2.3.7 since
   Sign in with Apple is mandatory; `privacy`/`private` are owned by VPNs and
   password managers; `data` belongs to the sibling eSIM app.
4. **No duplicate token inside the field**, and no space after a comma — a
   space costs a character and buys nothing.

⚠️ **Japanese is matched by SUBSTRING, not by token equality.** Apple segments
Japanese morphologically, so a comma-split check cannot prove a token is free:
`使い捨て` was once caught only by substring against the NAME. Any token with no
ASCII letters is therefore substring-checked against the whole name+subtitle.

Usage:
    python3 scripts/asc-keyword-lint.py
    python3 scripts/asc-keyword-lint.py --field en-US=mail,virtual,otp,verify
"""
import importlib.util
import json
import pathlib
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.request

import jwt

_spec = importlib.util.spec_from_file_location(
    "asc_keywords", pathlib.Path(__file__).with_name("asc-keywords.py"))
_kw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_kw)

KEY, KID, ISS, APP, LIMIT = _kw.KEY, _kw.KID, _kw.ISS, _kw.APP, _kw.LIMIT

# See the docstring for why each of these is refused.
BANNED = {
    "anonymous", "anonyme", "anonym", "anonimo", "anonimo",
    "privacy", "private", "prive", "privat", "privado", "privato",
    "data", "dati", "datos", "daten",
}


def token():
    return jwt.encode(
        {"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 900,
         "aud": "appstoreconnect-v1"},
        open(KEY).read(), algorithm="ES256", headers={"kid": KID})


def call(path, attempts=3):
    """⚠️ Catch URLError too, not just HTTPError. A network blip is a bare
    URLError and an uncaught one tracebacks out of a LINTER — turning 'I could
    not reach Apple' into what looks like a broken script."""
    for attempt in range(attempts):
        req = urllib.request.Request(
            "https://api.appstoreconnect.apple.com" + path,
            headers={"Authorization": "Bearer " + token()})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            print(f"  ASC {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
            return {}
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if attempt == attempts - 1:
                print(f"  ASC unreachable after {attempts} tries: {e}", file=sys.stderr)
                return {}
            time.sleep(2 * (attempt + 1))
    return {}


def fold(s):
    """Lowercase and strip accents — Apple indexes the field accent-stripped."""
    return "".join(c for c in unicodedata.normalize("NFD", s.lower())
                   if unicodedata.category(c) != "Mn")


def name_subtitle():
    """Live name+subtitle per locale. These are app-level, not per-version."""
    out = {}
    for info in call(f"/v1/apps/{APP}/appInfos?limit=10").get("data", []):
        got = call(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50"
                   "&fields[appInfoLocalizations]=locale,name,subtitle")
        for l in got.get("data", []):
            a = l["attributes"]
            pair = f"{a.get('name') or ''} {a.get('subtitle') or ''}"
            if pair.strip():
                out[a["locale"]] = pair
    return out


def lint(locale, field, pair):
    findings = []
    n = len(field)
    if n > LIMIT:
        findings.append(f"LENGTH {n}/{LIMIT} — Apple rejects this outright")
    if ", " in field:
        findings.append("a space follows a comma — costs characters, buys nothing")

    tokens = [t for t in field.split(",") if t]
    seen = set()
    for t in tokens:
        f = fold(t)
        if f in seen:
            findings.append(f"duplicate token inside the field: {t!r}")
        seen.add(f)
        if f in BANNED:
            findings.append(f"banned token {t!r} — see the docstring")

    if pair is None:
        findings.append("no name/subtitle found for this locale — cannot check "
                        "duplicates (is the locale live?)")
        return findings, n

    folded_pair = fold(pair)
    pair_tokens = set(re.findall(r"[a-z0-9]+", folded_pair))
    for t in tokens:
        f = fold(t)
        ascii_ish = re.fullmatch(r"[a-z0-9]+", f)
        hit = (f in pair_tokens) if ascii_ish else (f in folded_pair)
        if hit:
            findings.append(
                f"WASTED {t!r} — already indexed via name/subtitle ({pair.strip()!r})")
    return findings, n


def main():
    fields = dict(_kw.KEYWORDS)
    if "--field" in sys.argv:
        spec = sys.argv[sys.argv.index("--field") + 1]
        locale, _, value = spec.partition("=")
        fields = {locale: value}
        print(f"Linting one proposed field for {locale}\n")

    pairs = name_subtitle()
    total = 0
    for locale in sorted(fields):
        findings, n = lint(locale, fields[locale], pairs.get(locale))
        mark = "FAIL" if findings else "ok"
        print(f"{locale:<8} {n:>3}/{LIMIT} chars  [{mark}]")
        for f in findings:
            print("   " + f)
        total += len(findings)

    print(f"\n{'=' * 60}\n{total} finding(s) across {len(fields)} locale(s).")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
