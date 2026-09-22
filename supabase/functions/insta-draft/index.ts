// Instagram drafts — cron-driven (relay-insta-draft, daily 08:00 UTC).
//
// Generates ONE draft post (image + caption) and sends it to the owner's
// Telegram as a photo with two buttons, Post and Skip. 🔴 This function NEVER
// publishes: it does not import the publish path at all. Publishing happens
// only in telegram-webhook, only on the owner's Post tap, behind an atomic
// pending → publishing claim.
//
// Kinds alternate off the last row: `screenshot` (a real app screenshot from
// insta/screens/*.png with an AI headline drawn above it) and `ai` (a fully
// model-generated image). Themes rotate, avoiding the last few used.
//
// Body:
//   {}                  the cron run — skipped if a draft was made < 20h ago
//   {"force":true}      draft now regardless
//   {"probe":"image"}   compose ONE screenshot-kind image with a fixed headline,
//                       upload it, return its public URL. Calls NO model and NO
//                       Instagram, needs no credentials — it proves the image
//                       library (wasm + font) works in the HOSTED runtime.
//
// Guarded by the cron secret (403 without it) and deployed --no-verify-jwt:
// the pg_cron relay sends only x-cron-secret.
//
// ⚠️ Deliberately NO watchdog check of its own — the reddit-scan exception.
// The whole failure mode is "no draft today", which costs nothing and is
// visible in the chat by its absence; paging for it would spend the one
// channel that has to stay readable. Check by hand:
//   select status, count(*) from insta_posts group by 1;
//   select created_at, error from insta_posts where status='failed' order by 1 desc limit 5;

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { readWithRetry } from "../_shared/pgRetry.ts";
import { esc, sendMessage, sendPhoto } from "../_shared/telegram.ts";
import {
  chatJson, generateImage, hasOpenRouterKey,
  DEFAULT_CAPTION_MODEL, DEFAULT_IMAGE_MODEL,
} from "../_shared/openrouter.ts";
import {
  CAPTION_SYSTEM, THEMES, captionUserPrompt, parseDraft, validateDraft,
  type CaptionDraft, type PostKind,
} from "../_shared/instaCopy.ts";
import { composeAiPost, composeScreenshotPost } from "../_shared/instaImage.ts";
import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const BUCKET = "insta";
const SCREENS_PREFIX = "screens";

/** Don't repeat any of the last N themes. THEMES has 8, so 4 leaves a choice. */
const AVOID_LAST_THEMES = 4;

/** A cron run inside this window of the last draft is a duplicate (a manual
 *  trigger, a retried relay) and does nothing. `force` bypasses it. */
const MIN_GAP_MS = 20 * 3600 * 1000;

/** Caption attempts: the first, plus ONE retry when the validator rejects. */
const CAPTION_ATTEMPTS = 2;

