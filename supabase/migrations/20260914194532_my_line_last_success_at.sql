-- `my_line` gains `last_success_at`: the most recent moment this line actually
-- WORKED for its subscriber. It exists so the review prompt can include line
-- subscribers, who until now could never be asked — `reviewPromptBlocker()`
-- guards on a temp-SMS/e-mail code arrival, and of 19 line subscribers exactly
-- one ever placed a temp order and none ever received a code.
--
-- Definition (owner decision 2026-09-14): an inbound SMS arriving, OR any call
-- that connected for >= 10s in EITHER direction. Outbound is included
-- deliberately — outbound calling is the proven, heavily-used feature (235
-- calls in September), so an inbound-only signal would exclude most
-- subscribers. The 10s floor drops misdials and voicemail blips.
--
-- Computed, never stamped: the review prompt was broken for three weeks
-- because eligibility was gated on a UserDefaults stamp no real delivery
-- reached. A derived value cannot go stale and cannot be missed.
--
-- `ended_at` (falling back to `answered_at`) rather than `answered_at` so the
-- client's calm floor measures from the END of a call.
--
-- ⚠️ The view stays NOT `security_invoker` — its `where user_id = auth.uid()`
-- IS the security boundary, and SELECT on `phone_lines` is revoked from
-- `authenticated`. CREATE OR REPLACE preserves both that and the grants.
create or replace view public.my_line as
  select
    p.id,
    p.e164,
    p.country_code,
    p.number_type,
    p.status,
    p.current_period_start,
    p.current_period_end,
    p.grace_until,
    p.hold_until,
    p.sms_allowance,
    p.sms_used,
    p.voice_allowance_seconds,
    p.voice_used_seconds,
    p.allowance_period_start,
    p.emergency_disabled,
    p.created_at,
    p.activated_at,
    p.released_at,
    greatest(
      (select max(m.received_at)
         from public.line_messages m
        where m.line_id = p.id
          and m.direction = 'inbound'),
      (select max(coalesce(c.ended_at, c.answered_at))
         from public.line_calls c
        where c.line_id = p.id
          and c.answered_at is not null
          and coalesce(c.duration_seconds, 0) >= 10)
    ) as last_success_at
  from public.phone_lines p
  where p.user_id = (select auth.uid());
