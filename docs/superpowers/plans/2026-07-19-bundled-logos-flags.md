# Bundled Logos + Flags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship service logos + country flags inside the app bundle so they render instantly/offline, with the existing network cascade kept only as a fallback for catalog entries added after the build ships.

**Architecture:** Two flat folder references (`VirtualSIM/BundledLogos/`, `VirtualSIM/BundledFlags/`) hold one PNG per service `domain` / country flag code. A committed dev script downloads them. A `BundledImageStore.shared` singleton lists the folders once (O(1) membership) and caches decoded `UIImage`s; `ServiceLogo`/`FlagImage`/`FlagCircle` consult it first and fall through to today's `AsyncImage` cascade on a miss.

**Tech Stack:** SwiftUI, UIKit (`UIImage`), macOS `curl`+`sips` (script), Supabase PostgREST.

## Global Constraints

- **No test suite exists** (per `CLAUDE.md`). "Verify" = `xcodebuild` clean build + simulator runtime check + script output inspection. Do NOT add an XCTest target.
- iOS build verify command (from `CLAUDE.md`):
  `xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10`
- Work in the worktree: `/Users/adyl/Desktop/VirtualSIM/.claude/worktrees/init-claudemd-update` (branch `fixes-batch`).
- Logo lookup key = `Service.domain` **verbatim**. Flag lookup key = `Country.flagImageCode` (= `Country.id`, except `uk`→`gb`). Filenames MUST equal these keys.
- Supabase: URL `https://enugzltysdmjzavisloy.supabase.co`, publishable key `sb_publishable_IfwQ5IduTyVNawl7jiFA7A_aqJ-qqbk` (safe in-repo per `CLAUDE.md`).
- Rendering/visual treatment must not change — bundled images slot into the existing `ServiceLogo`/`FlagImage` shapes. No screenshots change.

---

### Task 1: Generation script + generated assets

**Files:**
- Create: `scripts/fetch-bundled-assets.sh`
- Create (output, committed): `VirtualSIM/BundledLogos/*.png`, `VirtualSIM/BundledFlags/*.png`

**Interfaces:**
- Produces: two populated folders whose filenames are `<service.domain>.png` and `<flagImageCode>.png`. Consumed at runtime by Task 3.

- [ ] **Step 1: Write the script**

Create `scripts/fetch-bundled-assets.sh`:

```bash
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
```

- [ ] **Step 2: Make executable and run**

Run:
```bash
chmod +x scripts/fetch-bundled-assets.sh
scripts/fetch-bundled-assets.sh
```
Expected: prints `done: N ok, M missing`, then counts. Logos ≈ 240–251, flags ≈ 69. A handful of logo MISSes is acceptable (they use the runtime fallback).

- [ ] **Step 3: Sanity-check output**

Run:
```bash
ls VirtualSIM/BundledLogos | head; echo "logos: $(ls VirtualSIM/BundledLogos | wc -l)"
ls VirtualSIM/BundledFlags | head; echo "flags: $(ls VirtualSIM/BundledFlags | wc -l)"
file VirtualSIM/BundledFlags/gb.png   # -> PNG image data
sips -g pixelWidth VirtualSIM/BundledFlags/gb.png
```
Expected: `.png` files present; `gb.png` exists (proves `uk`→`gb` mapping); files are real PNGs.

- [ ] **Step 4: Commit**

```bash
git add scripts/fetch-bundled-assets.sh VirtualSIM/BundledLogos VirtualSIM/BundledFlags
git commit -m "assets: generation script + bundled service logos & country flags"
```

---

### Task 2: Add folder references to the Xcode target

**Files:**
- Modify: `VirtualSIM.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `BundledLogos/` and `BundledFlags/` copied into the built `.app` bundle root, reachable via `Bundle.main.url(forResource:withExtension:subdirectory:)`.

- [ ] **Step 1: Locate the anchors**

Run:
```bash
cd /Users/adyl/Desktop/VirtualSIM/.claude/worktrees/init-claudemd-update
# a) the VirtualSIM PBXGroup children list (holds Assets.xcassets, etc.)
grep -n "Assets.xcassets in Resources\|/* Assets.xcassets */ = {isa = PBXFileReference" VirtualSIM.xcodeproj/project.pbxproj
# b) the Resources build phase
grep -n "PBXResourcesBuildPhase\|isa = PBXResourcesBuildPhase" VirtualSIM.xcodeproj/project.pbxproj
# confirm chosen UUIDs are unused:
grep -c "BND10AD5000000000000001\|BND10AD5000000000000002\|BND10AD5000000000000003\|BND10AD5000000000000004" VirtualSIM.xcodeproj/project.pbxproj  # expect 0
```

- [ ] **Step 2: Add two PBXFileReference entries**

In the `/* Begin PBXFileReference section */ ... /* End PBXFileReference section */` block, add:
```
		BND10AD5000000000000001 /* BundledLogos */ = {isa = PBXFileReference; lastKnownFileType = folder; path = BundledLogos; sourceTree = "<group>"; };
		BND10AD5000000000000002 /* BundledFlags */ = {isa = PBXFileReference; lastKnownFileType = folder; path = BundledFlags; sourceTree = "<group>"; };
