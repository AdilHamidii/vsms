// Instagram Content Publishing — Instagram API with Instagram Login.
//
//   POST {BASE}/{ig-user-id}/media          image_url + caption → container id
//   GET  {BASE}/{container-id}?fields=status_code   until FINISHED | ERROR
//   POST {BASE}/{ig-user-id}/media_publish  creation_id → media id
//   GET  https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token
//
// Professional accounts only; permissions instagram_business_basic +
// instagram_business_content_publish; 100 API posts per rolling 24h; JPEG
// only; the image must sit at a PUBLIC URL Meta can fetch.
//
// 🔴 Nothing in this file is reachable except from the owner's Post tap in
// telegram-webhook. insta-draft only DRAFTS; it never imports publishImage.
//
// 🔴 TOKEN STORAGE. Supabase secrets cannot be written from inside an edge
// function, and a long-lived Instagram token expires after 60 days unless it
// is refreshed — so the LIVE token lives in app_config.instagram_token as
// {access_token, refreshed_at}, seeded once from the INSTAGRAM_ACCESS_TOKEN
// secret when the key is absent. That key is service-role only: it must NEVER
// be added to the app_config RLS whitelist, which would publish a credential
// that can post to the brand account to anyone holding the publishable key.
//
// Never throws: every export returns `{ ok: true, … } | { ok: false, error }`.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

/** Graph API version. v26.0 is the latest listed on Meta's changelog
 *  (released 2026-07-29, read 2026-09-22). Bump deliberately. */
export const GRAPH_VERSION = "v26.0";
const BASE = `https://graph.instagram.com/${GRAPH_VERSION}`;

const TOKEN_KEY = "instagram_token";
/** Refresh well inside the 60-day life; a token must be ≥24h old to refresh. */
const REFRESH_AFTER_MS = 7 * 24 * 3600 * 1000;

/** Container processing poll. Bounded well inside the ~150s edge ceiling. */
const POLL_INTERVAL_MS = 3_000;
const POLL_DEADLINE_MS = 60_000;
const CALL_TIMEOUT_MS = 20_000;

type Result<T> = { ok: true; value: T } | { ok: false; error: string };

interface StoredToken { access_token: string; refreshed_at: string }

function igUserId(): string | null {
  return Deno.env.get("INSTAGRAM_USER_ID") ?? null;
}

/** Graph errors come back as {error:{message,type,code,error_subcode}}. */
async function graphError(resp: Response, what: string): Promise<string> {
  const body = await resp.text().catch(() => "");
  try {
    const j = JSON.parse(body) as { error?: { message?: string; code?: number; error_subcode?: number } };
    if (j.error) {
      return `${what}_${resp.status}: ${j.error.code ?? ""}/${j.error.error_subcode ?? ""} ${j.error.message ?? ""}`.slice(0, 300);
    }
  } catch { /* fall through to raw body */ }
  return `${what}_${resp.status}: ${body.slice(0, 200)}`;
}

/** Read the live token, seeding from the secret on first use and refreshing it
 *  when older than REFRESH_AFTER_MS. A failed refresh is logged and the old
 *  token is still returned — it is valid for up to 60 days, and failing the
 *  publish over a refresh hiccup would be the wrong trade. */
export async function getToken(sb: SupabaseClient): Promise<Result<string>> {
  const { data, error } = await sb
    .from("app_config").select("value").eq("key", TOKEN_KEY).maybeSingle();
  if (error) return { ok: false, error: `token_read: ${error.message}` };

  let stored = data?.value as StoredToken | null | undefined;
  if (!stored?.access_token) {
    const seed = Deno.env.get("INSTAGRAM_ACCESS_TOKEN");
    if (!seed) return { ok: false, error: "instagram_token_missing" };
    // The seed's real age is unknown; stamping now means the first refresh
    // happens 7 days from here, comfortably inside any 60-day life.
    stored = { access_token: seed, refreshed_at: new Date().toISOString() };
    const { error: wErr } = await sb.from("app_config")
      .upsert({ key: TOKEN_KEY, value: stored }, { onConflict: "key" });
    if (wErr) console.error(`instagram: token seed write failed: ${wErr.message}`);
  }

  const age = Date.now() - Date.parse(stored.refreshed_at);
  if (!Number.isFinite(age) || age > REFRESH_AFTER_MS) {
    const r = await refreshToken(stored.access_token);
    if (r.ok) {
      stored = { access_token: r.value, refreshed_at: new Date().toISOString() };
      const { error: wErr } = await sb.from("app_config")
        .upsert({ key: TOKEN_KEY, value: stored }, { onConflict: "key" });
      if (wErr) console.error(`instagram: refreshed token write failed: ${wErr.message}`);
    } else {
      console.error(`instagram: token refresh failed (using existing token): ${r.error}`);
    }
  }
  return { ok: true, value: stored.access_token };
}

