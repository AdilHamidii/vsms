#!/usr/bin/env python3
"""Ratings COUNT per storefront — the only read-out the review prompt has.

🔴 **ASC's `customerReviews` endpoint returns only WRITTEN reviews.** A user
who taps a star in the native prompt and writes nothing leaves a RATING, which
is invisible there — and the rating COUNT is the thing that actually caps App
Store search position. This endpoint is the only way to see those, and it needs
no auth at all.

🔴 **APPLE GIVES NO ATTRIBUTION FOR A RATING.** There is no callback from
`requestReview()`, nothing in ASC ties a star to a session, and a rating can
land days after the prompt. So this series is an INTERRUPTED TIME SERIES and
nothing more: run it regularly, ship a change, and read the slope before
against the slope after. **It is only a read-out if the series starts BEFORE
the change ships** — which is why this script exists as a committed artifact
rather than a one-off.

BASELINE, 2026-09-11 (the day the derived review prompt was written, and before
any build carrying it shipped — live build was 2.11):

    us 1 · fr 3 · de 1 · es 1 · pl 2 · everywhere else 0   →   TOTAL 8

Seven of those eight are the written reviews ASC lists, and the owner states
six of those seven are people they know. So exactly ONE rating in the app's
whole history is plausibly organic-and-silent, and the DEU 1★ is the only
organic written one. **Do not quote a prompt→rating rate from anything before
this date; none has ever been measured.**

Usage:
    python3 scripts/app-ratings.py              # table + total
    python3 scripts/app-ratings.py --csv        # one CSV row, for appending
"""
from __future__ import annotations   # this Mac's python3 predates `X | None` at runtime

import json
import sys
import time
import urllib.error
import urllib.request

APP = "6774768570"

# Storefronts worth watching: every locale the listing is localized for, plus
# the markets that actually produce installs. A storefront the app is not
# available in answers with an empty `results` and is reported as such — that
# is a real state (China is deliberately removed; see CLAUDE.md), not an error.
COUNTRIES = ["us", "gb", "ca", "au", "fr", "de", "es", "it", "pl", "br",
             "mx", "nl", "se", "ru", "jp", "sa", "ng", "in", "tr"]

CSV = "--csv" in sys.argv


def lookup(country: str) -> dict | None:
    url = f"https://itunes.apple.com/lookup?id={APP}&country={country}"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        print(f"  {country}: HTTP {e.code}", file=sys.stderr)
        return None
    except urllib.error.URLError as e:
        print(f"  {country}: {e.reason}", file=sys.stderr)
        return None
    results = data.get("results") or []
    return results[0] if results else None


def main():
    counts: dict[str, int] = {}
    rows = []
    for country in COUNTRIES:
        app = lookup(country)
        # Apple rate-limits this endpoint; it is generous, but 19 storefronts
        # back to back is enough to meet it on a bad day.
        time.sleep(0.2)
        if app is None:
            rows.append((country, None, None, None))
            continue
        n = app.get("userRatingCount", 0)
        counts[country] = n
        rows.append((country, n, app.get("averageUserRating", 0.0),
                     app.get("version")))

    stamp = time.strftime("%Y-%m-%d")
    if CSV:
        # date,total,us,gb,ca,... — append to a file to build the series.
        cells = ",".join(str(counts.get(c, "")) for c in COUNTRIES)
        print(f"{stamp},{sum(counts.values())},{cells}")
        return

    print(f"vSMS ratings by storefront — {stamp}\n")
    for country, n, avg, version in rows:
        if n is None:
            print(f"  {country:<3} not available in this storefront")
            continue
        print(f"  {country:<3} ratings={n:<5} avg={avg:<5.2f}  (live v{version})")
    print(f"\n  {'TOTAL':<3} {sum(counts.values())}")
    print("\n⚠️ A rating here cannot be attributed to a prompt. Read the SLOPE "
          "across runs,\n   never a single total. Baseline 2026-09-11 = 8.")


if __name__ == "__main__":
    main()
