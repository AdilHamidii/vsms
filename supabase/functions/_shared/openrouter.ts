// OpenRouter adapter — chat completions (captions) and the Image API (images).
//
//   chat  : POST https://openrouter.ai/api/v1/chat/completions   (Bearer key)
//   image : POST https://openrouter.ai/api/v1/images              (Bearer key)
//           → { data: [{ b64_json, media_type }], usage }
//
// Never throws: every function returns `{ ok: true, … } | { ok: false, error }`
// like the other adapters here, so one bad response cannot take down the
// caller's run.
//
// Model ids are defaults only. Both are overridable without a deploy through
// service-role-only app_config keys `insta_caption_model` / `insta_image_model`
// (a JSON string value). Verified against GET /api/v1/models and
// GET /api/v1/images/models on 2026-09-22 — re-check there before trusting
// these lines; OpenRouter's catalogue moves.

const BASE = "https://openrouter.ai/api/v1";

export const DEFAULT_CAPTION_MODEL = "anthropic/claude-sonnet-5";
/** "Nano Banana". GA (not -preview), accepts aspect_ratio "4:5" on the Image
 *  API, and is the cheapest image model in the catalogue that does. */
export const DEFAULT_IMAGE_MODEL = "google/gemini-2.5-flash-image";

/** Both calls sit inside one ~150s edge invocation alongside everything else;
 *  these bound the worst case so a hung upstream cannot eat the whole budget. */
const CHAT_TIMEOUT_MS = 30_000;
const IMAGE_TIMEOUT_MS = 60_000;

export type Result<T> = { ok: true; value: T } | { ok: false; error: string };

function key(): string | null {
  return Deno.env.get("OPENROUTER_API_KEY") ?? null;
}

export function hasOpenRouterKey(): boolean {
  return !!key();
}

function headers(k: string): HeadersInit {
  return {
    Authorization: `Bearer ${k}`,
    "Content-Type": "application/json",
    // Optional attribution headers OpenRouter documents; harmless if ignored.
    "X-Title": "vSMS insta-draft",
  };
}

/** One chat completion asking for a JSON object. Returns the raw content
 *  string; parsing and validation belong to the caller. */
export async function chatJson(
  model: string, system: string, user: string,
): Promise<Result<string>> {
  const k = key();
  if (!k) return { ok: false, error: "openrouter_key_missing" };

  let resp: Response;
  try {
    resp = await fetch(`${BASE}/chat/completions`, {
      method: "POST",
      headers: headers(k),
      body: JSON.stringify({
        model,
        temperature: 0.7,
        max_tokens: 1200,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: system },
          { role: "user", content: user },
        ],
      }),
      signal: AbortSignal.timeout(CHAT_TIMEOUT_MS),
    });
  } catch (e) {
    return { ok: false, error: `openrouter_unreachable: ${String(e)}` };
  }

  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    return { ok: false, error: `openrouter_${resp.status}: ${body.slice(0, 200)}` };
  }

  const j = await resp.json().catch(() => null) as
    | { choices?: Array<{ message?: { content?: unknown } }> }
    | null;
  const content = j?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    return { ok: false, error: "openrouter_malformed_chat" };
  }
  return { ok: true, value: content };
}

export interface GeneratedImage {
  bytes: Uint8Array;
  mediaType: string | null;
}

/** Generate one image. `aspectRatio` must be one the model lists in its
 *  supported_parameters (gemini-2.5-flash-image accepts "4:5"). */
export async function generateImage(
  model: string, prompt: string, aspectRatio = "4:5",
): Promise<Result<GeneratedImage>> {
  const k = key();
  if (!k) return { ok: false, error: "openrouter_key_missing" };

  let resp: Response;
  try {
    resp = await fetch(`${BASE}/images`, {
      method: "POST",
      headers: headers(k),
      body: JSON.stringify({ model, prompt, aspect_ratio: aspectRatio, n: 1 }),
      signal: AbortSignal.timeout(IMAGE_TIMEOUT_MS),
    });
  } catch (e) {
    return { ok: false, error: `openrouter_image_unreachable: ${String(e)}` };
  }

  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    return { ok: false, error: `openrouter_image_${resp.status}: ${body.slice(0, 200)}` };
  }

  const j = await resp.json().catch(() => null) as
    | { data?: Array<{ b64_json?: unknown; media_type?: unknown }> }
    | null;
  const first = j?.data?.[0];
  if (!first || typeof first.b64_json !== "string" || !first.b64_json) {
    return { ok: false, error: "openrouter_image_malformed" };
  }
  try {
    return {
      ok: true,
      value: {
        bytes: base64ToBytes(first.b64_json),
        mediaType: typeof first.media_type === "string" ? first.media_type : null,
      },
    };
  } catch (e) {
    return { ok: false, error: `openrouter_image_b64: ${String(e)}` };
  }
}

function base64ToBytes(b64: string): Uint8Array {
  // Tolerate a data: URL prefix in case a provider returns one.
  const clean = b64.replace(/^data:[^,]*,/, "");
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
