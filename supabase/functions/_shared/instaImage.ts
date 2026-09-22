// Instagram image composition — pure TS + imagescript (wasm), no native deps.
//
// Two shapes, both 1080×1350 JPEG (Instagram feed accepts 4:5 … 1.91:1, and
// ONLY JPEG through the Content Publishing API):
//   • screenshot — a real app screenshot on the brand background, with an
//     AI-written headline rendered as large text above it;
//   • ai         — a model-generated image, cover-cropped to 4:5.
//
// ⚠️ imagescript@1.3.0, deliberately not 1.4.0. 1.4.0 loads its wasm through
// ES `import * as wasm from './x.wasm'`, which needs the bundler to understand
// wasm module imports; 1.3.0 fetches the .wasm next to its own
// `import.meta.url` at module load, which is plain fetch + WebAssembly.Module.
// That is the shape more likely to survive Supabase's eszip bundling. It is
// NOT proven in the hosted runtime until `insta-draft {"probe":"image"}` has
// returned a URL — that probe exists precisely to settle it with zero
// credentials.
//
// ⚠️ imagescript only offers NEAREST-NEIGHBOUR resizing, which turns a 0.5×
// screenshot's text into jagged noise. `resample` below does an integer box
// pre-shrink then bilinear, which is what every resize here goes through.

import { Image, TextLayout } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

export const POST_WIDTH = 1080;
export const POST_HEIGHT = 1350;

/** Inter ExtraBold, latin subset, pinned by version on jsDelivr (fontsource).
 *  Fetched at runtime rather than committed: a 68 KB binary in the repo buys
 *  nothing a pinned, immutable CDN path does not, and bundling a static file
 *  into an edge function needs `static_files` + a Docker build. Latin-only is
 *  fine: headlines are English; a non-latin glyph would render as a box. */
const FONT_URL =
  "https://cdn.jsdelivr.net/fontsource/fonts/inter@5.2.5/latin-800-normal.ttf";

/** Brand: near-black green background, the app's accent green #279400 as a
 *  thin rule, white headline. The accent is used as a rule, not as text on
 *  dark, because it measures poorly against a dark ground. */
const BG = rgba(0x0b, 0x12, 0x0d, 0xff);
const ACCENT = rgba(0x27, 0x94, 0x00, 0xff);
const INK = rgba(0xff, 0xff, 0xff, 0xff);

const JPEG_QUALITY = 88;

let fontCache: Uint8Array | null = null;

export type ImageResult =
  | { ok: true; jpeg: Uint8Array }
  | { ok: false; error: string };

function rgba(r: number, g: number, b: number, a: number): number {
  return Image.rgbaToColor(r, g, b, a);
}

async function loadFont(): Promise<Uint8Array> {
  if (fontCache) return fontCache;
  const resp = await fetch(FONT_URL, { signal: AbortSignal.timeout(10_000) });
  if (!resp.ok) throw new Error(`font_fetch_${resp.status}`);
  fontCache = new Uint8Array(await resp.arrayBuffer());
  return fontCache;
}

/** Box pre-shrink by the largest integer factor that keeps the image at least
 *  the target size, then bilinear to the exact size. Good enough for a 2–3×
 *  reduction of UI text; far better than nearest-neighbour. */
function resample(src: Image, w: number, h: number): Image {
  let cur = src;
  const k = Math.floor(Math.min(cur.width / w, cur.height / h));
  if (k >= 2) cur = boxShrink(cur, k);
  if (cur.width === w && cur.height === h) return cur;
  return bilinear(cur, w, h);
}

function boxShrink(src: Image, k: number): Image {
  const w = Math.floor(src.width / k);
  const h = Math.floor(src.height / k);
  const out = new Image(w, h);
  const s = src.bitmap;
  const d = out.bitmap;
  const sw = src.width;
  const n = k * k;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let dy = 0; dy < k; dy++) {
        let i = ((y * k + dy) * sw + x * k) * 4;
        for (let dx = 0; dx < k; dx++, i += 4) {
          r += s[i]; g += s[i + 1]; b += s[i + 2]; a += s[i + 3];
        }
      }
      const o = (y * w + x) * 4;
      d[o] = r / n; d[o + 1] = g / n; d[o + 2] = b / n; d[o + 3] = a / n;
    }
  }
  return out;
}

