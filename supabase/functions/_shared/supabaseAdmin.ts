import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

let cached: SupabaseClient | null = null;

/** Service-role client. Bypasses RLS — use only inside edge functions, never client-side. */
export function admin(): SupabaseClient {
  if (cached) return cached;
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  cached = createClient(url, key, { auth: { persistSession: false } });
  return cached;
}

/** Decode the caller's user id from the Authorization: Bearer <JWT> header. */
export async function callerUserId(req: Request): Promise<string | null> {
  const authHeader = req.headers.get("authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  const { data, error } = await admin().auth.getUser(token);
  if (error) return null;
  return data.user?.id ?? null;
}
