#!/usr/bin/env python3
"""Audit Localizable.xcstrings for the two defects that ship as crashes or
English fallbacks, per the release-prep rule.

1. SPECIFIER SAFETY per translation: the conversion specifiers (%lld, %@, %d,
   %1$@ …) must be the same MULTISET as the source key AND in the same ORDER,
   unless the translation uses positional `%n$` markers. A reorder without
   positions reads the wrong argument — the Japanese `%lld%% of %@ codes`
   crash (1.7). Omitting a LATER argument is tolerated (documented-safe).
2. UNTRANSLATED keys: source strings with no value (or a "new"/"needs_review"
   state) in any of the target locales. Reported per locale so a release can
   decide what ships English.

Usage: python3 scripts/audit-xcstrings.py [path] [--locales de,es,fr,it,ja,pt-BR]
Exit code 1 on any specifier violation; untranslated keys are reported only.
"""
import json, re, sys

path = next((a for a in sys.argv[1:] if not a.startswith("--")), "VirtualSIM/Localizable.xcstrings")
loc_arg = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--locales=")), "de,es,fr,it,ja,pt-BR")
LOCALES = loc_arg.split(",")

SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|L)?([@dDuUxXoOfeEgGcCsSpaAF])|(%%)")


def specs(s):
    """[(position or None, conversion)] in order of appearance, %% skipped."""
    out = []
    for m in SPEC.finditer(s or ""):
        if m.group(3):
            continue
        out.append((int(m.group(1)) if m.group(1) else None, m.group(2)))
    return out


cat = json.load(open(path))
strings = cat["strings"]
viol, untranslated = [], {l: [] for l in LOCALES}

for key, entry in strings.items():
    src = specs(key)
    locs = entry.get("localizations", {})
    for l in LOCALES:
        su = locs.get(l, {}).get("stringUnit")
        if not su or not su.get("value") or su.get("state") in ("new", "needs_review"):
            if src or len(key) > 0:
                untranslated[l].append(key)
            continue
        tr = specs(su["value"])
        if not src and not tr:
            continue
        src_conv = [c for _, c in src]
        tr_conv = [c for _, c in tr]
        positional = all(p is not None for p, _ in tr) and tr
        if positional:
            # positions must reference valid source args with matching conversions
            bad = [(p, c) for p, c in tr if p < 1 or p > len(src) or src_conv[p - 1] != c]
            if bad:
                viol.append((l, key, su["value"], f"positional mismatch {bad}"))
            continue
        # non-positional: must be a prefix-compatible same-order sequence
        # (omitting later args is allowed; reordering or changing a conv is not)
        if tr_conv != src_conv[:len(tr_conv)]:
            viol.append((l, key, su["value"], f"order/conversion differs: src {src_conv} tr {tr_conv}"))

for l, key, val, why in viol:
    print(f"VIOLATION [{l}] {why}\n  key: {key}\n  val: {val}")
print(f"\nspecifier violations: {len(viol)}")
for l in LOCALES:
    u = untranslated[l]
    print(f"untranslated [{l}]: {len(u)}")
    for k in u[:40]:
        print(f"   - {k[:90]}")
    if len(u) > 40:
        print(f"   … and {len(u) - 40} more")
sys.exit(1 if viol else 0)
