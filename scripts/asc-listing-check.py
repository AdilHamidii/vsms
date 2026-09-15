#!/usr/bin/env python3
"""Assert two listing invariants this repo states but never enforced.

Read-only. Exits 1 if either check fails, so it works as a pre-submission gate
and as a daily cron line.

WHY THIS EXISTS
---------------
🔴 **CHECK 1 — the live keyword field drifted by hand and nothing noticed.**
Version 2.14 dropped `email` from the en-US field to make room for `sim` and
`usa`, matching no approval: `asc-keywords.py` and CLAUDE.md both still carry
the 2.13 list. It was the ONLY locale that changed (verified 2026-09-15 by
diffing all 13 against 2.13), so this was one deliberate edit, not a bulk
re-run.

Both halves of that edit were losses. `usa` bought nothing — the subtitle has
carried "USA Phone Line & Verification" since 2.10 and Apple indexes name +
subtitle + keyword field as ONE pool, which `asc-keywords.py`'s own header
says. And the characters came out of the token carrying the whole e-mail
cluster in the storefront that is 64% of all revenue: `temporary email`
(popularity 71, difficulty 52 — a *good target*) measured OUTSIDE THE TOP 182
in en-US on 2026-09-15, while temp-e-mail is about half of all order volume.

⚠️ Whether that edit caused the ~60% organic drop across the same window is
NOT established — nothing has ever rank-tracked this app, so there is no
before. What is established is that a money-relevant field changed with no
record and no alarm. This script is the alarm.

🔴 **CHECK 2 — a written invariant with no enforcement is not an invariant.**
CLAUDE.md: *"NO LISTING FIELD MAY QUOTE A PRICE — release notes and description
included, in EVERY locale."* It shipped violated anyway: all twelve non-en-US
2.13 release notes quoted the intro offer in DOLLARS, into territories Apple
bills in euros (fr/de/it/es said "3,99 $"), yen (ja said "$3.99" where Japan
pays ¥600) and reais (pt-BR said "US$ 3,99" against R$24.9). Caught by hand
before build 63 went out. The price belongs to StoreKit and to Apple's sheet,
which render it localized and correct; a listing field cannot.

⚠️ `en-US` is the FALLBACK locale for NL/SE/DK/NO/FI/PL, so a dollar figure
there renders in Sweden. That is why en-US is not exempt.

WHAT IT DOES NOT DO
-------------------
It never writes. `asc-keywords.py` stays the only sanctioned writer, and a
disagreement between it and the live listing is a defect to investigate, not
something to silently PATCH away — the drift might be the deliberate change and
the script might be the stale copy.

Usage:
    python3 scripts/asc-listing-check.py            # live + editable versions
    python3 scripts/asc-listing-check.py --all      # every version on record
    python3 scripts/asc-listing-check.py --version 2.14
"""
import importlib.util
import json
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

import jwt

# Import the sanctioned writer for its approved field and its credentials.
# 🔴 Import it, never re-parse it: a regex over those multi-line string
# concatenations reads only the first fragment and reports false drift on every
# locale whose field wraps. That happened while writing this.
_spec = importlib.util.spec_from_file_location(
    "asc_keywords", pathlib.Path(__file__).with_name("asc-keywords.py"))
_kw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_kw)  # safe: the module guards main() behind __main__

KEY, KID, ISS, APP = _kw.KEY, _kw.KID, _kw.ISS, _kw.APP
APPROVED = _kw.KEYWORDS

# The documented set, plus the symbols for the currencies this app actually
# bills in (NGN, TRY, ILS, KRW, THB, VND) so a future locale is covered.
CURRENCY = re.compile(r"[$€£¥₹₦₺₪₩฿₫]|\b(?:USD|EUR|GBP|JPY|INR|US\$)\b")

# Fields that must never carry a price. ⚠️ They live on TWO different
# resources and asking for the wrong one is a 400, not an empty column:
# name/subtitle are app-level (appInfoLocalizations), everything else is
# per-version (appStoreVersionLocalizations).
VERSION_PRICED = ("description", "whatsNew", "promotionalText")
APPINFO_PRICED = ("name", "subtitle")

# ⚠️ Apple leaves EVERY shipped version reading READY_FOR_SALE, not just the
# live one — 27 of them on this app — so that state cannot select "current".
# The default scan is therefore the NEWEST version (Apple returns them
# newest-first) plus anything still editable. --all overrides.
EDITABLE = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "WAITING_FOR_REVIEW", "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
}


