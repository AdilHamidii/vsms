"""Compose the App Store screenshot set from captured simulator frames.

The six frames are captured with `-screenshot <frame>` on an iPhone 17 Pro Max
(1320x2868) by `capture-frames.sh`, which drops `frame_<name>.png` in the work
dir. Every slide in the set is composed from one of those frames — there is no
longer any pass-through of previously exported shots.
"""
import subprocess, json, os

import sys
T = sys.argv[1] if len(sys.argv) > 1 else "."   # work dir holding frame_<name>.png and compose-slide.py
OUT = f"{T}/set"; os.makedirs(OUT, exist_ok=True)
SLIDES = [
    ("homeRouter", "green", "What do\\nyou need?",
     "A second number you keep, a one-time SMS code, or a throwaway email. All in one app."),
    ("lineStore", "green", "Get a real\\nUSA number",
     "Calls, texts and codes from WhatsApp, TikTok, DoorDash and most other apps. Yours to keep."),
    ("lineInbox", "dark", "Your codes\\nland here",
     "Texts from US and Canadian senders arrive in the app. Tap the number to copy it."),
    ("thread", "dark", "One tap to\\ncopy the code",
     "Codes are highlighted the moment they arrive, and every text stays on your number."),
    ("home", "dark", "Or a number\\nfor one code",
     "Pick the service and the country, get a temporary number, and the code arrives in the app. No code, no charge."),
    ("email", "green", "A throwaway\\nemail too",
     "An Outlook or Hotmail address that receives the confirmation for you, then goes away."),
]
SIZES = {"APP_IPHONE_67": (1320, 2868), "APP_IPHONE_65": (1284, 2778)}
manifest = {}
for dt, (W, H) in SIZES.items():
    files = []
    for i, (frame, theme, head, sub) in enumerate(SLIDES, 1):
        out = f"{OUT}/{dt}_{i:02d}_{frame}.png"
        subprocess.run(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "compose-slide.py"), f"{T}/frame_{frame}.png", out, str(W), str(H), theme, head, sub], check=True)
        files.append(out)
    manifest[dt] = files
json.dump(manifest, open(f"{T}/manifest.json", "w"), indent=1)
for dt, fs in manifest.items():
    print(dt, [os.path.basename(f) for f in fs])
print("DONE")
