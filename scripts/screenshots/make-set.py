import subprocess, json, os
from PIL import Image

import sys
T = sys.argv[1] if len(sys.argv) > 1 else "."   # work dir holding frame_<name>.png, shots/ and compose-slide.py
OUT = f"{T}/set"; os.makedirs(OUT, exist_ok=True)
SLIDES = [
    ("lineStore", "green", "Get a real\\nUSA number",
     "Codes from WhatsApp, TikTok, DoorDash and most other apps. From $5.99 a month."),
    ("lineInbox", "dark", "Your codes\\nland here",
     "Texts from US and Canadian senders arrive in the app. Tap the number to copy it."),
    ("thread", "dark", "One tap to\\ncopy the code",
     "Codes are highlighted the moment they arrive, and every text stays on your number."),
]
SIZES = {"APP_IPHONE_67": (1320, 2868), "APP_IPHONE_65": (1284, 2778)}
KEEP = ["APP_IPHONE_67_01_01_home.jpg", "APP_IPHONE_67_02_02_code.jpg",
        "APP_IPHONE_67_03_03_email.jpg", "APP_IPHONE_67_04_04_checkout.jpg"]
manifest = {}
for dt, (W, H) in SIZES.items():
    files = []
    for i, (frame, theme, head, sub) in enumerate(SLIDES, 1):
        out = f"{OUT}/{dt}_{i:02d}_{frame}.png"
        subprocess.run(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "compose-slide.py"), f"{T}/frame_{frame}.png", out, str(W), str(H), theme, head, sub], check=True)
        files.append(out)
    for j, k in enumerate(KEEP, len(SLIDES) + 1):
        im = Image.open(f"{T}/shots/{k}").convert("RGB")
        if im.size != (W, H):
            im = im.resize((W, H), Image.LANCZOS)
        out = f"{OUT}/{dt}_{j:02d}_{k.split('_', 3)[-1].rsplit('.', 1)[0]}.jpg"
        im.save(out, quality=94)
        files.append(out)
    manifest[dt] = files
json.dump(manifest, open(f"{T}/manifest.json", "w"), indent=1)
for dt, fs in manifest.items():
    print(dt, [os.path.basename(f) for f in fs])
print("DONE")
