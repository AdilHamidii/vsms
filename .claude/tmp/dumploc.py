#!/usr/bin/env python3
import json, sys
sys.path.insert(0, ".claude/tmp")
from ascq import get

VID = "61c4b4d0-a49d-4842-a3cd-459ca0d17d88"
d = get(f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations?limit=20")
json.dump(d, open(".claude/tmp/loc210.json", "w"), indent=1)
mode = sys.argv[1] if len(sys.argv) > 1 else "short"
for l in d["data"]:
    a = l["attributes"]
    print("=" * 70)
    print(a["locale"], "id=", l["id"])
    print("KEYWORDS:", a["keywords"], "(len %d)" % len(a["keywords"] or ""))
    print("PROMO:", repr(a["promotionalText"]))
    print("WHATSNEW:", repr(a["whatsNew"]))
    if mode == "full":
        print("DESCRIPTION:\n" + (a["description"] or ""))
