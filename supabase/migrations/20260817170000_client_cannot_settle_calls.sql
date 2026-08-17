-- 🔴 THE CLIENT COULD SETTLE ITS OWN LIVE CALL TO ZERO AND KEEP TALKING.
--
-- Found by audit 2026-08-17, introduced by 20260817090000 the same day. The
-- chain was three steps, each defensible alone:
--
--   1. `report-line-call` takes `status` from the REQUEST BODY, checked only
--      against the enum.
--   2. `attach_line_call_session` saw a terminal-unconnected status and called
--      `settle_call_claim(p_call, 0, ...)`.
--   3. `settle_call_claim` refunds the WHOLE credit block when billed seconds
--      are zero, and sets `allowance_settled = true`.
--   4. `sync-telnyx-cdr` sweeps `.eq("allowance_settled", false)`, so the real
--      detail record could never correct it.
--
-- Exploit: dial Kenya (4 credits reserved), and ten seconds in — call still up,
-- because `begin-line-call` is deliberately NOT on the ring path — POST
-- `{call_id, status:"canceled"}`. All credits refunded, the row frozen against
-- correction, and the call continues for as long as Telnyx allows. Repeatable.
-- The same request returns the 120-second domestic reservation on every call,
-- i.e. an unlimited allowance.
--
-- 20260817090000's own reasoning was: "canceled/failed/busy/missed mean no leg
-- was ever answered BY DEFINITION". That is true of a PROVIDER-reported status.
-- It is false of a client-reported one, and this function only ever receives
-- the latter — which made the device authoritative over money on precisely the
-- path that file said it must never be.
--
-- ── The fix, and what it costs ────────────────────────────────────────────
-- The client's report is now ADVISORY: it records what happened for the UI —
-- status, ended_at, duration, session ids — and settles NOTHING. Money moves
-- only on provider evidence (`sync-telnyx-cdr`, every 10 min) or on the
-- `settle_stale_calls` backstop.
--
-- The cost is that a genuinely failed call holds its reservation until a sweep
-- runs instead of being refunded instantly. That is the right trade: a short
-- hold on a real failure is a UX cost, and an instant refund on a live call is
-- a money loss that also destroys the evidence needed to detect it.
--
-- ⚠️ DO NOT "restore the fast refund" by trusting any client-supplied field.
-- The device can set every one of them. If the instant refund is wanted back,
-- it has to come from asking Telnyx, not from asking the phone.

create or replace function public.attach_line_call_session(
  p_user uuid,
  p_call uuid,
  p_session text,
  p_leg text default null,
  p_status public.line_call_status default null,
  p_answered_at timestamptz default null,
  p_duration_seconds integer default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid; v_settled boolean; v_existing text;
  v_status public.line_call_status; v_terminal boolean;
  v_final public.line_call_status;
begin
  select user_id, allowance_settled, provider_call_session_id, status
    into v_owner, v_settled, v_existing, v_status
    from public.line_calls where id = p_call for update;
  if not found or v_owner is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_call');
  end if;
  if v_owner <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'unknown_call');
  end if;
  if v_settled then
    return jsonb_build_object('ok', true, 'reason', 'already_settled');
  end if;
  if v_existing is not null and p_session is not null and v_existing <> p_session then
    return jsonb_build_object('ok', false, 'reason', 'session_conflict');
  end if;

  v_terminal := v_status in ('completed','missed','busy','failed','canceled');

  update public.line_calls
     set provider_call_session_id = coalesce(p_session, provider_call_session_id),
         provider_call_leg_id     = coalesce(p_leg, provider_call_leg_id),
         -- Once terminal, the status and the duration are FROZEN. A second
         -- report cannot turn a completed call into a canceled one, nor a
         -- real duration into 0.
         status                   = case when v_terminal then status
                                         else coalesce(p_status, status) end,
         answered_at              = coalesce(answered_at, p_answered_at),
         duration_seconds         = case when v_terminal then duration_seconds
                                         else coalesce(p_duration_seconds, duration_seconds) end,
         ended_at = case
           when v_terminal then ended_at
           when p_status in ('completed','missed','busy','failed','canceled')
             then coalesce(ended_at, now())
           else ended_at end
   where id = p_call;

  select status into v_final from public.line_calls where id = p_call;

  -- NO SETTLEMENT HERE. See the header. `allowance_settled` stays false so the
  -- CDR sweep still owns this row, which is the whole point: the client just
  -- told us its version of events, and the provider has not yet told us its.
  return jsonb_build_object(
    'ok', true,
    'reason', case when v_terminal then 'already_terminal' else 'attached' end,
    'settles', 'provider');
