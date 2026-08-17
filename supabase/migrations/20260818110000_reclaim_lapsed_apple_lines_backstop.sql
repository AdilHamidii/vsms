-- ─────────────────────────────────────────────────────────────────────────────
-- reclaim_lapsed_lines(): a TIME-BASED backstop for Apple-billed lines
-- ─────────────────────────────────────────────────────────────────────────────
--
-- THE HOLE. The release chain for an Apple subscription is:
--
--     Apple EXPIRED ASSN → apple-notifications → suspend_line_claim
--       → reclaim_lapsed_lines() [branch (a)] → release-lines → Telnyx DELETE
--
-- Every link after the first is on pg_cron and heartbeats into the watchdog.
-- The FIRST link is on no clock at all: it waits for a notification we cannot
-- make Apple send. None of the three existing branches of this function reads
-- `phone_lines.current_period_end` or `line_subscriptions.expires_at`, so a
-- single dropped, malformed or JWS-rejected EXPIRED notification leaves the
-- line `active` forever — $1/month to Telnyx, and the user keeps a fully
-- working number for free.
--
-- MEASURED 2026-08-17 22:51Z, and it is not theoretical:
--   * line_notifications by type: SUBSCRIBED 5, DID_CHANGE_RENEWAL_STATUS 6,
--     CONSUMPTION_REQUEST 15, REFUND_DECLINED 3, ONE_TIME_CHARGE 14, TEST 1 —
--     and EXPIRED **0**. The branch that releases every number this product
--     has ever sold has NEVER executed in production.
--   * All 5 Apple subscriptions carry auto_renew = false. The first two lapse
--     at 2026-08-18 00:19:50Z and 00:22:58Z — 88 minutes after the audit —
--     the third at 08-19 15:10Z. The untested path is about to be exercised
--     three times in 40 hours.
--
-- THE FIX is the same shape the repo already chose for the `releasing` leak
-- (CLAUDE.md, "the cancellation leak"): the watchdog checks BOTH a heartbeat
-- and THE STATE ITSELF, because a state check catches the leak even when the
-- signal is never written. Same reasoning, one layer down — do not depend on
-- a notification you cannot make Apple send.
--
-- Branch (d): an Apple-billed line whose period ended more than 6 HOURS ago
-- and is still `active` is suspended exactly as `suspend_line_claim` would
-- have done it, with the same 7-day hold, so branch (a) then drains it on the
-- next run. Six hours absorbs ASSN latency, Apple's own grace handling, and
-- clock skew; it is far short of the ~15 days a real grace period lasts, and
-- a line in Apple grace has current_period_end MOVED FORWARD by
-- apply_line_renewal, so it is not caught here.
--
-- Deliberately does NOT touch credit-billed lines: those are swept by
-- debit_credit_lines() on their own tombstoned schedule.
--
-- Also adds the matching STATE check to run_watchdog() — 12h, so it fires
-- only if branch (d) itself failed to run twice.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.reclaim_lapsed_lines()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_reclaimed integer := 0;
  v_stuck     integer := 0;
  v_msgs      integer := 0;
  v_lapsed    integer := 0;
  v_msg       record;
begin
  -- (d) FIRST, so a line it suspends is picked up by (a) in the same run once
  -- its hold expires — and so the count is visible even when (a) then acts on
  -- it. Apple-billed, still active, period ended > 6h ago: Apple did not tell
  -- us, or we did not hear it. Suspend with the same 7-day hold that
  -- suspend_line_claim writes, so every downstream step is unchanged.
  update public.phone_lines
     set status = 'suspended',
         hold_until = coalesce(hold_until, now() + interval '7 days'),
         updated_at = now()
   where billing = 'apple'
     and status = 'active'
     and current_period_end is not null
     and current_period_end < now() - interval '6 hours';
  get diagnostics v_lapsed = row_count;

  -- (a) The hold expired. THIS is the cancellation leak: without it a
  -- suspended line sits at Telnyx billing us $1/month with nothing scheduled
  -- to notice.
  update public.phone_lines
     set status = 'releasing', updated_at = now()
   where status = 'suspended'
     and hold_until is not null
     and hold_until < now();
  get diagnostics v_reclaimed = row_count;

  -- (b) Stuck provisioning. `verify-line-subscription` runs inside one edge
  -- invocation; if it dies between begin_line_rental and activate_line_claim
  -- the row is `provisioning` forever, and because
  -- phone_lines_one_live_per_user counts that status the user can never rent
  -- again. 15 minutes is far past the measured sub-5s number order plus the
  -- ~150s edge ceiling.
  --
  -- ⚠️ `failed` is correct rather than `releasing`: a stuck row usually has NO
  -- provider_number_id, so there is nothing to give back. Where a number WAS
  -- bought, `customer_reference` still carries the line id and the orphan
  -- sweep in release-lines is what finds it.
  update public.phone_lines
     set status = 'failed', released_at = now(), updated_at = now()
   where status = 'provisioning'
     and created_at < now() - interval '15 minutes';
  get diagnostics v_stuck = row_count;

  -- (c) Outbound messages stranded mid-send. `begin_outbound_message` spends
  -- the allowance before Telnyx is called; if the settle write then fails the
  -- segments are gone and nothing revisits the row. Handing the allowance back
  -- is the only remedy that exists on a line with no money in it.
  for v_msg in
    select id from public.line_messages
     where status in ('queued', 'sending')
       and created_at < now() - interval '15 minutes'
     limit 200
  loop
    -- Through the claim function, never a bare UPDATE: the claim is what
    -- returns the allowance and what stops a late receipt reopening the row.
    if public.settle_outbound_message_claim(
         v_msg.id, null, 'failed'::public.line_msg_status, null, 'stale_no_receipt',
         null, null) then
      v_msgs := v_msgs + 1;
    end if;
  end loop;

  -- Heartbeat for run_watchdog. An absent heartbeat must fail LOUD, so the
  -- watchdog checks `is null or stale`, never `is not null and stale`.
  insert into public.app_config (key, value)
  values ('line_reclaim_heartbeat', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object(
    'reclaimed', v_reclaimed, 'stuck_provisioning', v_stuck,
    'stale_messages', v_msgs, 'lapsed_unnotified', v_lapsed);
end;
$function$;

revoke execute on function public.reclaim_lapsed_lines() from public, anon, authenticated;
