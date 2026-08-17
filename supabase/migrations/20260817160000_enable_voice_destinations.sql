-- Turn on international calling: the PRICE half.
--
-- Owner decision 2026-08-17: enable all 50 rated destinations. The permission
-- half lives at Telnyx (`whitelisted_destinations` on each line's outbound
-- voice profile) and is driven from THIS table by `sync-voice-destinations`,
-- so the two gates cannot drift — which is the failure `begin_intl_call_claim`
-- was written to refuse:
--
--     A PRICE IS NOT PERMISSION.
--
-- Enabling here alone would let a user spend credits on a call Telnyx rejects.
-- `settle_call_claim` refunds the whole block when `billed_seconds <= 0`, so
-- the money comes back, but the user still gets a failed call — which is worse
-- than today's honest refusal. Deploy the sync in the same change.

-- ── The price half ────────────────────────────────────────────────────────
update public.voice_rates set enabled = true, updated_at = now()
 where not enabled;

-- ── The one definition of "where may a line dial?" ────────────────────────
-- Both callers read this: `sync-voice-destinations` (patching existing
-- profiles) and `mint-line-token` (creating new ones). A constant duplicated
-- across files WILL drift — this repo has paid for that with MAX_WHOLESALE_CENTS
-- and CREDIT_DIVISOR already — and here the drift is silent in the worst
-- direction: a profile created without a country simply rejects the call.
--
-- 🔴 THE NANP ROW IS NOT "US". `voice_rates` carries ONE row for +1, labelled
-- "United States & Canada", with `iso2 = 'US'`. Deriving destinations from
-- `iso2` alone would hand Telnyx a list with no `CA` in it — and EVERY line we
-- have sold is a Canadian number whose owner calls Canada. That would break
-- domestic calling for every existing customer while looking like a routine
-- widening. The NANP set matches `_shared/phone.ts`.
create or replace function public.voice_dial_destinations()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct d order by d), array['US','CA'])
    from (
      select unnest(
        case when r.prefix = '1' then array['US','CA','PR','VI']
             else array[r.iso2] end) as d
        from public.voice_rates r
       where r.enabled and r.iso2 is not null
    ) x;
$$;

comment on function public.voice_dial_destinations() is
  'ISO2 destinations a line may dial, derived from voice_rates.enabled. The '
  'ONLY source of truth for Telnyx whitelisted_destinations. Falls back to '
  'US/CA rather than an empty array: an empty whitelist would silently ground '
  'every line, and a fallback that still works beats one that fails closed on '
  'the domestic path the subscription actually sells.';

revoke execute on function public.voice_dial_destinations()
  from public, anon, authenticated;
