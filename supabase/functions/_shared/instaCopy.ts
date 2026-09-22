// Instagram draft copy: the themes, the guardrail prompt, and the validator.
//
// 🔴 The prompt and the validator say the SAME things on purpose — defence in
// depth, the shape of scripts/asc-listing-check.py. The prompt is a request;
// the validator is the rule. A caption that fails the validator is never shown
// to the owner as a draft, let alone posted.
//
// Why each rule exists (all standing product rules, see CLAUDE.md):
//  • no prices — the audience spans storefronts billed in different
//    currencies (€3.99 vs ¥600 vs R$24.9); "NO LISTING FIELD MAY QUOTE A PRICE"
//    binds this surface for the same reason;
//  • no supplier names — the app must never advertise that it resells someone
//    else's inventory (owner rule, absolute);
//  • no delivery promises — temp SMS delivers roughly a quarter of attempts,
//    and the app's only organic review is already about a promise not kept;
//  • no outbound-texting promise for US numbers / outside US+CA — US numbers
//    are not 10DLC-registered and non-NANP texting is blocked;
//  • PRIVACY framing only, never "multiple accounts" / evasion — this is
//    posted on Instagram, and Meta enforces against exactly that.

export type PostKind = "screenshot" | "ai";

/** Rotating themes. `key` is what is stored in insta_posts.theme and what
 *  the "avoid the last few" check compares; `brief` goes to the model. */
export const THEMES: ReadonlyArray<{ key: string; brief: string }> = [
  { key: "real_number_private",
    brief: "Keep your real phone number off sign-up forms and out of marketing databases." },
  { key: "throwaway_email_newsletters",
    brief: "Use a throwaway e-mail address for newsletters, coupons and one-off downloads so your real inbox stays clean." },
  { key: "second_number_calls",
    brief: "A second US or Canadian number for calls, so you can hand out a number that is not your personal one (marketplace listings, dating, side projects)." },
  { key: "how_temp_numbers_work",
    brief: "How a temporary number works: pick a service, get a number, the verification text shows up in the app. Be honest that a code does not always arrive." },
  { key: "failed_code_refunded",
    brief: "If a verification code does not arrive, the attempt is refunded — trying again or trying another country costs nothing extra." },
  { key: "spam_calls",
    brief: "Fewer spam calls and texts: give out a second number instead of your own." },
  { key: "trial_signups_email",
    brief: "Signing up for a free trial or a Wi-Fi portal? A temporary e-mail address keeps it from following you around." },
  { key: "privacy_habit",
    brief: "A small everyday privacy habit: not every app or shop needs your real number or e-mail." },
];

/** The system prompt for caption + headline (+ an image prompt for the ai kind). */
export const CAPTION_SYSTEM = `
You write Instagram posts for vSMS, a small privacy-focused iOS app.

WHAT THE APP ACTUALLY IS (do not embellish, do not add features):
1. Temporary phone numbers for RECEIVING SMS verification codes. A code does
   NOT always arrive — roughly a quarter of attempts deliver. A failed attempt
   is refunded.
2. Temporary e-mail addresses.
3. A rented US or Canadian second number the user keeps, for calls and for
   RECEIVING texts.

HARD RULES — every one, every time:
- NO prices, amounts, numbers-with-money-words, or currency symbols/codes of
  any kind. Not "cheap", not "free", not a price.
- NEVER name or hint at any supplier, wholesaler or carrier behind the app.
- NEVER promise a code will arrive. Never say guaranteed, 100%, always works,
  instant, never fails.
- NEVER promise sending texts from a US number, or texting outside the US and
  Canada. Talk about RECEIVING texts and making calls.
- Frame everything as PRIVACY: keeping your real number or e-mail private,
  avoiding spam. NEVER suggest creating multiple or fake accounts, getting
  around verification, evading bans or breaking any platform's rules.
- Friendly, plain, short. No hype, no ALL CAPS, at most two emoji.
- Caption: 2–5 short sentences, then a soft call to action such as
  "vSMS on the App Store", then 3–6 relevant hashtags (e.g. #privacy
  #onlineprivacy #iphoneapps #spamfree). Do not claim a "link in bio" unless
  you phrase it generically ("search vSMS on the App Store").
- Headline: at most 8 words, no hashtags, no emoji, no trailing period. It is
  rendered as large text on the image.

Return JSON only, with exactly these keys:
  headline      string
  caption       string
  image_prompt  string — a description for an image model: a clean, modern,
                photographic or illustrated scene that fits the theme. It must
                ask for NO text, letters, logos, phone UI or brand marks in the
                image, and no identifiable real people's faces up close.
`.trim();