export async function refreshToken(token: string): Promise<Result<string>> {
  const url = new URL("https://graph.instagram.com/refresh_access_token");
  url.searchParams.set("grant_type", "ig_refresh_token");
  url.searchParams.set("access_token", token);
  let resp: Response;
  try {
    resp = await fetch(url, { signal: AbortSignal.timeout(CALL_TIMEOUT_MS) });
  } catch (e) {
    return { ok: false, error: `refresh_unreachable: ${String(e)}` };
  }
  if (!resp.ok) return { ok: false, error: await graphError(resp, "refresh") };
  const j = await resp.json().catch(() => null) as { access_token?: unknown } | null;
  if (typeof j?.access_token !== "string") return { ok: false, error: "refresh_malformed" };
  return { ok: true, value: j.access_token };
}

async function postForm(path: string, params: Record<string, string>, what: string): Promise<Result<string>> {
  let resp: Response;
  try {
    resp = await fetch(`${BASE}/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params),
      signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
    });
  } catch (e) {
    return { ok: false, error: `${what}_unreachable: ${String(e)}` };
  }
  if (!resp.ok) return { ok: false, error: await graphError(resp, what) };
  const j = await resp.json().catch(() => null) as { id?: unknown } | null;
  if (j?.id == null) return { ok: false, error: `${what}_malformed` };
  return { ok: true, value: String(j.id) };
}

export function createContainer(
  token: string, userId: string, imageUrl: string, caption: string,
): Promise<Result<string>> {
  return postForm(`${userId}/media`, { image_url: imageUrl, caption, access_token: token }, "container");
}

/** Poll until FINISHED. ERROR / EXPIRED / deadline are failures. */
export async function waitForContainer(
  token: string, containerId: string, deadlineMs = POLL_DEADLINE_MS,
): Promise<Result<"FINISHED">> {
  const until = Date.now() + deadlineMs;
  let last = "unknown";
  while (Date.now() < until) {
    const url = new URL(`${BASE}/${containerId}`);
    url.searchParams.set("fields", "status_code,status");
    url.searchParams.set("access_token", token);
    try {
      const resp = await fetch(url, { signal: AbortSignal.timeout(CALL_TIMEOUT_MS) });
      if (!resp.ok) return { ok: false, error: await graphError(resp, "status") };
      const j = await resp.json().catch(() => null) as { status_code?: unknown; status?: unknown } | null;
      last = String(j?.status_code ?? "unknown");
      if (last === "FINISHED") return { ok: true, value: "FINISHED" };
      if (last === "ERROR" || last === "EXPIRED") {
        return { ok: false, error: `container_${last}: ${String(j?.status ?? "").slice(0, 200)}` };
      }
    } catch (e) {
      last = `unreachable: ${String(e)}`;
    }
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
  return { ok: false, error: `container_timeout (last: ${last})` };
}

export function publishContainer(token: string, userId: string, containerId: string): Promise<Result<string>> {
  return postForm(`${userId}/media_publish`, { creation_id: containerId, access_token: token }, "publish");
}

export interface PublishOutcome { containerId: string | null; mediaId: string | null; error: string | null }

/** The whole publish: token → container → wait → publish. Always returns the
 *  container id it got, so a failure after container creation is traceable. */
export async function publishImage(
  sb: SupabaseClient, imageUrl: string, caption: string,
): Promise<PublishOutcome> {
  const userId = igUserId();
  if (!userId) return { containerId: null, mediaId: null, error: "instagram_user_id_missing" };

  const tok = await getToken(sb);
  if (!tok.ok) return { containerId: null, mediaId: null, error: tok.error };

  const c = await createContainer(tok.value, userId, imageUrl, caption);
  if (!c.ok) return { containerId: null, mediaId: null, error: c.error };

  const w = await waitForContainer(tok.value, c.value);
  if (!w.ok) return { containerId: c.value, mediaId: null, error: w.error };

  const p = await publishContainer(tok.value, userId, c.value);
  if (!p.ok) return { containerId: c.value, mediaId: null, error: p.error };

  return { containerId: c.value, mediaId: p.value, error: null };
}
