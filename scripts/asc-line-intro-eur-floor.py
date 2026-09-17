#!/usr/bin/env python3
"""Raise line.monthly's $3.99 first-month intro to the EURO value in every
territory that carries the bare numeral 3.99 in a currency worth less than a
euro (owner decision 2026-09-17).

Why: the 2026-09-10 offer (`asc-line-monthly-intro-offer.py`) used the SAME
NUMERAL in every currency that had a 3.99 tier. A Canadian then paid CA$3.99 —
about US$2.45 after Apple's 15% — against a Telnyx number that costs $2.00 at
order, leaving ~$0.45 for the month. The owner's reference is the euro offer.

How: the target in each territory is APPLE'S EQUALIZATION of the €3.99 price
point in the base territory (FRA) — Apple's own FX and tax adjustment, not a
rate we pick. Only territories whose current offer is exactly "3.99" AND whose
equalized price is higher are touched; EUR territories are the reference and
USA is deliberately left alone ($3.99 is the owner's stated floor there).
Territories already on an equalized price (₹399, R$24.9, …) are not
same-numeral and are not touched.

Offer prices cannot be PATCHed on this API, so each change is DELETE then POST.
Apple honours offers already granted to a subscriber. Dry-run by default;
--apply writes. Every write is READ BACK — an accepted call is not evidence.
"""
import importlib.util
import json
import os
import sys
import time

_spec = importlib.util.spec_from_file_location(
    "intro", os.path.join(os.path.dirname(__file__), "asc-line-monthly-intro-offer.py"))
# The sibling script calls main() at import; load its helpers without running it.
_src = open(_spec.origin).read().rsplit("\nmain()", 1)[0]
intro = type(sys)("intro")
exec(compile(_src, _spec.origin, "exec"), intro.__dict__)

paged, SUB = intro.paged, intro.SUB


def call(method, path, body=None):
    """The sibling's `call`, except a DELETE answers 204 with an EMPTY body —
    json.load on that raised after the offer was already gone, stranding the
    territory with no offer at all (Albania, 2026-09-17, recovered below)."""
    import urllib.error
    import urllib.request
    req = urllib.request.Request(
        intro.BASE + path, data=json.dumps(body).encode() if body is not None else None,
        method=method, headers={"Authorization": f"Bearer {intro._token()}",
                                "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else {}
        except ValueError:
            return e.code, {"raw": raw[:200].decode(errors="replace")}
APPLY = "--apply" in sys.argv
BASE_TERRITORY = "FRA"
NUMERAL = "3.99"
SKIP = {"USA"}


def offers():
    """territory -> (offer id, price point id, customerPrice)."""
    rows, inc = paged(f"/v1/subscriptions/{SUB}/introductoryOffers"
                      "?limit=200&include=territory,subscriptionPricePoint")
    prices = {i["id"]: (i.get("attributes") or {}).get("customerPrice")
              for i in inc if i["type"] == "subscriptionPricePoints"}
    out = {}
    for o in rows:
        rel = o.get("relationships") or {}
        t = ((rel.get("territory") or {}).get("data") or {}).get("id")
        p = ((rel.get("subscriptionPricePoint") or {}).get("data") or {}).get("id")
        if t:
            out[t] = (o["id"], p, prices.get(p))
    return out


def currencies():
    rows, _ = paged("/v1/territories?limit=200")
    return {t["id"]: (t.get("attributes") or {}).get("currency") for t in rows}


def main():
    have = offers()
    cur = currencies()
    if BASE_TERRITORY not in have or have[BASE_TERRITORY][2] != NUMERAL:
        print(f"FAILED: base {BASE_TERRITORY} offer is {have.get(BASE_TERRITORY)}"); sys.exit(1)
    base_point = have[BASE_TERRITORY][1]
    print(f"offers: {len(have)} territories; base {BASE_TERRITORY} €{NUMERAL} point {base_point}")

    eq = {}
    rows, _ = paged(f"/v1/subscriptionPricePoints/{base_point}/equalizations"
                    "?include=territory&limit=200")
    for p in rows:
        t = ((p.get("relationships") or {}).get("territory") or {}).get("data", {}).get("id")
        if t:
            eq[t] = (p["id"], (p.get("attributes") or {}).get("customerPrice"))

    # A territory the subscription is sold in but that holds NO offer can only
    # be one an interrupted run deleted — restore it at the euro value.
    avail, _ = paged(f"/v1/subscriptionAvailabilities/{SUB}/availableTerritories?limit=200")
    plan = {}
    for t in sorted(a["id"] for a in avail):
        if t not in have and t in eq and cur.get(t) != "EUR":
            plan[t] = (None, eq[t][0], "none", eq[t][1])
    for t, (oid, _, price) in sorted(have.items()):
        if t in SKIP or cur.get(t) == "EUR" or price != NUMERAL or t not in eq:
            continue
        target_point, target_price = eq[t]
        if float(target_price) > float(price):
            plan[t] = (oid, target_point, price, target_price)

    same = sorted(t for t, v in have.items() if v[2] == NUMERAL)
    print(f"territories at bare {NUMERAL}: {len(same)}")
    print(f"to raise: {len(plan)}")
    for t, (_, _, old, new) in plan.items():
        print(f"  {t} {cur.get(t)}: {old} -> {new}")
    kept = [f"{t}({cur.get(t)} eq {eq.get(t, (0, '?'))[1]})" for t in same
            if t not in plan and cur.get(t) != "EUR"]
    print("same-numeral, not raised:", ", ".join(kept) or "none")

    if not APPLY:
        print("[dry] pass --apply to write"); return

    ok, fail = 0, []
    for t, (oid, pt, _, _) in plan.items():
        if oid:
            code, r = call("DELETE", f"/v1/subscriptionIntroductoryOffers/{oid}")
            if code >= 300:
                fail.append((t, "delete", code, json.dumps(r)[:200])); continue
        code, r = call("POST", "/v1/subscriptionIntroductoryOffers", {"data": {
            "type": "subscriptionIntroductoryOffers",
            "attributes": {"duration": "ONE_MONTH", "offerMode": "PAY_AS_YOU_GO",
                           "numberOfPeriods": 1},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": SUB}},
                "territory": {"data": {"type": "territories", "id": t}},
                "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": pt}},
            }}})
        if code < 300:
            ok += 1
        else:
            fail.append((t, "create", code, json.dumps(r)[:200]))
        time.sleep(0.15)
    print(f"raised {ok}, failed {len(fail)}")
    for f in fail:
        print("  FAIL", f)

    back = offers()
    bad = {t: back.get(t) for t, v in plan.items() if (back.get(t) or (0, 0, None))[2] != v[3]}
    print(f"read-back: {len(back)} of {len(avail)} territories hold an offer; "
          f"mismatches: {len(bad)} {list(bad.items())[:5]}")
    for t in ("USA", BASE_TERRITORY, "CAN", "AUS", "GBR"):
        print(f"  {t} now {(back.get(t) or (0, 0, None))[2]}")


main()