def token():
    return jwt.encode(
        {"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 900,
         "aud": "appstoreconnect-v1"},
        open(KEY).read(), algorithm="ES256", headers={"kid": KID})


def call(path):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"  ASC {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
        return {}


def localizations(version_id):
    fields = ",".join(("locale", "keywords") + VERSION_PRICED)
    got = call(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
               f"?limit=50&fields[appStoreVersionLocalizations]={fields}")
    return {l["attributes"]["locale"]: l["attributes"] for l in got.get("data", [])}


def app_info_localizations():
    """Name and subtitle, which are app-level and shared by every version."""
    infos = call(f"/v1/apps/{APP}/appInfos?limit=10")
    out = {}
    for info in infos.get("data", []):
        fields = ",".join(("locale",) + APPINFO_PRICED)
        got = call(f"/v1/appInfos/{info['id']}/appInfoLocalizations"
                   f"?limit=50&fields[appInfoLocalizations]={fields}")
        for l in got.get("data", []):
            out[l["attributes"]["locale"]] = l["attributes"]
    return out


def check_keywords(locs):
    """Live field vs the sanctioned writer. Returns a list of finding strings."""
    findings = []
    for locale, want in sorted(APPROVED.items()):
        got = (locs.get(locale, {}).get("keywords") or "").strip()
        if got == want:
            continue
        if locale not in locs:
            findings.append(f"keywords {locale}: locale missing from this version")
            continue
        a, b = set(want.split(",")), set(got.split(","))
        lost, gained = sorted(a - b), sorted(b - a)
        delta = []
        if lost:
            delta.append("approved but ABSENT: " + ",".join(lost))
        if gained:
            delta.append("live but UNAPPROVED: " + ",".join(gained))
        findings.append(f"keywords {locale}: " + " | ".join(delta or ["reordered"]))
    extra = sorted(set(locs) - set(APPROVED))
    if extra:
        findings.append("keywords: locales live but absent from asc-keywords.py: "
                        + ",".join(extra) + " (add them there or they drift unwatched)")
    return findings


def check_prices(locs, fields):
    """Any currency symbol in any displayed field, in any locale."""
    findings = []
    for locale, attrs in sorted(locs.items()):
        for field in fields:
            value = attrs.get(field) or ""
            hits = CURRENCY.findall(value)
            if not hits:
                continue
            excerpt = next((line.strip() for line in value.splitlines()
                            if CURRENCY.search(line)), value[:80])
            findings.append(f"price {locale}.{field}: {sorted(set(hits))} "
                            f"in {excerpt[:110]!r}")
    return findings


def main():
    only = None
    if "--version" in sys.argv:
        only = sys.argv[sys.argv.index("--version") + 1]
    scan_all = "--all" in sys.argv

    versions = call(f"/v1/apps/{APP}/appStoreVersions?limit=50"
                    "&fields[appStoreVersions]=versionString,appStoreState")
    rows = [(v["id"], v["attributes"]["versionString"], v["attributes"]["appStoreState"])
            for v in versions.get("data", [])]
    if only:
        rows = [r for r in rows if r[1] == only]
    elif not scan_all:
        rows = rows[:1] + [r for r in rows[1:] if r[2] in EDITABLE]
    if not rows:
        print("No versions matched.")
        return 1

    total = 0
    for vid, name, state in rows:
        locs = localizations(vid)
        if not locs:
            # An old version can answer with no localizations at all. That is
            # not 13 missing locales, it is one uninspectable version.
            findings = ["no localizations returned — nothing to check"]
        else:
            findings = check_keywords(locs) + check_prices(locs, VERSION_PRICED)
        mark = "FAIL" if findings else "ok"
        print(f"\n{name}  {state:<26} {len(locs)} locales  [{mark}]")
        for f in findings:
            print("   " + f)
        total += len(findings)

    # Name and subtitle are app-level: one check, not one per version.
    info = app_info_localizations()
    info_findings = check_prices(info, APPINFO_PRICED)
    print(f"\nname + subtitle  {len(info)} locales  "
          f"[{'FAIL' if info_findings else 'ok'}]")
    for f in info_findings:
        print("   " + f)
    total += len(info_findings)

    print(f"\n{'=' * 60}\n{total} finding(s) across {len(rows)} version(s).")
    if total:
        print("🔴 Do NOT auto-fix. asc-keywords.py is the only sanctioned writer,\n"
              "   and a disagreement may mean the SCRIPT is stale, not the listing.\n"
              "   Decide which is right, then make them agree in one commit.")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
