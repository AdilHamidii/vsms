// Moonshot / Kimi adapter — used for ONE job: scoring a Reddit thread and
// drafting a reply the OWNER edits and posts by hand.
//
// ⚠️ The `moonshot-v1-*` model family sunset 2026-08-31. Anything still naming
// moonshot-v1-8k is dead code, not a fallback. Current ids are kimi-k3
// (flagship), kimi-k2.6 (value) and kimi-k2.7-code-highspeed. This is
// classification, not writing, so k2.6 is the right tier — re-read
// https://platform.kimi.ai/docs/overview rather than trusting this line, the
// lineup has moved twice in three months.

const BASE = "https://api.moonshot.ai/v1";
const MODEL = "kimi-k2.6";

export interface LeadInput {
  subreddit: string;
  title: string;
  body: string | null;
}

export interface LeadVerdict {
  relevance: number;          // 0..100
  intent: "buying" | "discussion" | "support" | "irrelevant";
  need: string;
  subPolicy: "permissive" | "restricted" | "unknown";
  draftReply: string;
}

/** What the model is allowed to say about vSMS.
 *
 *  🔴 Three product truths are pinned here on purpose, because a drafted reply
 *  that oversells is worse than no reply: Reddit punishes it, and this app's
 *  ONLY organic review is already someone angry about a promise that did not
 *  hold.
 *   • Temp SMS delivers roughly a quarter of the time per attempt. Say so.
 *   • Outbound texting works NANP→NANP only. Never imply worldwide texting.
 *   • No supplier is ever named — the app must not advertise that it resells
 *     someone else's inventory. (Standing owner rule, absolute.)
 *  And the disclosure line is not optional: an undisclosed recommendation of
 *  your own product is the exact thing that gets a domain banned. */
const SYSTEM = `
You triage Reddit threads for the founder of vSMS, a small iOS app.

WHAT THE APP ACTUALLY IS (do not embellish):
- A rented US/Canada phone number the user keeps: calls, texts, app codes.
  Monthly or yearly subscription.
- Temporary phone numbers for receiving one verification code, paid in credits.
- Temporary e-mail addresses, mostly free.
- Outbound texting works between US/Canada numbers ONLY. It does not work to
  Europe or anywhere else, and you must never imply otherwise.
- Temporary numbers receive a code roughly a quarter of the time per attempt.
  Failed attempts are refunded. This is a real limitation — state it plainly
  if the thread is about temp numbers.
- Never name or allude to any upstream supplier, carrier wholesaler or
  inventory provider. Never quote a price.

YOUR JOB, per thread, is to return JSON with exactly these keys:
  relevance   integer 0-100. How likely is it that this person is actively
              looking for something vSMS sells? 80+ means they are asking for
              a recommendation right now. Below 40 means do not bother.
  intent      one of: buying, discussion, support, irrelevant
              buying     = asking for a recommendation or a tool
              discussion = talking about the category, not shopping
              support    = having a problem with some other product
              irrelevant = unrelated, or someone promoting their own thing
  need        one short sentence: what this person actually wants.
  sub_policy  one of: permissive, restricted, unknown. Your best read of
              whether that subreddit tolerates a founder answering with a
              disclosed mention. Default to "restricted" when unsure — the
              cost of guessing wrong is a ban.
  draft_reply a reply the FOUNDER will edit and post from their own account.

RULES FOR draft_reply — all of them, every time:
1. Answer the person's actual question FIRST, usefully, even if that means
   recommending something other than vSMS. If nothing about vSMS fits, say so
   and leave the mention out entirely.
2. Disclose the connection in plain words: "I built one of these" / "full
   disclosure, this is mine". Never hide it.
3. Name the real limitation that applies to their case. Honesty is the whole
   strategy here, not a disclaimer.
4. Under 120 words. Lowercase-ish, conversational, no marketing voice, no
   bullet lists, no emoji, no links unless they asked for one.
5. If sub_policy is "restricted", draft the reply WITHOUT any product mention
   at all — just the genuinely useful answer.
Return JSON only.
`.trim();

/** Classify one thread. Returns null on any failure — the caller records the
 *  error on the row and moves on, because one unparseable response must never
 *  stall the batch behind it. */
export async function classifyLead(
  lead: LeadInput,
): Promise<{ ok: true; verdict: LeadVerdict } | { ok: false; error: string }> {
  const key = Deno.env.get("MOONSHOT_API_KEY");
  if (!key) return { ok: false, error: "moonshot_key_missing" };

  const user = [
    `subreddit: r/${lead.subreddit}`,
    `title: ${lead.title}`,
    `body: ${(lead.body ?? "").slice(0, 2500) || "(no body)"}`,
  ].join("\n");

  let resp: Response;
  try {
    resp = await fetch(`${BASE}/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        temperature: 0.3,
        // JSON mode. Without it the model wraps the object in prose often
        // enough that the parse below becomes the failure path, not the guard.
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: SYSTEM },
          { role: "user", content: user },
        ],
      }),
    });
  } catch (e) {
    return { ok: false, error: `moonshot_unreachable: ${e}` };
  }

  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    return { ok: false, error: `moonshot_${resp.status}: ${body.slice(0, 200)}` };
  }

  // deno-lint-ignore no-explicit-any
  const j = await resp.json().catch(() => null) as any;
  const content = j?.choices?.[0]?.message?.content;
  if (typeof content !== "string") return { ok: false, error: "moonshot_malformed" };

  // deno-lint-ignore no-explicit-any
  let parsed: any;
  try { parsed = JSON.parse(content); } catch {
    return { ok: false, error: `moonshot_unparseable: ${content.slice(0, 120)}` };
  }

  const intents = ["buying", "discussion", "support", "irrelevant"];
  const policies = ["permissive", "restricted", "unknown"];
  const rel = Number(parsed?.relevance);

  return {
    ok: true,
    verdict: {
      // Clamp rather than reject: a model returning 120 is still telling us
      // "very relevant", and the column has a 0..100 check constraint that
      // would otherwise fail the whole write.
      relevance: Number.isFinite(rel) ? Math.max(0, Math.min(100, Math.round(rel))) : 0,
      intent: intents.includes(parsed?.intent) ? parsed.intent : "irrelevant",
      need: String(parsed?.need ?? "").slice(0, 300),
      // Unknown policy defaults to the CAUTIOUS value, matching the prompt.
      subPolicy: policies.includes(parsed?.sub_policy) ? parsed.sub_policy : "restricted",
      draftReply: String(parsed?.draft_reply ?? "").slice(0, 2000),
    },
  };
}
