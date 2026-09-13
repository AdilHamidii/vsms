// Re-run a PostgREST READ that failed on a transient, before treating the
// failure as real.
//
// Why this exists (measured 2026-09-12): every `* * * * *` pg_cron relay fires
// at second :00, so several edge functions boot together and open their first
// PostgREST call at the same instant. On the free-tier compute PostgREST kills
// part of that burst after ~5s ("Warp server error: Thread killed by timeout
// manager") — 1,229 REST 504s in 24h, 89% of them in seconds 0–2 of the
// minute, ~50/hour around the clock. The queries behind them run in under a
// millisecond. A function that answers 500 on that one read trips the
// watchdog's `relay-http` check, and a page for a stray timeout is the alert
// fatigue this repo records as how the next real outage gets missed.
//
// READS ONLY. A write that timed out may have landed, and retrying it blind
// is exactly the double-spend shape the money paths are built to prevent —
// every write here is idempotent by predicate or wrapped in its own claim, and
// that is where its safety lives, not in a retry.

/** Attempts per read, including the first. The residual 504 rate outside the
 *  :00 burst is ~0.1%, so three attempts make a false page vanishingly rare
 *  without hiding a database that is genuinely down. */
export const READ_ATTEMPTS = 3;

/** Generic over the builder's own result so `data` keeps its inferred row
 *  type; a `{ error }` shape is all it needs. */
export async function readWithRetry<R extends { error: unknown }>(
  run: () => PromiseLike<R>,
): Promise<R> {
  let last = await run();
  for (let attempt = 2; attempt <= READ_ATTEMPTS && last.error; attempt++) {
    await new Promise((r) => setTimeout(r, 1_000 * (attempt - 1)));
    last = await run();
  }
  return last;
}
