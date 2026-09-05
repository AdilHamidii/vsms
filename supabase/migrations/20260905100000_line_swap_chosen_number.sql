-- Let a swap land on a number the USER chose — in any country we sell.
--
-- Until now `swap-line-number` picked the first free number in the old one's
-- area code and the client never saw a choice. Owner decision 2026-09-05: the
-- "Change number" flow now walks the same country → city → number picker the
-- store uses, and the paywall (price + balance) comes LAST. So the cutover
-- has to be able to move the line's country, locality, number type and the
-- wholesale it now costs us.
--
-- ── Why DROP + CREATE rather than CREATE OR REPLACE ────────────────────────
-- `create or replace` with a different argument list creates an OVERLOAD, and
-- PostgREST then refuses the RPC with "could not choose the best candidate
-- function". The four new arguments carry defaults, so the deployed 4-argument
-- call from an older bundle still resolves against this one definition.
--
-- ── What moves and what does not ───────────────────────────────────────────
-- `country_code` / `number_type` / `locality` / `monthly_cost_cents` follow the
-- new number when the caller names a country; a legacy call (no country) leaves
-- all four alone. `locality` is REPLACED, not coalesced, whenever a country is
-- given — a country-wide search legitimately has none, and keeping the old
-- city under a new country would be a lie the next swap searches on.
-- Everything else is unchanged: the row is still mutated in place, `status`
-- never moves, and `provider_voice_attached` still goes false so
-- `provisionLineVoice` re-attaches the new number.

drop function if exists public.complete_line_swap(uuid, text, text, text);

create function public.complete_line_swap(
  p_swap uuid,
  p_new_e164 text,
  p_new_number_id text,
  p_order_id text,
  p_country text default null,
  p_number_type text default null,
  p_locality text default null,
  p_monthly_cost_cents integer default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line uuid;
  v_n    integer;
begin
  if p_swap is null or p_new_e164 is null then return false; end if;

  -- The claim. Anything but exactly one row means another worker already
  -- settled this swap, and settling it twice would release the wrong number.
  update public.line_number_swaps
     set state = 'done',
         new_e164 = p_new_e164,
         new_provider_number_id = p_new_number_id,
         completed_at = now()
   where id = p_swap and state = 'claimed'
  returning line_id into v_line;
  get diagnostics v_n = row_count;
  if v_n <> 1 then return false; end if;

  -- `provider_voice_attached` goes FALSE because the new number's voice is
  -- not pointed at the connection yet. `provisionLineVoice` keys its repair
  -- step on exactly this flag, so leaving it true would mean the line never
  -- rings again and nothing would ever notice.
  update public.phone_lines
     set e164 = p_new_e164,
         provider_number_id = p_new_number_id,
         provider_order_id = coalesce(p_order_id, provider_order_id),
         country_code = coalesce(upper(p_country), country_code),
         number_type = coalesce(p_number_type, number_type),
         locality = case when p_country is not null then p_locality else locality end,
         monthly_cost_cents = coalesce(p_monthly_cost_cents, monthly_cost_cents),
         provider_voice_attached = false,
         updated_at = now()
   where id = v_line;

  return true;
end;
$$;

revoke execute on function public.complete_line_swap(uuid, text, text, text, text, text, text, integer)
  from public, anon, authenticated;
