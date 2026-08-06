// Resolving WHICH line a request is about, now that a user can hold several.
//
// 🔴 THE BUG THIS EXISTS TO KILL. Every caller used to do:
//
//     .from("phone_lines").select(...).eq("user_id", userId)
//     .in("status", [...]).maybeSingle()
//
// which was correct while `phone_lines_one_live_per_user` guaranteed at most
// one. That index was dropped so credits can rent several numbers — and
// `.maybeSingle()` ERRORS when more than one row matches. So the moment a user
// rented a second number, sending a text, placing a call and minting a voice
// token all began returning `lookup_failed` (HTTP 500). Not the wrong line: no
// line at all.
//
// Two rules, both load-bearing:
//
//  1. A line id from the client is a RESOURCE SELECTOR and is never trusted.
//     It is always re-scoped with `.eq("user_id", userId)`, so passing someone
//     else's id returns nothing rather than acting on their number.
//
//  2. With no id supplied the pick must be DETERMINISTIC — oldest first, by
//     `created_at` — so an older client that knows nothing about multiple lines
//     keeps talking to the same number every time instead of hopping between
//     them as rows change.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

/** Statuses that may send, call, or mint a token. */
export const ACTING_STATUSES = ["active", "grace", "past_due", "suspended"];

/** Statuses that occupy a rental slot, including ones still settling. */
export const OCCUPYING_STATUSES = [
  "provisioning", "active", "grace", "past_due", "suspended", "releasing",
];

export interface ResolvedLine {
  id: string;
  e164: string | null;
  status: string;
}

/**
 * The line this request is about.
 *
 * `requestedId` is optional so a client that predates multiple numbers keeps
 * working unchanged. Returns null when the user has no matching line, or when
 * the requested id is not theirs — the caller cannot tell those apart, which is
 * deliberate: "not yours" and "does not exist" must look identical or the
 * endpoint becomes an id oracle.
 */
export async function resolveCallerLine(
  sb: SupabaseClient,
  userId: string,
  requestedId: string | null | undefined,
  statuses: string[] = ACTING_STATUSES,
  columns = "id, e164, status",
): Promise<ResolvedLine | null> {
  let q = sb.from("phone_lines").select(columns)
    .eq("user_id", userId)
    .in("status", statuses);

  if (requestedId) {
    // Ownership is re-asserted by the .eq above; this only narrows.
    q = q.eq("id", requestedId);
  }

  // `.limit(1)` rather than `.maybeSingle()` alone: maybeSingle throws on more
  // than one row, which is exactly the state we now expect.
  const { data, error } = await q
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (error || !data) return null;
  return data as unknown as ResolvedLine;
}

/** How many rental slots this user currently occupies. */
export async function countOccupiedLines(
  sb: SupabaseClient,
  userId: string,
): Promise<number> {
  const { count } = await sb.from("phone_lines")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .in("status", OCCUPYING_STATUSES);
  return count ?? 0;
}
