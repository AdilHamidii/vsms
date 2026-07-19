# Bundle service logos + country flags — design

**Date:** 2026-07-19
**Status:** Approved (design), pending implementation plan

## Goal

Ship service brand logos and country flags **inside the app bundle** so the
common case renders instantly with **no per-user server fetch**, while still
degrading gracefully for catalog entries added server-side after a build ships.

Today:
- `ServiceLogo` loads logos at runtime via a network cascade keyed on
  `service.domain`: DuckDuckGo ip3 → Google FaviconV2 → SF-Symbol/glyph.
- `FlagImage` / `FlagCircle` load flags from `flagcdn.com/w160` keyed on
  `country.flagImageCode` (ISO alpha-2 lowercase, `uk`→`gb`) → emoji fallback.

Catalog size (live DB, 2026-07-19): **268 services** (251 distinct logo
domains), **69 countries** (69 flags). Estimated bundle add: **2–6 MB**.

## Decisions (approved)

1. **Bundle-first, network fallback.** Bundled image is source #1; if a
   service/flag isn't bundled (added to the catalog after this build), fall
   through to the existing network cascade, then the SF-Symbol/emoji. The live
   catalog is dynamic (`sync-smspool`/`sync-prices` add rows over time), so the
   network path must remain as a fallback — it just stops being the default.
2. **Flat folder references**, not an asset catalog. Filenames are the lookup
   key directly (dots/slashes are legal in filenames), and regeneration is a
   plain file drop with clean git diffs.

## Architecture

### 1. Storage
Two **blue folder references** added to the `VirtualSIM` target:
- `VirtualSIM/BundledLogos/<domain>.png`  (e.g. `whatsapp.com.png`)
- `VirtualSIM/BundledFlags/<code>.png`    (e.g. `gb.png`)

Folder references include whatever is in the folder at build time, so the
generation script never edits `project.pbxproj`. At runtime the files are
reachable via `Bundle.main.url(forResource:withExtension:subdirectory:)`.
Image sizes: logos ~128px (FaviconV2 native — no upscaling; ample for a 40pt
logo at 3×), flags ~160px, PNG. Committed to the repo.

### 2. Generation script — `scripts/fetch-bundled-assets.sh`
Pure `curl` + `sips` (both built into macOS; no pip/Homebrew deps). Steps:
1. Fetch `services.domain` (distinct, non-null) and `countries` flag codes from
   PostgREST using the publishable key.
2. For each domain, download a logo — **primary Google FaviconV2** (returns a
   clean 128px PNG), **fallback DuckDuckGo ip3** (`sips`-convert ICO→PNG if
   needed). For each country, download `flagcdn.com/w160/<code>.png`.
3. Normalize to PNG, write `BundledLogos/<domain>.png` / `BundledFlags/<code>.png`.
4. Idempotent: existing files are kept unless a `--refresh` flag is passed.
   Print a summary of successes and misses.

The script is a **dev-time tool**, run manually. It does not run at app build or
runtime.

### 3. Loading layer — `BundledImageStore`
A single `@Observable` (or plain singleton) injected via the environment, built
once at launch:
- On init, list both folders into `Set<String>` of filenames for **O(1)
  membership** (so list rows never touch disk to decide bundled-vs-network).
- `image(forLogoDomain:) -> UIImage?` and `image(forFlagCode:) -> UIImage?`
  decode lazily and cache in an `NSCache<NSString, UIImage>`.

`ServiceLogo`:
- If `has(logo: domain)` → render the bundled `UIImage` with the **same** tinted
  rounded-square + white-inset treatment used today.
- Else → existing `AsyncImage` cascade (unchanged), then SF-Symbol/glyph.

`FlagImage` / `FlagCircle`:
- If `has(flag: code)` → render bundled `UIImage`, same rounded-square / circle clip.
- Else → `AsyncImage(flagcdn)` → emoji.

Rendering output is byte-for-byte the same shape/treatment; only the pixel
source changes. No screenshots change.

## Data flow

```
launch → BundledImageStore lists BundledLogos/ + BundledFlags/ into Sets
render row → ServiceLogo/FlagImage ask store.has(key)
   ├─ yes → store.image(key) (NSCache) → draw
   └─ no  → existing AsyncImage network cascade → draw / fallback
```

## Error handling / edge cases
- **Logo download fails or is low-res** during generation → not written → runtime
  network fallback covers it (same as today, just not accelerated).
- **Domain casing / `uk`→`gb`**: the store keys must match how the models emit
  them (`service.domain` verbatim; `country.flagImageCode`). Generation writes
  files using those exact keys.
- **Corrupt/missing bundled file at runtime** (e.g. decode returns nil) → treat
  as a miss → fall through to network.
- **New catalog rows** between releases → not bundled → network fallback.

## Refresh workflow
Documented in the script header and a line in `CLAUDE.md`: after the catalog
grows, run `scripts/fetch-bundled-assets.sh --refresh`, commit the new PNGs,
ship an app update. No runtime code change needed as the catalog grows.

## Testing / verification
- Run the script → confirm `BundledLogos/` (~251) and `BundledFlags/` (69)
  populate; review the miss list.
- `xcodebuild build` clean.
- Run on simulator with **network disabled**: known services/flags still render
  from the bundle; an artificially-unknown domain falls back to SF-Symbol.
- Scroll the 268-row ServiceSheet → smooth (membership is O(1), decode cached).
- Light + dark spot check (logos on white, flags unchanged).

## Non-goals
- No dark-mode logo/flag variants.
- No app-thinning/asset-catalog variants (all PNGs ship to all devices; the set
  is tiny).
- No automated CI regeneration; refresh is a manual dev step.
- No change to the network cascade order or the models' URL helpers (kept as the
  fallback path).