const PROBE_HEADLINE = "Keep your real number off sign-up forms";

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  return !!header && !!expected && header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) {
    return json({ error: "forbidden" }, { status: 403 });
  }

  let body: { probe?: unknown; force?: unknown } = {};
  try { body = await req.json(); } catch { /* empty body = cron run */ }

  const sb = admin();

  if (body.probe === "image") return await probeImage(sb);

  // Same shape as reddit-scan's credentials-missing path: a clean 200 no-op,
  // so the cron does not flap while the secret is unset.
  if (!hasOpenRouterKey()) {
    return json({ ok: true, skipped: "openrouter_key_missing" });
  }

  const { data: recent, error: rErr } = await readWithRetry(() =>
    sb.from("insta_posts")
      .select("kind, theme, created_at, status")
      .order("created_at", { ascending: false })
      .limit(8)
  );
  if (rErr) return json({ error: "recent_read_failed", detail: rErr.message }, { status: 500 });

  const last = recent?.[0];
  if (body.force !== true && last && Date.now() - Date.parse(last.created_at) < MIN_GAP_MS) {
    return json({ ok: true, skipped: "drafted_recently", last_at: last.created_at });
  }

  const screens = await listScreens(sb);
  // Alternate off the last row; screenshot kind needs at least one screenshot.
  let kind: PostKind = last?.kind === "screenshot" ? "ai" : "screenshot";
  if (kind === "screenshot" && !screens.length) kind = "ai";

  const recentThemes = new Set((recent ?? []).slice(0, AVOID_LAST_THEMES).map((r) => r.theme));
  const candidates = THEMES.filter((t) => !recentThemes.has(t.key));
  const pool = candidates.length ? candidates : THEMES;
  const theme = pool[Math.floor(Math.random() * pool.length)];

  const models = await readModels(sb);

  // ── caption + headline ────────────────────────────────────────────────────
  let draft: CaptionDraft | null = null;
  const rejections: string[] = [];
  for (let i = 0; i < CAPTION_ATTEMPTS && !draft; i++) {
    const r = await chatJson(models.caption, CAPTION_SYSTEM, captionUserPrompt(theme, kind));
    if (!r.ok) { rejections.push(r.error); continue; }
    const parsed = parseDraft(r.value);
    if (!parsed) { rejections.push("unparseable"); continue; }
    const hits = validateDraft(parsed);
    if (hits.length) { rejections.push(`rejected: ${hits.join(", ")}`); continue; }
    draft = parsed;
  }
  if (!draft) {
    return await recordFailure(sb, {
      kind, theme: theme.key, caption_model: models.caption,
      error: `caption: ${rejections.join(" | ")}`.slice(0, 1000),
    });
  }

  // ── image ─────────────────────────────────────────────────────────────────
  let jpeg: Uint8Array;
  let textNote = "";
  if (kind === "screenshot") {
    const pick = screens[Math.floor(Math.random() * screens.length)];
    const png = await download(sb, `${SCREENS_PREFIX}/${pick}`);
    if (!png.ok) return await recordFailure(sb, draftFields(kind, theme.key, draft, models, png.error));
    const img = await composeScreenshotPost(png.value, draft.headline);
    if (!img.ok) return await recordFailure(sb, draftFields(kind, theme.key, draft, models, img.error));
    jpeg = img.jpeg;
    if (!img.textRendered) textNote = "\n<i>Headline could not be drawn on the image; it is only in this message.</i>";
  } else {
    const prompt = (draft.imagePrompt || theme.brief) +
      " No text, no letters, no logos, no phone screens or app UI in the image.";
    const gen = await generateImage(models.image, prompt, "4:5");
    if (!gen.ok) return await recordFailure(sb, draftFields(kind, theme.key, draft, models, gen.error));
    const img = await composeAiPost(gen.value.bytes);
    if (!img.ok) return await recordFailure(sb, draftFields(kind, theme.key, draft, models, img.error));
    jpeg = img.jpeg;
  }

  // ── upload, record, show the owner ────────────────────────────────────────
  const id = crypto.randomUUID();
  const path = `posts/${id}.jpg`;
  const up = await upload(sb, path, jpeg);
  if (!up.ok) return await recordFailure(sb, draftFields(kind, theme.key, draft, models, up.error));

  const { error: insErr } = await sb.from("insta_posts").insert({
    id, status: "pending", kind, theme: theme.key,
    headline: draft.headline, caption: draft.caption,
    image_path: path, image_url: up.value,
    caption_model: models.caption,
    image_model: kind === "ai" ? models.image : null,
  });
  if (insErr) return json({ error: "insert_failed", detail: insErr.message }, { status: 500 });

  const html =
    `📸 <b>Instagram draft</b> · ${kind === "ai" ? "AI image" : "screenshot"} · ${esc(theme.key)}\n` +
    `<b>${esc(draft.headline)}</b>\n\n` +
    `${esc(draft.caption)}\n\n` +
    `<i>Nothing is posted until you tap Post.</i>${textNote}`;

  const msgId = await sendPhoto(up.value, html, {
    inline_keyboard: [[
      { text: "✅ Post", callback_data: `insta:post:${id}` },
      { text: "🚫 Skip", callback_data: `insta:skip:${id}` },
    ]],
  });

  if (msgId == null) {
    // The owner never saw it, so it can never be approved: close it out rather
    // than leave a pending row nobody can act on.
    const { error } = await sb.from("insta_posts")
      .update({ status: "failed", error: "telegram_send_failed" })
      .eq("id", id).eq("status", "pending");
    if (error) console.error(`insta-draft: mark failed ${id}: ${error.message}`);
    return json({ ok: false, id, error: "telegram_send_failed" }, { status: 502 });
  }

  const { error: mErr } = await sb.from("insta_posts")
    .update({ tg_message_id: msgId }).eq("id", id);
  if (mErr) console.error(`insta-draft: tg_message_id write ${id}: ${mErr.message}`);

  return json({ ok: true, id, kind, theme: theme.key, image_url: up.value, retries: rejections.length });
});

// ─────────────────────────────────────────────────────────────────────────────

type R<T> = { ok: true; value: T } | { ok: false; error: string };