```

- [ ] **Step 3: Add two PBXBuildFile entries**

In the `/* Begin PBXBuildFile section */ ... /* End */` block, add:
```
		BND10AD5000000000000003 /* BundledLogos in Resources */ = {isa = PBXBuildFile; fileRef = BND10AD5000000000000001 /* BundledLogos */; };
		BND10AD5000000000000004 /* BundledFlags in Resources */ = {isa = PBXBuildFile; fileRef = BND10AD5000000000000002 /* BundledFlags */; };
```

- [ ] **Step 4: Reference the folders in the VirtualSIM group + Resources phase**

In the VirtualSIM PBXGroup `children = ( ... );` (the group whose `path = VirtualSIM;`), add these two lines next to the `Assets.xcassets` child:
```
				BND10AD5000000000000001 /* BundledLogos */,
				BND10AD5000000000000002 /* BundledFlags */,
```
In the `PBXResourcesBuildPhase` `files = ( ... );`, add next to the `Assets.xcassets in Resources` line:
```
				BND10AD5000000000000003 /* BundledLogos in Resources */,
				BND10AD5000000000000004 /* BundledFlags in Resources */,
```

- [ ] **Step 5: Build and verify the folders ship in the bundle**

Run the Global-Constraints build command. Expected: `** BUILD SUCCEEDED **`.
Then confirm the resources are copied:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/VirtualSIM-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "VirtualSIM.app" | head -1)
ls "$APP/BundledFlags/gb.png" && ls "$APP/BundledLogos" | wc -l
```
Expected: `gb.png` exists in the built app; logo count matches Task 1.

- [ ] **Step 6: Commit**

```bash
git add VirtualSIM.xcodeproj/project.pbxproj
git commit -m "build: bundle BundledLogos/BundledFlags folder refs into the app target"
```

---

### Task 3: `BundledImageStore` lookup + cache

**Files:**
- Create: `VirtualSIM/Components/BundledImageStore.swift`

**Interfaces:**
- Produces:
  - `BundledImageStore.shared` (singleton)
  - `func logo(forDomain domain: String?) -> UIImage?`
  - `func flag(forCode code: String) -> UIImage?`
  Both return `nil` when there is no bundled asset (→ caller falls back to network).

- [ ] **Step 1: Write the store**

Create `VirtualSIM/Components/BundledImageStore.swift`:
```swift
import UIKit

/// Loads service logos + country flags shipped in the app bundle
/// (BundledLogos/<domain>.png, BundledFlags/<code>.png). Membership is listed
/// once at first use for O(1) checks; decoded images are cached. Returns nil
/// for anything not bundled so callers fall back to the network cascade.
final class BundledImageStore {
    static let shared = BundledImageStore()

    private let logoNames: Set<String>
    private let flagNames: Set<String>
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        logoNames = Self.list("BundledLogos")
        flagNames = Self.list("BundledFlags")
    }

    private static func list(_ sub: String) -> Set<String> {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(sub),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: url, includingPropertiesForKeys: nil) else { return [] }
        return Set(files.filter { $0.pathExtension == "png" }
                        .map { $0.deletingPathExtension().lastPathComponent })
    }

    func logo(forDomain domain: String?) -> UIImage? {
        guard let d = domain, !d.isEmpty, logoNames.contains(d) else { return nil }
        return image(sub: "BundledLogos", name: d)
    }

    func flag(forCode code: String) -> UIImage? {
        guard flagNames.contains(code) else { return nil }
        return image(sub: "BundledFlags", name: code)
    }

    private func image(sub: String, name: String) -> UIImage? {
        let key = "\(sub)/\(name)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: sub),
              let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
```

- [ ] **Step 2: Build**

Run the Global-Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VirtualSIM/Components/BundledImageStore.swift
git commit -m "feat: BundledImageStore — bundle-first logo/flag lookup with cache"
```

---

### Task 4: `ServiceLogo` bundle-first

**Files:**
- Modify: `VirtualSIM/Components/ServiceLogo.swift`

**Interfaces:**
- Consumes: `BundledImageStore.shared.logo(forDomain:)` (Task 3).

- [ ] **Step 1: Insert the bundled branch**

In `ServiceLogo.body`, replace the `let sources = service.logoURLs` / `if sourceIndex < sources.count { AsyncImage(...) } else { fallback }` block so a bundled image wins first. New body inner content:
```swift
            if let bundled = BundledImageStore.shared.logo(forDomain: service.domain) {
                Image(uiImage: bundled)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.16)
                    .background(.white, in: .rect(cornerRadius: radius))
                    .clipShape(.rect(cornerRadius: radius))
            } else {
                let sources = service.logoURLs
                if sourceIndex < sources.count {
                    AsyncImage(url: sources[sourceIndex], transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(size * 0.16)
                                .background(.white, in: .rect(cornerRadius: radius))
                                .clipShape(.rect(cornerRadius: radius))
                        case .empty:
                            Color.clear
                        case .failure:
                            Color.clear
                                .task { sourceIndex += 1 }
                        @unknown default:
                            Color.clear
                        }
                    }
                } else {
                    fallback
                }
            }
