// Reddit radar — cron-driven (relay-reddit-scan, hourly at :26).
//
// Three phases, in order, each bounded so the whole run fits inside the ~150s
// edge ceiling and anything it does not finish is simply picked up next hour:
//
//   A. SEARCH   every active reddit_queries row, insert genuinely new threads.
//   B. CLASSIFY up to CLASSIFY_BUDGET unscored rows through Kimi.
//   C. NOTIFY   the ones that clear the bar, to Telegram, with a DRAFT reply.
//
// 🔴 It never posts to Reddit, and it cannot: the credential is app-only (see
// _shared/reddit.ts). The draft is for the owner to edit and post by hand from
// their own account. Do not add a posting path — undisclosed automated
// promotion is a Reddit Rule 2 violation whose sanction is a sitewide DOMAIN
// ban, which would cost the legitimate channel permanently.
//
// Guarded by the cron secret and deployed --no-verify-jwt: the pg_cron relay
// sends only x-cron-secret and no Authorization header, so with verify_jwt on
// every run 401s silently — the exact failure that left `winback` sending zero
// nudges for two months.
//
// ⚠️ Deliberately has NO watchdog check of its own, the same exception
// relay-rc-sync carries. The watchdog's only output is a Telegram page, and
// the entire failure mode here is "a marketing lead arrived late or not at
// all" — which costs nothing and fixes itself next run. Paging for it would
// spend the one channel that has to stay readable, which this repo already
// records as how the next real outage gets missed. Check it by hand with
// /leads, and look at reddit_leads.classify_error when the numbers look wrong.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { redditToken, searchPosts } from "../_shared/reddit.ts";
import { classifyLead } from "../_shared/kimi.ts";
import { sendMessageWithId, esc } from "../_shared/telegram.ts";

/** How many unscored rows one run will pay Kimi for. Each call is ~2-5s, so
 *  this plus the searches is the run's whole time budget. A backlog drains at
 *  CLASSIFY_BUDGET/hour, which is far faster than Reddit produces matches. */
const CLASSIFY_BUDGET = 8;

/** The bar for interrupting the owner's Telegram. Both conditions, not either:
 *  a high-relevance "discussion" thread is interesting and not actionable, and
 *  the whole point of this build is that it produces a small number of threads
 *  worth answering by hand rather than a firehose.
 *  ⚠️ Judgement calls, not measurements. Read `/leads all` against what the
 *  owner actually replied to before moving either. */
const NOTIFY_MIN_RELEVANCE = 70;
const NOTIFY_INTENTS = ["buying"];

/** Never push more than this per run, however good the backlog looks. A first
 *  run against a week-old search window would otherwise fire thirty messages. */
