#!/usr/bin/env python3
import sys, json
sys.path.insert(0, ".claude/tmp")
from ascq import get

d = get("/v1/apps/6774768570/appAvailabilityV2?include=territoryAvailabilities&limit[territoryAvailabilities]=50")
if "__error" in d:
    print(d); sys.exit(1)
aid = d["data"]["id"]
print("availableInNewTerritories:", d["data"]["attributes"])
rows, nxt = [], f"/v1/appAvailabilities/{aid}/territoryAvailabilities?limit=50"
while nxt:
    r = get(nxt)
    if "__error" in r:
        print(r); break
    rows += r["data"]
    link = r.get("links", {}).get("next")
    nxt = link.split("appstoreconnect.apple.com")[1] if link else None
print("territories rows:", len(rows))
avail = [t for t in rows if t["attributes"].get("available")]
print("available:", len(avail))
for t in rows:
    if t["id"].upper().startswith("CHN") or "CHN" in t["id"].upper():
        print("CHINA:", t["id"], t["attributes"])