end;
$$;

revoke execute on function public.attach_line_call_session(
  uuid, uuid, text, text, public.line_call_status, timestamptz, integer)
  from public, anon, authenticated;

-- ── Fail closed on +1 ranges we do not actually price ─────────────────────
--
-- `voice_rates` had ONE row for '1' ("United States & Canada", covered by the
-- minute allowance at an assumed $0.01/min). Longest-prefix matching means that
-- row also answered for every other NANP country and for US premium ranges:
--
--   +1242 Bahamas, +1809 Dominican Republic, +1876 Jamaica, +1345 Cayman …
--   +1900 / +1976  US premium-rate ("information provider") ranges
--
-- all resolved to `covered_by_allowance = true`, so `begin-line-call` billed
-- them against the 100-minute allowance and the dialer told the user
-- "Included in your minutes."
--
-- Caribbean NANP countries are separate ISO2 codes, so Telnyx's
-- `whitelisted_destinations` (US/CA/PR/VI) should already reject them — that
-- design is why this has not already cost money. But +1900 and +1976 are ISO2
-- **US**: they are INSIDE the whitelist and the permission gate offers no
-- protection at all. Premium ranges bill $1–5/min against $8.49/month of
-- subscription revenue, and they are the single most-targeted family in
-- International Revenue Share Fraud.
--
-- Relying on a provider-side allowlist as the sole control for a whole class of
-- destinations is also exactly the "one gate, silently" shape this repo keeps
-- paying for. These rows make the refusal OURS and explicit: `enabled = false`
-- and `covered_by_allowance = false`, so `begin_intl_call_claim` returns
-- `destination_unavailable` before any money moves, and the client renders them
-- as unavailable rather than as included minutes.
insert into public.voice_rates
  (prefix, iso2, label, wholesale_usd_per_min, covered_by_allowance, enabled)
