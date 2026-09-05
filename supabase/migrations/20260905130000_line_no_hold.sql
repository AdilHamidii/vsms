-- The 7-day hold on a lapsed line is RETIRED (owner decision 2026-09-05).
--
-- Why it existed: a suspended number was kept for seven days so a late Apple
-- billing recovery could restore the SAME number ("fix your card and
-- everything is as you left it"). Why it goes: measured on 2026-09-05 against
-- Telnyx's own number list, the account held 13 numbers for 6 paying lines —
-- 3 in `grace` and 2 in `suspended` were rent with no revenue behind them,
-- and every lapsed subscriber in the product's history had auto-renew OFF at
-- expiry, i.e. there was nothing to recover. The owner's rule is now:
--
--   a line that lapses releases its number on the NEXT sweep. No hold.
--
-- Mechanics kept deliberately simple: `suspended` survives as a transient hop
-- (≤ 15 min, one `reclaim_lapsed_lines` run) so the state machine, the client
-- rendering and `release-lines` are unchanged — only `hold_until` is now
-- `now()` everywhere it is written, and branch (a) promotes on `<=` so the
-- same run that suspends also moves the row to `releasing`. `release-lines`
-- (cron :03/:18/:33/:48) then deletes at Telnyx. Worst case ~30 min from
-- Apple's EXPIRED / GRACE_PERIOD_EXPIRED to the rent stopping.
--
-- Accepted residual, stated plainly: a billing recovery that lands AFTER the
-- release (Apple retries a declined card for up to 60 days) finds no live
-- line. `apply_line_renewal` marks the subscription active and revives
-- nothing — the customer has paid and holds no number until they reopen the
-- app and provision one. `apple-notifications` now PAGES the owner when that
-- happens (`renew_noline:<uuid>`), where before it only console.logged.
--
-- `suspend_line_claim` keeps its 2-arg signature (apple-notifications passes
-- `p_hold_until`) but IGNORES the value: the policy lives here, in one place,
-- and no caller can reintroduce a hold without a migration.

create or replace function public.suspend_line_claim(
  p_original_tx text, p_hold_until timestamptz
) returns boolean
language plpgsql security definer set search_path to 'public'
as $$
begin
  update public.line_subscriptions
     set state = 'expired', updated_at = now()
   where original_transaction_id = p_original_tx;

  -- p_hold_until is accepted for signature compatibility and ignored: there
  -- is no hold. The row is picked up by reclaim_lapsed_lines' branch (a) on
  -- its next run (≤ 15 min) and moved to `releasing`.
  update public.phone_lines
     set status = 'suspended',
         hold_until = now(),
         updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('active', 'grace', 'past_due');
  return found;
end;
$$;

revoke execute on function public.suspend_line_claim(text, timestamptz)
  from public, anon, authenticated;

create or replace function public.reclaim_lapsed_lines()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
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
  -- us, or we did not hear it. See migration 20260818110000 for the rationale
  -- of the 6h lag. No hold (20260905130000): hold_until = now() so branch (a)
  -- below promotes the row to `releasing` in this same run.
  update public.phone_lines
     set status = 'suspended',
         hold_until = now(),
         updated_at = now()
   where billing = 'apple'
     and status = 'active'
     and current_period_end is not null
     and current_period_end < now() - interval '6 hours';
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
$$;

revoke execute on function public.reclaim_lapsed_lines()
  from public, anon, authenticated;

-- One-time: the two lines already sitting in `suspended` under the old 7-day
-- hold (+14387951134 until 09-07, +14377825495 until 09-08) release on the
-- next sweep instead. Both subscriptions have auto_renew = false, so no
-- recovery was ever coming for either.
update public.phone_lines
   set hold_until = now(), updated_at = now()
 where status = 'suspended'
   and hold_until > now();
