#!/usr/bin/env python3
"""Add translated keys to Localizable.xcstrings in the committed JSON dialect.

Usage: python3 scripts/xcstrings-add.py entries.json [--catalog PATH]

entries.json: {"English key": {"de": "...", "es": "...", "fr": "...",
                               "it": "...", "ja": "...", "pt-BR": "..."}}

Refuses the whole batch (exit 1, catalog untouched) when any entry is missing
a locale or a translation's format specifiers differ from the key's. The
catalog is re-emitted exactly as committed: json.dumps(indent=2,
ensure_ascii=False, sort_keys=True) plus a trailing newline — never Xcode's
dialect, which would rewrite ~44,000 lines.
"""
import json
import re
import sys
from collections import Counter

LOCALES = ["de", "es", "fr", "it", "ja", "pt-BR"]
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)")


def specifiers(s: str) -> Counter:
    # Positional (%1$@) and plain (%@) forms are equivalent.
    return Counter(re.sub(r"\d+\$", "", m) for m in SPEC.findall(s))


def main() -> int:
    args = sys.argv[1:]
    catalog_path = "VirtualSIM/Localizable.xcstrings"
    if "--catalog" in args:
        i = args.index("--catalog")
        catalog_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__)
        return 1
    entries = json.load(open(args[0], encoding="utf-8"))
    errors = []
    for key, tr in entries.items():
        missing = [l for l in LOCALES if not tr.get(l)]
        if missing:
            errors.append(f"{key!r}: missing {missing}")
        for l in LOCALES:
            if tr.get(l) and specifiers(tr[l]) != specifiers(key):
                errors.append(f"{key!r} [{l}]: specifiers {dict(specifiers(tr[l]))} != {dict(specifiers(key))}")
    if errors:
        print("\n".join(errors))
        return 1

    catalog = json.load(open(catalog_path, encoding="utf-8"))
    strings = catalog["strings"]
    for key, tr in entries.items():
        entry = strings.setdefault(key, {})
        locs = entry.setdefault("localizations", {})
        for l in LOCALES:
            locs[l] = {"stringUnit": {"state": "translated", "value": tr[l]}}
    with open(catalog_path, "w", encoding="utf-8") as f:
        f.write(json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"added/updated {len(entries)} keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
