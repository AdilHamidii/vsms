-- Let `record_line_voice_binding` persist the outbound voice profile.
--
-- 🔴 `phone_lines.provider_voice_profile_id` has existed since the FIRST line
-- migration and nothing has ever written it: both provisioning paths pass
-- `p_voice_profile: null` and this function had no parameter for it at all.
-- Telnyx requires an Outbound Voice Profile on a connection before it will
-- place any outbound call, so that column being empty was a SECOND, independent
-- reason calling never worked — hidden behind the invalid SIP username, and
-- equally silent.
--
-- That is the third column in this feature to ship with no writer, after
-- `line_subscriptions` (six updaters, no INSERT) and `line_threads.blocked`.
-- The rule the repo already states is the right one: when a migration adds a
-- column, grep for something that WRITES it.
--
-- ⚠️ The new parameter is added LAST and defaulted, so the existing 4-argument
-- calls keep resolving. Adding it in the middle would silently rebind
-- positional callers.

create or replace function public.record_line_voice_binding(
  p_line          uuid,
  p_connection    text default null,
  p_credential    text default null,
  p_attached      boolean default null,
  p_voice_profile text default null
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.phone_lines
     set provider_connection_id    = coalesce(p_connection, provider_connection_id),
         provider_credential_id    = coalesce(p_credential, provider_credential_id),
         provider_voice_attached   = coalesce(p_attached, provider_voice_attached),
         -- coalesce, never overwrite with null: each call to this function
         -- carries exactly one binding and must leave the others untouched.
         provider_voice_profile_id = coalesce(p_voice_profile, provider_voice_profile_id),
         updated_at = now()
   where id = p_line;
  return found;
end;
$$;

revoke execute on function public.record_line_voice_binding(uuid, text, text, boolean, text)
  from public, anon, authenticated;

-- The 4-argument version MUST go. `create or replace` with a new trailing
-- parameter creates an OVERLOAD rather than replacing, and a call supplying the
-- original four named arguments then matches both — PostgREST answers
-- "function is not unique" and every voice binding stops persisting. Verified:
-- pg_proc held 2 rows for this name until this drop.
drop function if exists public.record_line_voice_binding(uuid, text, text, boolean);