export function captionUserPrompt(theme: { key: string; brief: string }, kind: PostKind): string {
  return [
    `Theme: ${theme.brief}`,
    kind === "screenshot"
      ? "The image will be a real screenshot of the app with your headline above it."
      : "The image will be generated from your image_prompt and carries no text; the headline is only a title for the draft.",
  ].join("\n");
}

/** Every pattern a caption or headline must NOT match. One exported constant
 *  so the list is reviewable in one place. Case-insensitive. */
export const BANNED_PATTERNS: ReadonlyArray<{ reason: string; re: RegExp }> = [
  // Money.
  { reason: "currency_symbol", re: /[$€£¥₹₦₺₪₩฿₫]/ },
  { reason: "currency_code", re: /\b(usd|eur|gbp|jpy|inr|cad|aud|brl|chf|us\$|dollars?|euros?|pounds?|cents?|bucks)\b/i },
  { reason: "price_word_with_digit",
    re: /\d[\d.,]*\s*(\/\s*)?(per|a|each)?\s*(month|mo|year|yr|week|credits?|price|cost|fee)\b|\b(price|cost|costs|fee|only|just|from)\s*[:\-]?\s*\d/i },
  { reason: "price_word", re: /\b(cheap(est|er)?|discount|sale|promo code|free trial)\b/i },
  // "free" is an overpromise: the signup grant is 0 and only ONE lifetime
  // e-mail address costs nothing. The lookbehind spares "spam-free"/#spamfree.
  { reason: "free", re: /(?<![-#\w])free\b/i },
  // Suppliers — never named, never hinted.
  { reason: "supplier",
    re: /\b(5\s*sim|hero[\s-]?sms|sms[\s-]?activate|telnyx|sms[\s-]?pva|sms[\s-]?pool|esim\s*access|twilio|textnow)\b/i },
  // Promises and policy risk.
  { reason: "promise",
    // `100%` sits OUTSIDE the \b group: a trailing \b after "%" never matches
    // before a space, which silently let "100% private" through.
    re: /\b(guarantee[ds]?|always\s+works?|never\s+fails?|instant(ly)?|works\s+every\s+time)\b|\b100\s*%/i },
  { reason: "evasion",
    re: /\b(bypass(es|ing)?|evad(e|es|ing)|get\s+around|circumvent\w*|unlimited\s+accounts?|multiple\s+accounts?|fake\s+accounts?|burner\s+accounts?|ban(s|ned)?|unban\w*|avoid\s+verification)\b/i },
  { reason: "outbound_texting",
    re: /\b(send|text)\s+(anyone|anywhere|worldwide|internationally|abroad)\b|\btext\s+the\s+world\b/i },
];

export interface CaptionDraft {
  headline: string;
  caption: string;
  imagePrompt: string;
}

/** Returns the list of violated rules; empty means the draft passes. */
export function validateDraft(d: CaptionDraft): string[] {
  const hits: string[] = [];
  for (const field of ["headline", "caption"] as const) {
    const text = d[field];
    for (const p of BANNED_PATTERNS) {
      if (p.re.test(text)) hits.push(`${field}:${p.reason}`);
    }
  }
  if (!d.headline.trim()) hits.push("headline:empty");
  if (!d.caption.trim()) hits.push("caption:empty");
  if (d.headline.split(/\s+/).filter(Boolean).length > 10) hits.push("headline:too_long");
  // Instagram's hard caption limit is 2,200 characters.
  if (d.caption.length > 2200) hits.push("caption:too_long");
  return hits;
}

/** Parse the model's JSON into a draft, or null when the shape is wrong. */
export function parseDraft(raw: string): CaptionDraft | null {
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch {
    // Some models wrap JSON in a fence despite response_format.
    const m = /\{[\s\S]*\}/.exec(raw);
    if (!m) return null;
    try { parsed = JSON.parse(m[0]); } catch { return null; }
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const o = parsed as Record<string, unknown>;
  if (typeof o.headline !== "string" || typeof o.caption !== "string") return null;
  return {
    headline: o.headline.trim().replace(/\.$/, ""),
    caption: o.caption.trim(),
    imagePrompt: typeof o.image_prompt === "string" ? o.image_prompt.trim() : "",
  };
}