```

- [ ] **Step 2: Build**

Run the Global-Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Runtime verify (bundle-first + offline)**

Build+run on an iOS simulator (see `CLAUDE.md` / XcodeBuildMCP). Turn the Mac's network off (or use a bundled service). Open the Service picker. Expected: known-domain logos still render (from bundle); scrolling the 268-row list stays smooth.

- [ ] **Step 4: Commit**

```bash
git add VirtualSIM/Components/ServiceLogo.swift
git commit -m "feat: ServiceLogo renders bundled logo first, network as fallback"
```

---

### Task 5: `FlagImage` + `FlagCircle` bundle-first

**Files:**
- Modify: `VirtualSIM/Components/FlagImage.swift`

**Interfaces:**
- Consumes: `BundledImageStore.shared.flag(forCode:)` (Task 3).

- [ ] **Step 1: `FlagImage` bundled branch**

In `FlagImage.body`, wrap the existing `flagImageURL` branch so bundled wins first:
```swift
            if let bundled = BundledImageStore.shared.flag(forCode: country.flagImageCode) {
                Image(uiImage: bundled)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: radius))
            } else if let url = country.flagImageURL(width: 160) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(.rect(cornerRadius: radius))
                    case .empty, .failure:
                        emojiFallback
                    @unknown default:
                        emojiFallback
                    }
                }
            } else {
                emojiFallback
            }
```

- [ ] **Step 2: `FlagCircle` bundled branch**

In `FlagCircle.body`, mirror the same, using `.clipShape(.circle)` and the emoji `Text` fallback:
```swift
            if let bundled = BundledImageStore.shared.flag(forCode: country.flagImageCode) {
                Image(uiImage: bundled)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else if let url = country.flagImageURL(width: 160) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(.circle)
                    case .empty, .failure:
                        Text(country.flag).font(.system(size: size * 0.55))
                    @unknown default:
                        Text(country.flag).font(.system(size: size * 0.55))
                    }
                }
            } else {
                Text(country.flag).font(.system(size: size * 0.55))
            }
```

- [ ] **Step 3: Build**

Run the Global-Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Runtime verify**

Run on simulator with network off. Open the Country picker. Expected: flags render from the bundle (e.g. `gb`/`us`), sort/scroll smooth; an id with no bundled flag shows the emoji.

- [ ] **Step 5: Commit**

```bash
git add VirtualSIM/Components/FlagImage.swift
git commit -m "feat: FlagImage/FlagCircle render bundled flag first, network as fallback"
```

---

### Task 6: Document the refresh workflow

**Files:**
- Modify: `CLAUDE.md` (add to the logo/flag gotcha area)

**Interfaces:** none.

- [ ] **Step 1: Add a note**

Add under the "Non-obvious gotchas" section of `CLAUDE.md`:
```markdown
- **Logos + flags are bundled** (`VirtualSIM/BundledLogos/<domain>.png`,
  `VirtualSIM/BundledFlags/<code>.png`, folder references). `ServiceLogo`/
  `FlagImage`/`FlagCircle` render the bundled PNG first and fall back to the
  network cascade only for catalog entries not yet bundled. After the catalog
  grows, regenerate + commit: `scripts/fetch-bundled-assets.sh --refresh`, then
  ship an app update. New services/countries work via the network fallback in
  the meantime.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: bundled logos/flags + refresh workflow"
```

---

## Self-Review

**Spec coverage:** storage (Tasks 1–2) ✓; generation script (Task 1) ✓; bundle-first + network fallback loading (Tasks 3–5) ✓; refresh workflow (Task 6) ✓; O(1) membership + cache (Task 3) ✓; visual treatment unchanged (Tasks 4–5 reuse existing modifiers) ✓; `uk`→`gb` key (Task 1 Step 1 + verified Step 3) ✓.

**Placeholder scan:** all steps contain concrete code/commands; no TBD/TODO.

**Type consistency:** `BundledImageStore.shared.logo(forDomain:)` / `.flag(forCode:)` defined in Task 3 are the exact calls used in Tasks 4–5. Keys: `service.domain` and `country.flagImageCode` match Task-1 filenames.

**Adaptation note:** repo has no XCTest target, so tasks verify via build + simulator runtime + script output instead of unit tests (per Global Constraints), rather than the skill's default `pytest`-style TDD loop.
