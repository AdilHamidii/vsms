// Shared presentation helpers for the Telegram ops bot.
//
// Every timestamp the bot prints goes through here, in EUROPE/PARIS — the
// owner reads the bot from France, and until 2026-08-21 every command and
// alert printed raw UTC ISO strings (or bare HH:MM with the "UTC" only in a
// source comment). A time the reader has to convert in their head is a time
// they get wrong at 1am.
//
// Deno's Intl handles the zone and DST natively (verified: 23:16Z → "01:16"
// on a CEST date), so no library is needed.

export const OPS_TZ = "Europe/Paris";

const DT_FULL = new Intl.DateTimeFormat("en-GB", {
  timeZone: OPS_TZ, weekday: "short", day: "numeric", month: "short",
  hour: "2-digit", minute: "2-digit", hour12: false,
});
const DT_TIME = new Intl.DateTimeFormat("en-GB", {
  timeZone: OPS_TZ, hour: "2-digit", minute: "2-digit", hour12: false,
});
const DT_DAY = new Intl.DateTimeFormat("en-GB", {
  timeZone: OPS_TZ, weekday: "short", day: "numeric", month: "short",
});
const DT_DATE = new Intl.DateTimeFormat("en-GB", {
  timeZone: OPS_TZ, day: "numeric", month: "short", year: "numeric",
});

/** ICU builds differ on whether the weekday takes a comma ("Sat, 22 Aug" on
 *  the edge runtime, "Sat 22 Aug" locally). Normalise so renderings are
 *  byte-stable across environments and the fixtures match production. */
function noWeekdayComma(s: string): string {
  return s.replace(/^([A-Za-z]{3}),/, "$1");
}

function toDate(v: string | number | Date | null | undefined): Date | null {
  if (v == null || v === "") return null;
  const d = v instanceof Date ? v : new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

/** "Sat 22 Aug, 01:16" (Paris). Empty string for a null/invalid input. */
export function parisFull(v: string | number | Date | null | undefined): string {
  const d = toDate(v);
  return d ? noWeekdayComma(DT_FULL.format(d)) : "";
}

/** "01:16" (Paris). */
export function parisTime(v: string | number | Date | null | undefined): string {
  const d = toDate(v);
  return d ? DT_TIME.format(d) : "";
}

/** "Sat 22 Aug" (Paris). */
export function parisDay(v: string | number | Date | null | undefined): string {
  const d = toDate(v);
  return d ? noWeekdayComma(DT_DAY.format(d)) : "";
}

/** "22 Aug 2026" (Paris) — for dates far enough out that the weekday is noise. */
export function parisDate(v: string | number | Date | null | undefined): string {
  const d = toDate(v);
  return d ? DT_DATE.format(d) : "";
}

/** Smart timestamp: time-only if it is today (Paris), "Sat 22 Aug, 01:16" if
 *  within ~a week either side, else "22 Aug 2026". Use this for lists. */
export function parisSmart(
  v: string | number | Date | null | undefined, now: Date = new Date(),
): string {
  const d = toDate(v);
  if (!d) return "";
  if (DT_DAY.format(d) === DT_DAY.format(now)) return `today ${DT_TIME.format(d)}`;
  const diffDays = Math.abs(d.getTime() - now.getTime()) / 86_400_000;
  return diffDays <= 8 ? noWeekdayComma(DT_FULL.format(d)) : DT_DATE.format(d);
}

/** Compact duration: "42s", "3m", "2h 05m", "3d 4h". Never negative. */
export function duration(seconds: number | null | undefined): string {
  const s = Math.max(0, Math.round(seconds ?? 0));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${String(m % 60).padStart(2, "0")}m`;
  const d = Math.floor(h / 24);
  return `${d}d ${h % 24}h`;
}

/** "3m ago" / "2h 05m ago" / "just now". Empty for null. */
export function ago(v: string | number | Date | null | undefined, now: Date = new Date()): string {
  const d = toDate(v);
  if (!d) return "";
  const s = (now.getTime() - d.getTime()) / 1000;
  if (s < 30) return "just now";
  return `${duration(s)} ago`;
}

/** "in 6h 33m" / "in 3d 4h" / "overdue by 12m". Empty for null. */
export function until(v: string | number | Date | null | undefined, now: Date = new Date()): string {
  const d = toDate(v);
  if (!d) return "";
  const s = (d.getTime() - now.getTime()) / 1000;
  return s >= 0 ? `in ${duration(s)}` : `overdue by ${duration(-s)}`;
}

/** "$12.34" — always two decimals, never "-0.00". */
export function usd(v: number | null | undefined): string {
  const n = Math.abs(v ?? 0) < 0.005 ? 0 : (v ?? 0);
  return `${n < 0 ? "-" : ""}$${Math.abs(n).toFixed(2)}`;
}

/** "42%" from a 0..1 or 0..100 input (pass `ofHundred` for the latter). */
export function pct(v: number | null | undefined, ofHundred = false): string {
  if (v == null || !Number.isFinite(v)) return "—";
  return `${Math.round(ofHundred ? v : v * 100)}%`;
}

/** "3 of 7" ratio helper with a percentage when n ≥ 5, raw pair otherwise —
 *  the repo's standing rule: a percentage off a tiny sample wears confidence
 *  it has not earned. */
export function ratio(num: number, den: number): string {
  if (den <= 0) return "none yet";
  return den >= 5 ? `${num}/${den} (${Math.round((num / den) * 100)}%)` : `${num} of ${den}`;
}

/** Plural helper: n("line", 1) → "1 line", n("line", 3) → "3 lines". */
export function n(word: string, count: number, plural = `${word}s`): string {
  return `${count} ${count === 1 ? word : plural}`;
}

/** Unicode bar for a 0..1 share, 8 cells wide: "▰▰▰▱▱▱▱▱". */
export function bar(share: number, width = 8): string {
  const filled = Math.max(0, Math.min(width, Math.round((share || 0) * width)));
  return "▰".repeat(filled) + "▱".repeat(width - filled);
}

/** Footer stamped on every command reply: "🕒 Fri 21 Aug, 18:43 Paris". */
export function stamp(now: Date = new Date()): string {
  return `🕒 ${noWeekdayComma(DT_FULL.format(now))} Paris`;
}