const NOTIFY_BUDGET = 5;

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  return !!header && !!expected && header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();
  const out = {
    searched: 0, found: 0, inserted: 0,
    classified: 0, classify_failed: 0,
    notified: 0,
    errors: [] as string[],
  };

  // ── A. search ─────────────────────────────────────────────────────────────
  const { data: queries, error: qErr } = await sb
    .from("reddit_queries")
    .select("id, query, subreddits")
    .eq("active", true);

  if (qErr) {
    return json({ error: "queries_read_failed", detail: qErr.message }, { status: 500 });
  }

  if (queries?.length) {
    const tok = await redditToken();
    if (!tok.ok) {
      // A dead Reddit credential stops phase A but must not stop B and C —
      // there may be a classify backlog from a previous run worth draining.
      out.errors.push(tok.error);
    } else {
      for (const q of queries) {
        const res = await searchPosts(tok.token, q.query, q.subreddits ?? null);
        out.searched++;
        if (!res.ok) { out.errors.push(`${q.query}: ${res.error}`); continue; }
        out.found += res.posts.length;
        if (!res.posts.length) continue;

        // Dedupe is the UNIQUE index on reddit_id, not a pre-read: two rows
        // arriving from two queries in the same batch would both pass a
        // "have I seen this" check and then collide on insert.
        const rows = res.posts.map((p) => ({
          reddit_id: p.redditId,
          subreddit: p.subreddit,
          author: p.author,
          title: p.title,
          body: p.body,
          permalink: p.permalink,
          posted_at: p.postedAt,
          score: p.score,
          num_comments: p.numComments,
          matched_query: q.query,
        }));

        const { data: ins, error: insErr } = await sb
          .from("reddit_leads")
          .upsert(rows, { onConflict: "reddit_id", ignoreDuplicates: true })
          .select("id");
        if (insErr) { out.errors.push(`insert ${q.query}: ${insErr.message}`); continue; }
        out.inserted += ins?.length ?? 0;
      }
    }
  }

  // ── B. classify ───────────────────────────────────────────────────────────
  const { data: pending, error: pErr } = await sb
    .from("reddit_leads")
    .select("id, subreddit, title, body")
    .is("classified_at", null)
    .order("created_at", { ascending: false })   // freshest first: a week-old
    .limit(CLASSIFY_BUDGET);                     // thread is a cold reply

  if (pErr) out.errors.push(`pending_read: ${pErr.message}`);

  for (const lead of pending ?? []) {
    const v = await classifyLead({
      subreddit: lead.subreddit, title: lead.title, body: lead.body,
    });

    if (!v.ok) {
      out.classify_failed++;
      // Stamp classified_at even on failure, or this row is retried forever
      // and pins the budget — the same starvation shape the winback candidate
      // window hit with dead push tokens. classify_error is the audit trail.
      const { error } = await sb.from("reddit_leads")
        .update({ classified_at: new Date().toISOString(), classify_error: v.error })
        .eq("id", lead.id);
      if (error) out.errors.push(`classify_mark ${lead.id}: ${error.message}`);
      continue;
    }

    const { error } = await sb.from("reddit_leads").update({
      classified_at: new Date().toISOString(),
      relevance: v.verdict.relevance,
      intent: v.verdict.intent,
      need: v.verdict.need,
      sub_policy: v.verdict.subPolicy,
      draft_reply: v.verdict.draftReply,
      classify_error: null,
    }).eq("id", lead.id);
    if (error) { out.errors.push(`classify_write ${lead.id}: ${error.message}`); continue; }
    out.classified++;
  }

  // ── C. notify ─────────────────────────────────────────────────────────────
  const { data: ready, error: rErr } = await sb
    .from("reddit_leads")
    .select("id, subreddit, title, permalink, relevance, intent, need, sub_policy, draft_reply, posted_at")
    .is("notified_at", null)
    .not("classified_at", "is", null)
    .gte("relevance", NOTIFY_MIN_RELEVANCE)
    .in("intent", NOTIFY_INTENTS)
    .order("relevance", { ascending: false })
    .limit(NOTIFY_BUDGET);

  if (rErr) out.errors.push(`ready_read: ${rErr.message}`);

  for (const lead of ready ?? []) {
    const restricted = lead.sub_policy === "restricted";
    const html =
      `🧵 <b>Reddit lead</b> · r/${esc(lead.subreddit)} · ${lead.relevance}/100\n` +
      `<b>${esc(lead.title)}</b>\n` +
      `${esc(lead.need ?? "")}\n\n` +
      (restricted
        ? `⚠️ <i>Subreddit reads as restricted — the draft below deliberately ` +
          `carries no product mention. Check the sub's rules before posting ` +
          `anything promotional.</i>\n\n`
        : "") +
      `<b>Draft</b> (yours to edit — nothing is posted for you):\n` +
      `<blockquote>${esc(lead.draft_reply ?? "")}</blockquote>\n\n` +
      `${esc(lead.permalink)}`;

    const sent = await sendMessageWithId(html, {
      replyMarkup: {
        inline_keyboard: [[
          { text: "✅ Replied", callback_data: `lead:done:${lead.id}` },
          { text: "🚫 Skip", callback_data: `lead:skip:${lead.id}` },
        ]],
      },
    });

    // Only stamp notified_at when Telegram ACCEPTED it. A failed send that
    // marked the row would lose the lead silently, which is the whole class of
    // bug this repo keeps finding in "claim then act" orderings.
    if (sent == null) { out.errors.push(`send ${lead.id}: telegram refused`); continue; }

    const { error } = await sb.from("reddit_leads")
      .update({ notified_at: new Date().toISOString(), status: "notified" })
      .eq("id", lead.id);
    if (error) out.errors.push(`notify_mark ${lead.id}: ${error.message}`);
    out.notified++;
  }

  return json(out);
});
