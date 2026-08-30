-- Close the two lapse paths that nothing swept.
--
-- `reclaim_lapsed_lines()` gained an unnotified-lapse backstop in
-- 20260818110000, but it only ever covered `status = 'active'`. The only way
-- out of `grace` or `past_due` was an Apple EXPIRED notification calling
-- `suspend_line_claim`. When that notification is missed the line sits in
-- `grace`/`past_due` forever, and we keep paying Telnyx ~$1/month per number
-- with no signal anywhere — the invoice is the only place it shows up.
--
-- `past_due` is the urgent half going forward: the app-level grace period was
-- DISABLED on 2026-08-28, so every future failed renewal lands in `past_due`
-- (via mark_line_past_due_claim, which records no deadline at all) rather than
-- in `grace`. Without this branch the disabled grace period would have turned
-- every future billing failure into a permanent rent leak.
--
-- Both new branches suspend with the SAME 7-day hold `suspend_line_claim`
-- writes, so every downstream step (the hold, `releasing`, `release-lines`) is
-- unchanged. The hold is also the billing-recovery window: `apply_line_renewal`
-- restores a `suspended` line to `active` and clears `hold_until`, so a late
-- Apple recovery inside those 7 days costs the subscriber nothing.
--
-- Regenerated from pg_get_functiondef; branches (a), (b), (c), (d), the
-- heartbeat and the return shape are unchanged apart from two added counters.

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
  v_grace     integer := 0;
  v_pastdue   integer := 0;
  v_msg       record;
begin
  -- (d) Apple-billed, still active, period ended > 6h ago: Apple did not tell
  -- us, or we did not hear it. Suspend with the same 7-day hold that
  -- suspend_line_claim writes, so every downstream step is unchanged.
  -- See migration 20260818110000 for the full rationale.
  update public.phone_lines
     set status = 'suspended',
         hold_until = coalesce(hold_until, now() + interval '7 days'),
         updated_at = now()
   where billing = 'apple'
     and status = 'active'
     and current_period_end is not null
     and current_period_end < now() - interval '6 hours';
  get diagnostics v_lapsed = row_count;

  -- (d2) Grace expired and no EXPIRED notification arrived.
  --
  -- `grace_until` is Apple's own gracePeriodExpiresDate and is the authority.
  -- It can be null when the renewal-info JWS carried no such date, and in that
  -- case there is no recorded deadline to key on — so fall back to
  -- current_period_end + 16 days, Apple's MAXIMUM grace length. A grace row
  -- cannot legitimately outlive that, and the fallback can only ever fire
  -- LATER than the real deadline, so it can never cut a live grace short.
  update public.phone_lines
     set status = 'suspended',
         hold_until = coalesce(hold_until, now() + interval '7 days'),
         updated_at = now()
   where billing = 'apple'
     and status = 'grace'
     and coalesce(grace_until,
                  current_period_end + interval '16 days') < now() - interval '6 hours';
  get diagnostics v_grace = row_count;

  -- (d3) Billing retry with NO grace: entitlement ended at the period end.
  --
  -- mark_line_past_due_claim records no deadline of its own, so the period end
  -- is the only timestamp available — and it is the right one, because
  -- `past_due` means precisely "the renewal failed and there is no grace
  -- period". Apple may still recover the charge for up to 60 days; the 7-day
  -- hold is that recovery window, and apply_line_renewal restores the line.
  update public.phone_lines
     set status = 'suspended',
         hold_until = coalesce(hold_until, now() + interval '7 days'),
         updated_at = now()
   where billing = 'apple'
     and status = 'past_due'
     and current_period_end is not null
     and current_period_end < now() - interval '6 hours';
  get diagnostics v_pastdue = row_count;

  -- (a) The hold expired.
  update public.phone_lines
     set status = 'releasing', updated_at = now()
   where status = 'suspended'
     and hold_until is not null
     and hold_until < now();
  get diagnostics v_reclaimed = row_count;

  -- (b) Stuck provisioning.
  update public.phone_lines
     set status = 'failed', released_at = now(), updated_at = now()
   where status = 'provisioning'
     and created_at < now() - interval '15 minutes';
  get diagnostics v_stuck = row_count;

  -- (c) Outbound messages stranded mid-send.
  for v_msg in
    select id from public.line_messages
     where status in ('queued', 'sending')
       and created_at < now() - interval '15 minutes'
     limit 200
  loop
    if public.settle_outbound_message_claim(
         v_msg.id, null, 'failed'::public.line_msg_status, null, 'stale_no_receipt',
         null, null) then
      v_msgs := v_msgs + 1;
    end if;
  end loop;

  insert into public.app_config (key, value)
  values ('line_reclaim_heartbeat', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object(
    'reclaimed', v_reclaimed, 'stuck_provisioning', v_stuck,
    'stale_messages', v_msgs, 'lapsed_unnotified', v_lapsed,
    'lapsed_grace', v_grace, 'lapsed_past_due', v_pastdue);
end;
$function$;

revoke execute on function public.reclaim_lapsed_lines() from public, anon, authenticated;