async function readModels(sb: SupabaseClient): Promise<{ caption: string; image: string }> {
  const { data, error } = await readWithRetry(() =>
    sb.from("app_config").select("key, value")
      .in("key", ["insta_caption_model", "insta_image_model"])
  );
  if (error) console.error(`insta-draft: model config read: ${error.message}`);
  const get = (k: string) => {
    const v = data?.find((r) => r.key === k)?.value;
    return typeof v === "string" && v.trim() ? v.trim() : null;
  };
  return {
    caption: get("insta_caption_model") ?? DEFAULT_CAPTION_MODEL,
    image: get("insta_image_model") ?? DEFAULT_IMAGE_MODEL,
  };
}

/** Screenshot file names under insta/screens/, listed at runtime so the set
 *  can change by uploading files, never by editing code. */
async function listScreens(sb: SupabaseClient): Promise<string[]> {
  const { data, error } = await sb.storage.from(BUCKET).list(SCREENS_PREFIX, { limit: 100 });
  if (error) { console.error(`insta-draft: list screens: ${error.message}`); return []; }
  return (data ?? []).map((f) => f.name).filter((n) => /\.png$/i.test(n));
}

async function download(sb: SupabaseClient, path: string): Promise<R<Uint8Array>> {
  const { data, error } = await sb.storage.from(BUCKET).download(path);
  if (error || !data) return { ok: false, error: `download ${path}: ${error?.message ?? "empty"}` };
  return { ok: true, value: new Uint8Array(await data.arrayBuffer()) };
}

/** Upload a JPEG and return its PUBLIC url — the one Instagram will fetch. */
async function upload(sb: SupabaseClient, path: string, jpeg: Uint8Array): Promise<R<string>> {
  const { error } = await sb.storage.from(BUCKET)
    .upload(path, jpeg, { contentType: "image/jpeg", upsert: false });
  if (error) return { ok: false, error: `upload ${path}: ${error.message}` };
  return { ok: true, value: sb.storage.from(BUCKET).getPublicUrl(path).data.publicUrl };
}

function draftFields(
  kind: PostKind, theme: string, d: CaptionDraft,
  models: { caption: string; image: string }, error: string,
): Record<string, unknown> {
  return {
    kind, theme, headline: d.headline, caption: d.caption,
    caption_model: models.caption, image_model: kind === "ai" ? models.image : null,
    error: error.slice(0, 1000),
  };
}

/** Record a failed draft and tell the owner, in that order. Returns 200: a
 *  failed draft is a normal outcome, and a 500 would only trip the watchdog's
 *  generic relay-http check for something that costs nothing. */
async function recordFailure(sb: SupabaseClient, fields: Record<string, unknown>): Promise<Response> {
  const { data, error } = await sb.from("insta_posts")
    .insert({ ...fields, status: "failed" }).select("id").maybeSingle();
  if (error) console.error(`insta-draft: failure insert: ${error.message}`);
  await sendMessage(
    `📸 <b>Instagram draft failed</b> · ${esc(fields.kind)} · ${esc(fields.theme)}\n` +
    `<code>${esc(String(fields.error ?? "").slice(0, 600))}</code>\n` +
    `<i>No post was drafted today. Nothing was published.</i>`,
  );
  return json({ ok: false, id: data?.id ?? null, error: fields.error });
}

/** Compose one screenshot-kind image with a fixed headline and upload it.
 *  Uses a real screenshot from the bucket if one exists, else a synthetic
 *  grey "phone" — either way it exercises PNG decode, font fetch + render,
 *  and JPEG encode, which are the parts that might not survive bundling. */
async function probeImage(sb: SupabaseClient): Promise<Response> {
  const t0 = Date.now();
  const screens = await listScreens(sb);
  let png: Uint8Array;
  let source: string;
  if (screens.length) {
    const d = await download(sb, `${SCREENS_PREFIX}/${screens[0]}`);
    if (!d.ok) return json({ ok: false, stage: "download", error: d.error }, { status: 500 });
    png = d.value;
    source = screens[0];
  } else {
    try {
      png = await new Image(1320, 2868).fill(Image.rgbaToColor(0x2a, 0x2f, 0x2c, 0xff)).encode();
      source = "synthetic";
    } catch (e) {
      return json({ ok: false, stage: "synthetic_png", error: String(e) }, { status: 500 });
    }
  }
  const img = await composeScreenshotPost(png, PROBE_HEADLINE);
  if (!img.ok) return json({ ok: false, stage: "compose", error: img.error }, { status: 500 });
  const up = await upload(sb, `probe/${Date.now()}.jpg`, img.jpeg);
  if (!up.ok) return json({ ok: false, stage: "upload", error: up.error }, { status: 500 });
  return json({
    ok: true, url: up.value, source, text_rendered: img.textRendered,
    bytes: img.jpeg.length, ms: Date.now() - t0,
  });
}
