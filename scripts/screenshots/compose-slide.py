"""Compose App Store slides in the house style: wordmark, headline, subline,
then the app frame in a phone bezel that runs off the bottom of the canvas.

usage: compose.py <frame.png> <out.png> <W> <H> <theme: dark|green> <headline|two lines with \\n> <subline>
"""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

frame_path, out_path, W, H, theme, headline, subline = sys.argv[1:8]
W, H = int(W), int(H)
S = W / 1320.0                      # every metric below was measured on the 1320×2868 set

SF = "/System/Library/Fonts/SFNS.ttf"
def font(size, weight):
    f = ImageFont.truetype(SF, int(size * S))
    f.set_variation_by_name(weight)
    return f

GREEN = (34, 197, 94)               # the app's accent, as the wordmark's "v" and the green slides
if theme == "green":
    top, bottom = (33, 178, 78), (26, 158, 66)
    text2 = (236, 252, 240)
else:
    top, bottom = (10, 40, 20), (4, 8, 5)
    text2 = (170, 190, 175)

# background gradient
img = Image.new("RGB", (W, H), bottom)
px = img.load()
grad = Image.new("RGB", (1, H))
for y in range(H):
    t = y / (H - 1)
    grad.putpixel((0, y), tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3)))
img = grad.resize((W, H))
d = ImageDraw.Draw(img)

# wordmark
x0, y = int(112 * S), int(130 * S)
fw = font(96, "Bold")
d.text((x0, y), "v", font=fw, fill=GREEN if theme == "dark" else (12, 60, 28))
vw = d.textlength("v", font=fw)
d.text((x0 + vw, y), "SMS", font=fw, fill=(255, 255, 255))

# headline (up to two lines) + subline (wrapped to ~700 px at 1320)
fh = font(150, "Bold")
y = int(300 * S)
for line in headline.split("\\n"):
    d.text((x0, y), line, font=fh, fill=(255, 255, 255))
    y += int(140 * S)
fs = font(48, "Regular")
y += int(20 * S)
words, line, lines = subline.split(), "", []
for w in words:
    t = (line + " " + w).strip()
    if d.textlength(t, font=fs) > int(1060 * S):
        lines.append(line); line = w
    else:
        line = t
lines.append(line)
for l in lines:
    d.text((x0, y), l, font=fs, fill=text2)
    y += int(62 * S)

# phone: bezel + the app frame, top at ~830, running off the bottom
frame = Image.open(frame_path).convert("RGB")
pw = int(1200 * S)
ph = int(frame.height * pw / frame.width)
frame = frame.resize((pw, ph), Image.LANCZOS)
bez = int(22 * S)
radius = int(120 * S)
px0, py0 = (W - pw) // 2, int(830 * S)
bezel = Image.new("RGBA", (pw + 2 * bez, ph + 2 * bez), (0, 0, 0, 0))
bd = ImageDraw.Draw(bezel)
bd.rounded_rectangle((0, 0, bezel.width - 1, bezel.height - 1), radius=radius + bez, fill=(14, 16, 15, 255), outline=(52, 58, 54, 255), width=int(3 * S))
mask = Image.new("L", frame.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, pw - 1, ph - 1), radius=radius, fill=255)
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((px0 - bez, py0 - bez, px0 + pw + bez, py0 + ph + bez), radius=radius + bez, fill=(0, 0, 0, 140))
shadow = shadow.filter(ImageFilter.GaussianBlur(int(40 * S)))
img = img.convert("RGBA")
img.alpha_composite(shadow)
img.alpha_composite(bezel, (px0 - bez, py0 - bez))
img.paste(frame, (px0, py0), mask)
img.convert("RGB").save(out_path, quality=95)
print("wrote", out_path, W, H)
