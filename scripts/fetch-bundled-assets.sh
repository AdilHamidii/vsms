#!/usr/bin/env bash
# Download service logos + country flags into the app bundle folders so the app
# renders them instantly/offline. Dev-time tool: run manually, commit the PNGs.
# Deps: curl + sips + python3 (all present on macOS). No pip/Homebrew needed.
# Usage: scripts/fetch-bundled-assets.sh [--refresh]   (--refresh re-downloads existing)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOGO_DIR="$REPO/VirtualSIM/BundledLogos"
FLAG_DIR="$REPO/VirtualSIM/BundledFlags"
mkdir -p "$LOGO_DIR" "$FLAG_DIR"
SB="https://enugzltysdmjzavisloy.supabase.co"
KEY="sb_publishable_IfwQ5IduTyVNawl7jiFA7A_aqJ-qqbk"
REFRESH="${1:-}"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok=0; miss=0

# minimum acceptable icon width (px) — rejects Google's generic globe fallback
MINW=24

save_png_if_valid() { # $1 src file, $2 dest .png -> 0 if a valid image >=MINW written
  local src="$1" dest="$2" w
  w="$(sips -g pixelWidth "$src" 2>/dev/null | awk '/pixelWidth/{print $2}')" || return 1
  [ -n "$w" ] && [ "$w" -ge "$MINW" ] || return 1
  sips -s format png "$src" --out "$dest" >/dev/null 2>&1 || return 1
}

echo "== logos =="
domains="$(curl -sf "$SB/rest/v1/services?select=domain&domain=not.is.null" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  | python3 -c "import sys,json;print(chr(10).join(sorted({r['domain'] for r in json.load(sys.stdin) if r.get('domain')})))")"
while IFS= read -r d; do
  [ -z "$d" ] && continue
  out="$LOGO_DIR/$d.png"
  [ -f "$out" ] && [ "$REFRESH" != "--refresh" ] && { ok=$((ok+1)); continue; }
  # primary: Google FaviconV2 (clean 128px PNG)
  curl -sf -o "$TMP/f" "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https%3A%2F%2F$d&size=128" || true
  if save_png_if_valid "$TMP/f" "$out"; then ok=$((ok+1)); continue; fi
  # fallback: DuckDuckGo ip3 (.ico -> png via sips)
  curl -sf -o "$TMP/d" "https://icons.duckduckgo.com/ip3/$d.ico" || true
  if save_png_if_valid "$TMP/d" "$out"; then ok=$((ok+1)); continue; fi
  echo "  MISS logo: $d"; miss=$((miss+1))
done <<< "$domains"

echo "== flags =="
codes="$(curl -sf "$SB/rest/v1/countries?select=id" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  | python3 -c "import sys,json;print(chr(10).join(sorted({('gb' if r['id']=='uk' else r['id']) for r in json.load(sys.stdin) if r.get('id')})))")"
while IFS= read -r c; do
  [ -z "$c" ] && continue
  out="$FLAG_DIR/$c.png"
  [ -f "$out" ] && [ "$REFRESH" != "--refresh" ] && { ok=$((ok+1)); continue; }
  curl -sf -o "$TMP/g" "https://flagcdn.com/w160/$c.png" || true
  if save_png_if_valid "$TMP/g" "$out"; then ok=$((ok+1)); else echo "  MISS flag: $c"; miss=$((miss+1)); fi
done <<< "$codes"

echo "done: $ok ok, $miss missing"
echo "logos: $(ls -1 "$LOGO_DIR" | wc -l | tr -d ' ')  flags: $(ls -1 "$FLAG_DIR" | wc -l | tr -d ' ')"
