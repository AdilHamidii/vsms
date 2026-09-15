// Reddit adapter — READ ONLY, and structurally so.
//
// 🔴 The token is minted with `grant_type=client_credentials`, which is Reddit's
// APP-ONLY grant. It carries no user context, so it cannot submit, comment,
// vote or message — the endpoints simply 403. That is deliberate and it is the
// safety property of this whole feature: there is no posting path to disable,
// because the credential cannot post. Do NOT "upgrade" this to a password or
// refresh-token grant to gain write scope. Undisclosed automated promotion is
// a Reddit Rule 2 (inauthentic engagement) violation, it is detected, and the
// sanction that matters is a sitewide DOMAIN ban — which would cost the
// legitimate channel permanently, not just an account.
//
// Two facts that reading the code does not give you:
//   • API calls go to oauth.reddit.com. www.reddit.com is ONLY the token host,
//     and calling the wrong one with a bearer token returns HTML, not JSON.
//   • The User-Agent is mandatory and must be unique and descriptive. A
//     generic or absent one is rate-limited far below the documented ceiling
//     regardless of the token, which reads exactly like "our client id is
//     throttled" and is not.

const TOKEN_URL = "https://www.reddit.com/api/v1/access_token";
const API_BASE = "https://oauth.reddit.com";

/** Free tier is ~100 queries/minute per OAuth client id, averaged over a
 *  10-minute window. One run costs 1 token call + one call per active query,
 *  so an hourly scan of a dozen terms sits three orders of magnitude under it.
 *  The cap is not the constraint here; the SEARCH INDEX is (see searchPosts). */
export const REDDIT_QPM_CEILING = 100;

function creds(): { id: string; secret: string; ua: string } | null {
  const id = Deno.env.get("REDDIT_CLIENT_ID");
  const secret = Deno.env.get("REDDIT_CLIENT_SECRET");
  // Reddit's documented shape: <platform>:<app id>:<version> (by /u/<user>)
  const ua = Deno.env.get("REDDIT_USER_AGENT");
  if (!id || !secret || !ua) return null;
  return { id, secret, ua };
}

export interface RedditPost {
  redditId: string;      // fullname, e.g. t3_abc123
  subreddit: string;
  author: string | null;
  title: string;
  body: string | null;
  permalink: string;
  postedAt: string | null;
  score: number | null;
  numComments: number | null;
}

/** App-only bearer token. Lives ~1 hour; we mint one per run rather than cache
 *  it, because an edge invocation is stateless and one extra request an hour is
 *  cheaper than any store that could go stale. */
export async function redditToken(): Promise<
  { ok: true; token: string } | { ok: false; error: string }
> {
  const c = creds();
  if (!c) return { ok: false, error: "reddit_credentials_missing" };

  let resp: Response;
  try {
    resp = await fetch(TOKEN_URL, {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${c.id}:${c.secret}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": c.ua,
      },
      body: "grant_type=client_credentials",
    });
  } catch (e) {
    return { ok: false, error: `reddit_token_unreachable: ${e}` };
  }

  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    return { ok: false, error: `reddit_token_${resp.status}: ${body.slice(0, 200)}` };
  }

  const j = await resp.json().catch(() => null) as { access_token?: string } | null;
  if (!j?.access_token) return { ok: false, error: "reddit_token_malformed" };
  return { ok: true, token: j.access_token };
}

/** Search posts. `subreddits` is a comma-separated list or null for site-wide.
 *
 *  ⚠️ Reddit's search indexes POSTS well and COMMENTS barely at all — there is
 *  no supported comment-search endpoint, and the old Pushshift mirror that
 *  filled that gap has been closed to general use since 2023. So this surfaces
 *  threads, and the reply opportunity is usually a comment ON one. Do not add
 *  a `type=comment` parameter expecting it to work; it is silently ignored.
 *
 *  `sort=new` + `t=week` is chosen so an hourly poll cannot miss anything: the
 *  window is 168× the cadence. Sorting by relevance would reorder under us and
 *  make the dedupe do all the work. */
export async function searchPosts(
  token: string,
  query: string,
  subreddits: string | null,
  limit = 25,
): Promise<{ ok: true; posts: RedditPost[] } | { ok: false; error: string }> {
  const c = creds();
  if (!c) return { ok: false, error: "reddit_credentials_missing" };

  const params = new URLSearchParams({
    q: query,
    sort: "new",
    t: "week",
    limit: String(limit),
    type: "link",
    // Without this, Reddit HTML-escapes &, < and > inside every body — which
    // then reaches the classifier and the Telegram message as literal &amp;.
    raw_json: "1",
  });

  let path = `/search?${params}`;
  if (subreddits) {
    const subs = subreddits.split(",").map((s) => s.trim()).filter(Boolean).join("+");
    if (subs) {
      params.set("restrict_sr", "1");
      path = `/r/${subs}/search?${params}`;
    }
  }

  let resp: Response;
  try {
    resp = await fetch(`${API_BASE}${path}`, {
      headers: { Authorization: `Bearer ${token}`, "User-Agent": c.ua },
    });
  } catch (e) {
    return { ok: false, error: `reddit_search_unreachable: ${e}` };
  }

  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    return { ok: false, error: `reddit_search_${resp.status}: ${body.slice(0, 200)}` };
  }

  // deno-lint-ignore no-explicit-any
  const j = await resp.json().catch(() => null) as any;
  const children = j?.data?.children;
  if (!Array.isArray(children)) return { ok: false, error: "reddit_search_malformed" };

  const posts: RedditPost[] = [];
  for (const child of children) {
    const d = child?.data;
    if (!d?.name || !d?.title || !d?.permalink) continue;
    // Skip the bot's own noise sources: pinned mod posts are never a lead, and
    // NSFW subs are not somewhere this product should be seen.
    if (d.stickied || d.over_18) continue;
    posts.push({
      redditId: String(d.name),
      subreddit: String(d.subreddit ?? ""),
      author: d.author ? String(d.author) : null,
      title: String(d.title).slice(0, 500),
      body: d.selftext ? String(d.selftext).slice(0, 4000) : null,
      permalink: `https://www.reddit.com${d.permalink}`,
      postedAt: typeof d.created_utc === "number"
        ? new Date(d.created_utc * 1000).toISOString()
        : null,
      score: typeof d.score === "number" ? d.score : null,
      numComments: typeof d.num_comments === "number" ? d.num_comments : null,
    });
  }
  return { ok: true, posts };
}