function bilinear(src: Image, w: number, h: number): Image {
  const out = new Image(w, h);
  const s = src.bitmap;
  const d = out.bitmap;
  const sw = src.width, sh = src.height;
  const xr = sw / w, yr = sh / h;
  for (let y = 0; y < h; y++) {
    const fy = Math.max(0, (y + 0.5) * yr - 0.5);
    const y0 = Math.min(sh - 1, Math.floor(fy));
    const y1 = Math.min(sh - 1, y0 + 1);
    const wy = fy - y0;
    for (let x = 0; x < w; x++) {
      const fx = Math.max(0, (x + 0.5) * xr - 0.5);
      const x0 = Math.min(sw - 1, Math.floor(fx));
      const x1 = Math.min(sw - 1, x0 + 1);
      const wx = fx - x0;
      const i00 = (y0 * sw + x0) * 4, i01 = (y0 * sw + x1) * 4;
      const i10 = (y1 * sw + x0) * 4, i11 = (y1 * sw + x1) * 4;
      const o = (y * w + x) * 4;
      for (let c = 0; c < 4; c++) {
        const top = s[i00 + c] * (1 - wx) + s[i01 + c] * wx;
        const bot = s[i10 + c] * (1 - wx) + s[i11 + c] * wx;
        d[o + c] = top * (1 - wy) + bot * wy;
      }
    }
  }
  return out;
}

/** Scale to cover w×h, then centre-crop. */
function coverCrop(src: Image, w: number, h: number): Image {
  const scale = Math.max(w / src.width, h / src.height);
  const sw = Math.max(w, Math.round(src.width * scale));
  const sh = Math.max(h, Math.round(src.height * scale));
  const scaled = resample(src, sw, sh);
  return scaled.crop(Math.floor((sw - w) / 2), Math.floor((sh - h) / 2), w, h);
}

/** Render the headline, shrinking the font until it fits the box. Returns
 *  null when text rendering fails for any reason, so the caller can fall back
 *  to a no-overlay image (the headline still ships in the caption). */
async function renderHeadline(text: string, maxW: number, maxH: number): Promise<Image | null> {
  try {
    const font = await loadFont();
    for (let size = 84; size >= 48; size -= 6) {
      const img = Image.renderText(
        font, size, text, INK,
        new TextLayout({ maxWidth: maxW, wrapStyle: "word", verticalAlign: "center" }),
      );
      if (img.height <= maxH) return img;
    }
    return null;
  } catch (e) {
    console.error(`instaImage: headline render failed: ${String(e)}`);
    return null;
  }
}

/**
 * Screenshot kind. Layout, top to bottom:
 *   80px margin · headline (≤ 300px tall, centred) · accent rule ·
 *   the screenshot at 660px wide with rounded corners, top-anchored and
 *   bleeding off the bottom edge.
 *
 * Why a bleed rather than fit-whole: a 1320×2868 phone capture scaled to fit
 * the ~850px left under the headline is ~390px wide, and UI text at that size
 * is unreadable in a feed. The top ~60% of every screen is where its content
 * sits (title, cards), so that is the part worth showing large.
 *
 * `headline` null or render failure → no text; the screenshot moves up. The
 * result reports which happened so the caller can say so.
 */
export async function composeScreenshotPost(
  screenshotPng: Uint8Array,
  headline: string | null,
): Promise<ImageResult & { textRendered?: boolean }> {
  try {
    const canvas = new Image(POST_WIDTH, POST_HEIGHT).fill(BG);
    const shot = await Image.decode(screenshotPng);

    let top = 80;
    let textRendered = false;
    if (headline && headline.trim()) {
      const text = await renderHeadline(headline.trim(), POST_WIDTH - 140, 300);
      if (text) {
        canvas.composite(text, Math.floor((POST_WIDTH - text.width) / 2), top);
        top += text.height + 36;
        canvas.drawBox(Math.floor((POST_WIDTH - 120) / 2), top, 120, 8, ACCENT);
        top += 8 + 44;
        textRendered = true;
      }
    }

    const shotW = 660;
    const shotH = Math.round(shot.height * (shotW / shot.width));
    let phone = resample(shot, shotW, shotH);
    const radius = 44;
    // Keep one radius below the canvas so only the TOP corners show rounded.
    const visible = Math.min(shotH, POST_HEIGHT - top + radius);
    if (visible < shotH) phone = phone.crop(0, 0, shotW, visible);
    phone.roundCorners(radius);
    canvas.composite(phone, Math.floor((POST_WIDTH - shotW) / 2), top);

    const jpeg = await canvas.encodeJPEG(JPEG_QUALITY);
    return { ok: true, jpeg, textRendered };
  } catch (e) {
    return { ok: false, error: `compose_screenshot: ${String(e)}` };
  }
}

/** AI kind: whatever the model returned (PNG/JPEG), cover-cropped to 4:5. */
export async function composeAiPost(modelImage: Uint8Array): Promise<ImageResult> {
  try {
    const src = await Image.decode(modelImage);
    const out = coverCrop(src, POST_WIDTH, POST_HEIGHT);
    return { ok: true, jpeg: await out.encodeJPEG(JPEG_QUALITY) };
  } catch (e) {
    return { ok: false, error: `compose_ai: ${String(e)}` };
  }
}
