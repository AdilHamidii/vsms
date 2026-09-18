#!/usr/bin/env python3
"""Apple's own App Store funnel for vSMS: impressions -> page views -> downloads.

    python3 scripts/asc-analytics.py daily            # one row per day, whole funnel
    python3 scripts/asc-analytics.py territory        # impressions per territory, two windows
    python3 scripts/asc-analytics.py versions         # first-time downloads per app version per day

This is the ONLY source in the repo that can tell a DISCOVERY problem from a
PRODUCT one. `profiles` counts people who installed AND signed in, so a fall in
signups is ambiguous on its own; these reports split it into how many people
Apple showed the app to, how many opened the page, and how many installed.

🔴 It reads an ONGOING analyticsReportRequest that already exists
(`GET /v1/apps/<app>/analyticsReportRequests`). Apple only serves data from the
request's creation date forward — today that is 2026-08-14 — so there is no way
to look further back, and DELETING that request would destroy the history.
Never delete it; if it is ever missing, create a new ONGOING one and accept
that the series restarts.

Instances land about a day late: the instance with processingDate D carries the
data for D-1, so the newest complete day is always yesterday.

Segments are gzipped TSV and are cached under the job tmp dir; delete the cache
directory to re-fetch.
"""
import collections, csv, glob, gzip, json, os, sys, time, urllib.request
import jwt

KEY = "/Users/adyl/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8"
KID, ISS, APP = "R5ZVLBTUR6", "4644ed13-4d98-489e-a94b-687f63946f46", "6774768570"
CACHE = os.path.expanduser("~/.cache/vsms-asc-analytics")

# The two reports this needs. Names are Apple's and are stable.
REPORTS = {"discovery": "App Store Discovery and Engagement Standard",
           "downloads": "App Downloads Standard"}

tok = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1000,
                  "aud": "appstoreconnect-v1"}, open(KEY).read(), algorithm="ES256",
                 headers={"kid": KID})
H = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}


def call(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, headers=H)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code >= 500 and attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            print(f"HTTP {e.code} GET {path}\n{e.read().decode()[:600]}")
            raise


def sync():
    """Download every DAILY instance we do not already hold. Returns the cache dir."""
    os.makedirs(CACHE, exist_ok=True)
    reqs = call(f"/v1/apps/{APP}/analyticsReportRequests?limit=50")["data"]
    ongoing = [r for r in reqs if r["attributes"].get("accessType") == "ONGOING"]
    if not ongoing:
        sys.exit("no ONGOING analyticsReportRequest on this app — history would restart; "
                 "create one in ASC before relying on this script")
    rid = ongoing[0]["id"]
    names = {d["attributes"].get("name"): d["id"]
             for d in call(f"/v1/analyticsReportRequests/{rid}/reports?limit=200")["data"]}
    for label, name in REPORTS.items():
        rep = names.get(name)
        if not rep:
            sys.exit(f"Apple no longer offers a report named {name!r}")
        insts = call(f"/v1/analyticsReports/{rep}/instances?limit=200&filter[granularity]=DAILY")
        for inst in sorted(insts["data"], key=lambda d: d["attributes"]["processingDate"]):
            path = f"{CACHE}/{label}-{inst['attributes']['processingDate']}.tsv"
            if os.path.exists(path):
                continue
            segs = call(f"/v1/analyticsReportInstances/{inst['id']}/segments")
            out = []
            for s in segs.get("data", []):
                raw = urllib.request.urlopen(s["attributes"]["url"], timeout=120).read()
                try:
                    out.append(gzip.decompress(raw).decode())
                except OSError:          # Apple sometimes serves it uncompressed
                    out.append(raw.decode())
            open(path, "w").write("\n".join(out))
    return CACHE


def rows(label):
    """Every data row of one report, each data date counted EXACTLY ONCE.

    🔴 An instance does NOT hold one day. The instance with processingDate D
    carries a ROLLING THREE-DAY WINDOW, D-1 through D-3, and Apple restates as
    it goes. So a naive sum over the files counts a middle day three times and
    the newest day once, which manufactures a ~3x cliff out of nothing — that
    read the 09-12 keyword drop as 6,200 -> 1,244 impressions/day when the
    truth was 2,090 -> 1,270. The direction survived; the magnitude did not.

    For each data date we therefore keep the copy from the NEWEST processing
    date that contains it, which is also the most restated. A consequence worth
    knowing: the two most recent data dates have been through fewer restatements
    and read LOW until two more instances land. Never call the last row a trend.
    """
    best = {}                                   # data date -> (processingDate, rows)
    for p in sorted(glob.glob(f"{CACHE}/{label}-*.tsv")):
        proc = os.path.basename(p)[len(label) + 1:].replace(".tsv", "")
        per = collections.defaultdict(list)
        with open(p) as f:
            for row in csv.DictReader(f, delimiter="\t"):
                if row.get("Date") and row["Date"] != "Date":
                    per[row["Date"]].append(row)
        for date, rs in per.items():
            if date not in best or proc > best[date][0]:
                best[date] = (proc, rs)
    for date in sorted(best):
        yield from best[date][1]


def is_search(row):
    return "search" in (row.get("Source Type") or "").lower()