values
  -- US/CA premium and special ranges. ISO2 stays 'US' because that is what they
  -- are; `enabled = false` is what stops them.
  ('1900', 'US', 'US premium rate',        5.00, false, false),
  ('1976', 'US', 'US premium rate',        5.00, false, false),
  ('1700', 'US', 'US special services',    5.00, false, false),
  ('1500', 'US', 'US personal comms',      5.00, false, false),
  ('1600', 'CA', 'Canada special',         5.00, false, false),
  -- The NANP Caribbean. Each is its own country at $0.15–0.40/min wholesale and
  -- none is in `voice_dial_destinations()`.
  ('1242', 'BS', 'Bahamas',                0.40, false, false),
  ('1246', 'BB', 'Barbados',               0.40, false, false),
  ('1264', 'AI', 'Anguilla',               0.40, false, false),
  ('1268', 'AG', 'Antigua & Barbuda',      0.40, false, false),
  ('1284', 'VG', 'British Virgin Islands', 0.40, false, false),
  ('1345', 'KY', 'Cayman Islands',         0.40, false, false),
  ('1441', 'BM', 'Bermuda',                0.40, false, false),
  ('1473', 'GD', 'Grenada',                0.40, false, false),
  ('1649', 'TC', 'Turks & Caicos',         0.40, false, false),
  ('1664', 'MS', 'Montserrat',             0.40, false, false),
  ('1721', 'SX', 'Sint Maarten',           0.40, false, false),
  ('1758', 'LC', 'Saint Lucia',            0.40, false, false),
  ('1767', 'DM', 'Dominica',               0.40, false, false),
  ('1784', 'VC', 'St Vincent & Grenadines',0.40, false, false),
  ('1809', 'DO', 'Dominican Republic',     0.40, false, false),
  ('1829', 'DO', 'Dominican Republic',     0.40, false, false),
  ('1849', 'DO', 'Dominican Republic',     0.40, false, false),
  ('1868', 'TT', 'Trinidad & Tobago',      0.40, false, false),
  ('1869', 'KN', 'St Kitts & Nevis',       0.40, false, false),
  ('1876', 'JM', 'Jamaica',                0.40, false, false),
  ('1658', 'JM', 'Jamaica',                0.40, false, false),
  -- ── Premium sub-ranges INSIDE countries we do sell ─────────────────────
  -- `voice_rates`' own header promised that longest-match lets a premium
  -- sub-range override its country "without a special case", and gave '35191'
  -- as the example. Not one override row had ever been written, and then all
  -- 50 countries were enabled — so +4470 (UK personal numbering, $0.30–1.50/min
  -- wholesale and the classic European IRSF target) billed at the UK landline
  -- rate of 0.75 cr/min. One 20-minute call there can lose more than a month of
  -- subscription revenue.
  ('4470',  'GB', 'UK personal numbering', 1.50, false, false),
  ('4476',  'GB', 'UK personal numbering', 1.50, false, false),
  ('44844', 'GB', 'UK service number',     1.50, false, false),
  ('44870', 'GB', 'UK service number',     1.50, false, false),
  ('44871', 'GB', 'UK service number',     1.50, false, false),
  ('44872', 'GB', 'UK service number',     1.50, false, false),
  ('44873', 'GB', 'UK service number',     1.50, false, false),
  ('44909', 'GB', 'UK premium rate',       1.50, false, false),
  ('49900', 'DE', 'Germany premium rate',  1.50, false, false),
  ('39899', 'IT', 'Italy premium rate',    1.50, false, false),
  ('39144', 'IT', 'Italy premium rate',    1.50, false, false),
  ('34803', 'ES', 'Spain premium rate',    1.50, false, false),
  ('34806', 'ES', 'Spain premium rate',    1.50, false, false),
  ('34807', 'ES', 'Spain premium rate',    1.50, false, false),
  -- ⚠️ NOT '3519'. That was the first attempt and it was WRONG: Portuguese
  -- MOBILES are 91/92/93/96, so '3519' would have refused most of Portugal
  -- while claiming to block premium rate. Portuguese premium is 760/761/762,
  -- shared-cost is 707/808. Caught by querying `voice_rate_for('+351912345678')`
  -- after applying — a prefix table is exactly the kind of change that looks
  -- right in review and is wrong against real numbering plans.
  ('351760','PT', 'Portugal premium rate', 1.50, false, false),
  ('351761','PT', 'Portugal premium rate', 1.50, false, false),
  ('351762','PT', 'Portugal premium rate', 1.50, false, false),
  ('351707','PT', 'Portugal shared cost',  1.50, false, false),
  ('351808','PT', 'Portugal shared cost',  1.50, false, false),
  ('33899', 'FR', 'France premium rate',   1.50, false, false),
  ('358600','FI', 'Finland premium rate',  1.50, false, false),
  ('4190',  'CH', 'Switzerland premium',   1.50, false, false),
  ('4390',  'AT', 'Austria premium rate',  1.50, false, false)
on conflict (prefix) do nothing;

comment on table public.voice_rates is
  'Per-prefix call pricing. Longest prefix wins, so a premium sub-range row '
  'overrides its country row. A row with enabled = false is a REFUSAL, not a '
  'missing price: begin_intl_call_claim returns destination_unavailable before '
  'charging. Wholesale figures on disabled rows are indicative only — they '
  'exist to document why the range is refused, and nothing bills from them.';
