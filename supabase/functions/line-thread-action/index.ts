// Block / unblock / report / mark-read for a line thread.
//
// One function rather than four, because they share a single shape: verify the
// caller owns the thread, then call one SECURITY DEFINER RPC. The ownership
// check lives in the RPCs — a thread id is a client-supplied resource selector,
// so it is never taken on trust.
//
// Every write to line_threads is revoked from `authenticated`: RLS is
// row-level and cannot stop a client setting `blocked` on someone else's row,
// or inserting a message with `direction='inbound'` and forging a text from a
// number they do not own. So all of this goes through the service role.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

type Action = "block" | "unblock" | "report" | "read";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { thread_id?: string; action?: Action; reason?: string } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const threadId = body.thread_id ?? "";
  const action = body.action;
  if (!threadId || !action) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  switch (action) {
    case "block":
    case "unblock": {
      const { data, error } = await sb.rpc("set_thread_blocked", {
        p_user: userId, p_thread: threadId, p_blocked: action === "block",
      });
      if (error) return json({ error: "action_failed" }, { status: 500 });
      if (data?.ok !== true) return json({ error: "thread_not_found" }, { status: 404 });
      return json({ ok: true, blocked: data.blocked });
    }

    case "report": {
      // Recorded, not acted on. An automatic block on report would let one tap
      // silence a number the user still wants, and the point of a report is
      // that a human looks at it.
      const { data, error } = await sb.rpc("report_thread", {
        p_user: userId, p_thread: threadId, p_reason: body.reason ?? null,
      });
      if (error) return json({ error: "action_failed" }, { status: 500 });
      if (data?.ok !== true) return json({ error: "thread_not_found" }, { status: 404 });
      return json({ ok: true });
    }

    case "read": {
      const { error } = await sb.rpc("mark_thread_read", {
        p_user: userId, p_thread: threadId,
      });
      if (error) return json({ error: "action_failed" }, { status: 500 });
      return json({ ok: true });
    }

    default:
      return json({ error: "bad_request" }, { status: 400 });
  }
});