def cmd_daily():
    d = collections.defaultdict(collections.Counter)
    for r in rows("discovery"):
        key = ("impr" if r["Event"] == "Impression" else
               "pv" if r["Event"] == "Page view" else None)
        if key:
            d[r["Date"]][key + ("_search" if is_search(r) else "_other")] += int(r["Counts"] or 0)
    for r in rows("downloads"):
        if r["Download Type"] == "First-time download":
            d[r["Date"]]["new"] += int(r["Counts"] or 0)

    print(f"{'date':12}{'impr_search':>12}{'impr_other':>11}{'page_views':>11}"
          f"{'new_installs':>13}{'pv/impr':>9}{'inst/pv':>9}")
    days = sorted(d)
    for day in days:
        c = d[day]
        impr, pv = c["impr_search"] + c["impr_other"], c["pv_search"] + c["pv_other"]
        flag = "  PROVISIONAL" if day in days[-2:] else ""
        print(f"{day:12}{c['impr_search']:>12}{c['impr_other']:>11}{pv:>11}{c['new']:>13}"
              f"{(pv / impr * 100 if impr else 0):>8.1f}%"
              f"{(c['new'] / pv * 100 if pv else 0):>8.0f}%{flag}")
    print("\nPROVISIONAL = still inside Apple's 3-day restatement window; these "
          "read LOW and are not a trend.")


def window(counter, a, b):
    days = [v for k, v in counter.items() if a <= k <= b]
    return sum(days) / max(len(days), 1)


def cmd_territory():
    """Search impressions per territory, before a pivot date against after it.

        python3 scripts/asc-analytics.py territory 2026-09-13

    🔴 PASS THE PIVOT. It is the day the thing you are testing went live, and
    a window that straddles that day mixes the two regimes and reports
    nonsense — an auto-chosen window once put France at +2702% by averaging
    a pre-change spike into the "after" side. Default is the 5th-from-last
    settled day, which tests nothing in particular.
    """
    terr = collections.defaultdict(collections.Counter)
    for r in rows("discovery"):
        if r["Event"] == "Impression" and is_search(r):
            terr[r["Territory"]][r["Date"]] += int(r["Counts"] or 0)
    days = sorted({d for c in terr.values() for d in c})[:-2]   # drop provisional days
    if len(days) < 12:
        sys.exit("not enough settled history for a comparison")
    pivot = sys.argv[2] if len(sys.argv) > 2 else days[-5]
    base = [d for d in days if d < pivot][-8:]
    now = [d for d in days if d >= pivot]
    if not base or not now:
        sys.exit(f"pivot {pivot} leaves one side empty (settled range "
                 f"{days[0]}..{days[-1]})")
    print(f"compare {base[0]}..{base[-1]}  ->  {now[0]}..{now[-1]}  (impressions/day)\n")
    print(f"{'terr':6}{'before':>9}{'after':>9}{'change':>9}   note")
    ranked = sorted(terr, key=lambda t: -window(terr[t], base[0], base[-1]))
    for t in ranked[:15]:
        b, n = window(terr[t], base[0], base[-1]), window(terr[t], now[0], now[-1])
        # A "before" made almost entirely of one or two days is a SPIKE, and
        # comparing against it reports a collapse in a territory that never had
        # steady traffic. This caught a reader out once: seven European
        # storefronts read -100% off a two-day burst against a ~28/day norm.
        vals = sorted((terr[t].get(d, 0) for d in base), reverse=True)
        tot = sum(vals)
        note = ""
        if tot and (vals[0] / tot > 0.6 or sum(vals[:2]) / tot > 0.8):
            note = ("   ⚠️ SPIKY baseline — one or two days carry most of it, "
                    "change is meaningless")
        elif tot / len(base) < 20:
            note = "   (tiny volume)"
        print(f"{t:6}{b:>9.0f}{n:>9.0f}{((n - b) / b * 100 if b else 0):>8.0f}%{note}")
    tb = sum(window(terr[t], base[0], base[-1]) for t in terr)
    tn = sum(window(terr[t], now[0], now[-1]) for t in terr)
    print(f"{'ALL':6}{tb:>9.0f}{tn:>9.0f}{((tn - tb) / tb * 100 if tb else 0):>8.0f}%")
    print("\nRead the US row first — it is ~90% of all impressions. A small "
          "territory's percentage is noise unless its volume is real.")


def cmd_versions():
    """When each version actually reached users — the only honest 'went live' date."""
    by = collections.defaultdict(collections.Counter)
    for r in rows("downloads"):
        if r["Download Type"] == "First-time download":
            by[r["Date"]][r["App Version"]] += int(r["Counts"] or 0)
    vers = sorted({v for c in by.values() for v in c},
                  key=lambda v: [int(x) for x in v.split(".") if x.isdigit()])[-6:]
    print(f"{'date':12}" + "".join(f"{v:>9}" for v in vers))
    for day in sorted(by):
        print(f"{day:12}" + "".join(f"{by[day][v]:>9}" for v in vers))


if __name__ == "__main__":
    sync()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "daily"
    {"daily": cmd_daily, "territory": cmd_territory, "versions": cmd_versions}.get(
        cmd, lambda: sys.exit(__doc__))()
