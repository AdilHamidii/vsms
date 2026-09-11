-- Release a lapsed number AT the period end when Apple has already told us the
-- subscription is not renewing.
--
-- 🔴 Owner rule (2026-09-11): **never pay rent on a number no subscriber is
-- assigned to.** "I'll only pay the next month $1 if that user is still
-- subscribed."
--
-- Branch (d) waited `current_period_end + 6 hours` for EVERY Apple line. That
-- lag exists for one reason: a DID_RENEW notification can arrive late, and
-- releasing a renewing subscriber's number is unrecoverable. It is the right
-- slop when a renewal might still be coming.
--
-- It is pure cost when one cannot. `auto_renew = false` is Apple telling us in
-- advance that nothing will be charged at the period end, and on 2026-09-11
-- SIX of the nine active Apple lines carried it. Telnyx charges **$2.00 at the
-- moment of order** — $1.00 upfront and the first month together, measured
-- from Telnyx's own refusal (`app_config.telnyx_test_number_probe`: "Credit
-- available: 0.51 Total cost of Order: 2.0") — so rent is not a distant event
-- worth six hours of slop, and those six hours straddle exactly the moment the
-- number's own renewal falls due.
--
-- So: no wait when Apple has said there is no renewal; the unchanged 6h
-- everywhere else. Branches (d2) grace and (d3) past_due KEEP the 6h on
-- purpose — both mean Apple is still trying to bill, so a renewal genuinely
-- may still land.
--
-- ⚠️ Never release EARLIER than `current_period_end`. The subscriber paid
-- through that instant and is entitled to the number until it passes; the gain
-- here is the six hours after it, not a minute before.

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
  -- (d) Apple-billed, still active, period ended: Apple did not tell us, or we
  -- did not hear it. See migration 20260818110000 for the rationale of the 6h
  -- lag, and this migration for why `auto_renew = false` does not get it. No
  -- hold (20260905130000): hold_until = now() so branch (a) below promotes the
  -- row to `releasing` in this same run.
  update public.phone_lines p
     set status = 'suspended',
         hold_until = now(),
         updated_at = now()
   where p.billing = 'apple'
     and p.status = 'active'
     and p.current_period_end is not null
     and p.current_period_end < now() - (
           case when exists (
                  select 1 from public.line_subscriptions s
                   where s.original_transaction_id = p.original_transaction_id
                     and s.auto_renew is false)
                then interval '0'
                else interval '6 hours'
           end);
  get diagnostics v_lapsed = row_count;

  -- (d2) Grace expired and no GRACE_PERIOD_EXPIRED / EXPIRED notification
  -- arrived. `grace_until` is Apple's own gracePeriodExpiresDate; when it is
  -- null, fall back to current_period_end + 16 days (Apple's MAXIMUM grace),
  -- which can only ever fire LATER than the real deadline.
  update public.phone_lines
     set status = 'suspended',
         hold_until = now(),
         updated_at = now()
   where billing = 'apple'
     and status = 'grace'
     and coalesce(grace_until,
                  current_period_end + interval '16 days') < now() - interval '6 hours';
  get diagnostics v_grace = row_count;

  -- (d3) Billing retry with NO grace: entitlement ended at the period end.
  -- mark_line_past_due_claim records no deadline of its own, so the period
  -- end is the only timestamp available, and the right one.
  update public.phone_lines
     set status = 'suspended',
         hold_until = now(),
         updated_at = now()
   where billing = 'apple'
     and status = 'past_due'
     and current_period_end is not null
     and current_period_end < now() - interval '6 hours';
  get diagnostics v_pastdue = row_count;

  -- (a) Suspended → releasing. `<=`, not `<`: now() is fixed for the whole
  -- transaction, so a row suspended two statements above carries exactly
  -- now() and must still qualify here.
  update public.phone_lines
     set status = 'releasing', updated_at = now()
   where status = 'suspended'
     and hold_until is not null
     and hold_until <= now();
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

revoke execute on function public.reclaim_lapsed_lines() from anon, authenticated;
