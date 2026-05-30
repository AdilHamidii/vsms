# vSIM OTP — App Store submission checklist

Pre-flight items to clear before pressing **Submit for Review**. Work
top to bottom; the build won't even archive cleanly if some of these
are skipped.

## 1. Legal pages live

- [ ] Paste `docs/privacy-policy.md` into a public Notion page
- [ ] Paste `docs/terms.md` into a public Notion page
- [ ] Paste `docs/refund-policy.md` into a public Notion page
- [ ] Paste `docs/help.md` into a public Notion page
- [ ] In each Notion page: **Share → Publish to web** → copy the URL
- [ ] Update `VirtualSIM/LegalLinks.swift` with the four real URLs
- [ ] Update `supportEmail` in the same file to a real address you monitor
- [ ] Update the support email in each docs/*.md file

## 2. App icon

- [x] 1024×1024 light + dark uploaded ✅ (you already did this)
- Apple auto-generates the smaller sizes from the 1024 master

## 3. Build configuration for distribution

- [ ] Bump `MARKETING_VERSION` to `1.0.0` (already there)
- [ ] Bump `CURRENT_PROJECT_VERSION` for every TestFlight build
      (use a monotonically increasing integer, starts at `1`)
- [ ] Flip `aps-environment` from `development` → `production`
      in `VirtualSIM/VirtualSIM.entitlements` **before archiving**
      (then flip back after if you keep dev-building afterward)
- [ ] Set Supabase secret `APNS_ENV` to `production`
      (`supabase secrets set APNS_ENV=production`)
      ⚠️ Test pushes from TestFlight first — sandbox tokens won't
      receive prod-env pushes

## 4. Capabilities present in Xcode

Open the project, select the **VirtualSIM** target → Signing & Capabilities:

- [ ] Sign in with Apple ✅
- [ ] Push Notifications ✅
- [ ] In-App Purchase (auto-added when StoreKit imported)
- [ ] Background Modes: **not** required (we use alert pushes only)

## 5. App Store Connect — record setup

Go to https://appstoreconnect.apple.com → My Apps → **+** → New App.

- Platform: iOS
- Name: **vSIM OTP**
- Primary Language: English (U.S.)
- Bundle ID: `com.anthersystems.VirtualSIM`
- SKU: `vsimotp001` (anything unique, internal)
- User Access: Full Access

Then fill out, in order:

- [ ] **App Information** → category Utilities (primary) + Productivity (secondary)
- [ ] **Pricing & Availability** → Free, all territories you want
- [ ] **App Privacy** → use the nutrition-label table in `docs/app-store-listing.md`
- [ ] **In-App Purchases** → create 3 Consumable products with IDs from `docs/app-store-listing.md`
- [ ] **App Store** tab → 1.0.0 version
  - Promotional Text + Description + Keywords + URLs (all in app-store-listing.md)
  - App Review Information notes (in app-store-listing.md)
  - Version Release: Manual
- [ ] **Screenshots** (see section 6)
- [ ] **Build** — uploaded via Xcode (see section 7)

## 6. Screenshots

Required: **iPhone 6.7"** (iPhone 16 Pro Max, 1290×2796 px).
Recommended also: iPhone 6.5", iPhone 5.5", iPad if you support tablet.

Capture from the iPhone 16 Pro Max simulator (⌘S in the simulator menu).
Suggested 5-shot lineup:

1. **Home — Last used hero** (Service + cost + Get number button)
2. **Service picker** (sheet open, filter chips visible)
3. **Waiting screen** (live pulse animation + timer)
4. **OTP received** (digit grid with the ambient glow)
5. **Account** (showing balance + a few preference rows)

⚠️ Apple's reviewers compare screenshots to the app behavior. Don't
mock up screenshots that show features that aren't actually there.

## 7. Archive + upload

In Xcode:

1. Top bar device selector: choose **Any iOS Device (arm64)** (not a simulator)
2. **Product → Archive** (takes 1–3 minutes)
3. The Organizer window opens with the archive
4. Click **Distribute App** → App Store Connect → Upload → follow prompts
5. Use **automatic signing** (default for your dev account)
6. Wait 10–30 minutes for processing — you'll get an email when ready
7. Back in App Store Connect → Build section → select the processed build

## 8. Submit

- [ ] Answer Export Compliance: encryption = Yes, but exempt (standard HTTPS only)
- [ ] Answer Content Rights: No third-party content
- [ ] Answer Advertising Identifier (IDFA): No (we don't use it)
- [ ] Click **Add for Review** → **Submit for Review**

Apple usually responds within 24–48h for first submissions.

## 9. If rejected

The most likely rejection reasons for this app category:

- **5.2.1 (Brand)** — if any of our service names land too close to a
  real brand. Mitigation: we already use generic names. If a specific
  one is flagged, rename it.
- **4.3 (Spam)** — apps that "circumvent" intended platform behavior.
  Mitigation: our marketing emphasizes privacy, our Terms prohibit
  fraudulent use. Quote those if the reviewer pushes back.
- **5.1.1(v) (Account deletion)** — fully implemented (Account → Danger zone)
- **3.1.1 (IAP)** — only IAP for digital goods. ✅ Credits are digital.
- **Demo account broken** — if reviewer can't sign in: they'll reject.
  Test the full flow once more with a fresh Apple ID before submitting.

If they ask for something specific, fix it and resubmit — turnaround
on second submissions is usually faster.

## 10. Post-approval

- [ ] Switch `APNS_ENV` back to `production` permanently
- [ ] Set up an App Store Connect TestFlight group for staged rollout
- [ ] Add a small status page on your support site for when SMSPVA goes down
