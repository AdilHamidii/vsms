-- Rented lines: the repairs that make the lifecycle survivable.
--
-- Everything here fixes a path that FAILS SILENTLY. None of these throws, none
-- logs, and every one of them costs either money or the user's allowance.
--
--  1. THE CANCELLATION LEAK. `reclaim_lapsed_lines()` shipped, was scheduled in
--     no cron job, and `release-lines` — named in 20260805170000 as the thing
--     that drains `releasing` rows — was never written. So an ordinary Apple
--     cancellation went EXPIRED → suspend_line_claim → `suspended` → and
--     NOTHING EVER RAN AGAIN. $1/month per cancelled subscriber, forever,
--     discoverable only on the Telnyx invoice. This migration schedules the
--     sweep; the companion commit adds the edge function and its cron.
--
--  2. THE PROVISIONING LOCKOUT. `phone_lines_one_live_per_user` counts
--     `provisioning`, and nothing ever ages a stuck row out. A purchase whose
--     function died between `begin_line_rental` and `activate_line_claim` left
--     the user barred from renting again — permanently, while paying.
--
--  3. THE LOST RENEWAL. `apply_line_renewal` claimed its idempotency tombstone
--     BEFORE checking that either UPDATE matched. A renewal arriving while the
--     line was still `provisioning` was recorded as applied and dropped: the
--     allowance never reset and no retry could ever fix it, because the
--     tombstone said the work was done.
--
--  4. THE STUCK ALLOWANCE. An outbound message whose settle write failed sits
--     `queued` forever with its segments spent. There is no money to refund on
--     this line — the allowance IS the only thing that can be made whole — so
--     an unsettleable message must hand it back on a timer.
--
--  5. THE UNSETTLEABLE CALL. Nothing wrote `provider_call_session_id`, so the
--     CDR poller could never match a call and every dial stayed reserved at 120
--     seconds. 100 minutes of allowance ÷ 120s = 50 dials a month, and the
--     reservation was the *only* thing enforcing the cap, so a two-hour call
--     also cost nothing. Adds the writer and a stale-call fallback.
--
--  6. SUB-CENT COSTS ROUNDED TO ZERO. Telnyx bills $0.0040 a message;
--     `Math.round(0.004 * 100)` is 0, so `provider_cost_cents` recorded nothing
--     for every message ever sent. Adds an exact numeric column beside it.
--
-- ⚠️ Several of these change a function SIGNATURE, which `create or replace`
-- cannot do — it would create a second overload and leave PostgREST to pick.
-- Each one is dropped explicitly first, and every caller moves in the same
-- commit.

-- ── 1. Exact provider cost, beside the rounded cents ───────────────────────
-- The integer stays: it is what the ops formatter reads and what every
-- existing row carries. The numeric is the truth. Same shape as keeping
-- `herosms_cost_cents` raw beside the smoothed column — the rounded figure is
-- for display, the exact one is for arithmetic.
alter table public.line_messages
  add column if not exists provider_cost_usd numeric(12,6);
alter table public.line_calls
  add column if not exists provider_cost_usd numeric(12,6);

comment on column public.line_messages.provider_cost_usd is
  'Exact provider cost in USD. provider_cost_cents rounds a $0.0040 message to '
  '0 — this column is what margin arithmetic must read.';

-- ── 2. The reclaim sweep, widened into the lifecycle janitor ────────────────
-- Pure SQL and scheduled directly in pg_cron with no HTTP hop, for the same
-- reason run_watchdog is: the CLAIM must survive the edge layer being down.
-- The provider DELETE cannot, so `release-lines` drains `releasing` rows
-- separately and this function never calls out.
--
-- Return type changes from integer to jsonb, so the old one must go first.
drop function if exists public.reclaim_lapsed_lines();

create or replace function public.reclaim_lapsed_lines()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_reclaimed integer := 0;
  v_stuck     integer := 0;
  v_msgs      integer := 0;
  v_msg       record;
begin
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
    'stale_messages', v_msgs);
end;
$fn$;
revoke execute on function public.reclaim_lapsed_lines()
  from public, anon, authenticated;

-- ── 3. Renewal: verify before claiming the tombstone ───────────────────────
create or replace function public.apply_line_renewal(
  p_original_tx text, p_transaction_id text, p_period_end timestamptz,
  p_price_milli bigint, p_currency text, p_storefront text,
  p_signed_transaction text default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_line uuid; v_status public.line_status;
begin
  if p_original_tx is null or p_transaction_id is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 🔴 RESOLVE THE LINE BEFORE CLAIMING THE TOMBSTONE.
  --
  -- `provisioning` is TRANSIENT: verify-line-subscription is mid-flight and
  -- will set the period and reset the allowance itself in a few seconds. The
  -- old order claimed the tombstone first, so a renewal landing in that window
  -- was recorded as applied and then matched no row — the allowance never
  -- reset, and no retry could ever repair it because the tombstone said the
  -- work was done. Refusing here claims nothing, so Apple's retry ladder (and
  -- the unprocessed-notification sweep) can still apply it.
  select id, status into v_line, v_status
    from public.phone_lines
   where original_transaction_id = p_original_tx
   order by created_at desc
   limit 1;

  if v_status = 'provisioning' then
    return jsonb_build_object('ok', false, 'reason', 'line_provisioning',
                              'retryable', true);
  end if;

  -- The tombstone IS the idempotency check. Apple retries notifications at
  -- 1h/12h/24h/48h/72h and the reprocess sweep replays the same renewal from
  -- another direction — without this, one renewal resets the allowance several
  -- times and hands out free capacity.
  insert into public.line_renewals (transaction_id, original_transaction_id)
  values (p_transaction_id, p_original_tx)
  on conflict (transaction_id) do nothing;
  if not found then
    return jsonb_build_object('ok', true, 'reason', 'already_applied');
  end if;

  update public.line_subscriptions
     set state = 'active', expires_at = p_period_end,
         last_transaction_id = p_transaction_id,
         latest_signed_transaction =
           coalesce(p_signed_transaction, latest_signed_transaction),
         price_milli = coalesce(p_price_milli, price_milli),
         currency = coalesce(p_currency, currency),
         storefront = coalesce(p_storefront, storefront),
         grace_expires_at = null, updated_at = now()
   where original_transaction_id = p_original_tx;

  v_line := null;
  update public.phone_lines
     set status = case when status in ('grace','past_due','suspended')
                       then 'active' else status end,
         current_period_start = now(),
         current_period_end = p_period_end,
         grace_until = null,
         hold_until = null,
         allowance_period_start = now(),
         sms_used = 0,
         voice_used_seconds = 0,
         updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('active','grace','past_due','suspended')
  returning id into v_line;

  -- `allowance_reset` is reported rather than assumed. A renewal for a line
  -- that is already released is legitimate (the subscription outlives the
  -- number) and must read as such, not as success.
  return jsonb_build_object('ok', true, 'line_id', v_line,
                            'allowance_reset', v_line is not null);
end;
$fn$;
revoke execute on function public.apply_line_renewal(
  text, text, timestamptz, bigint, text, text, text)
  from public, anon, authenticated;

-- ── 4. Outbound settle: the provider's segment count is authoritative ──────
-- `sent.parts` was fetched from Telnyx and thrown away, so a message the local
-- estimator called one segment and Telnyx billed as three spent one segment of
-- allowance. The estimator errs LOW by design and this is what corrects it.
drop function if exists public.settle_outbound_message_claim(
  uuid, text, public.line_msg_status, integer, text);

create or replace function public.settle_outbound_message_claim(
  p_message uuid, p_provider_id text, p_status public.line_msg_status,
  p_cost_cents integer, p_error text,
  p_segments integer default null, p_cost_usd numeric default null
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_status public.line_msg_status; v_line uuid; v_segments integer;
begin
  select status, line_id, segments into v_status, v_line, v_segments
    from public.line_messages where id = p_message for update;
  if not found then return false; end if;
  -- Terminal states are final: a late DLR must never reopen a settled row.
  if v_status in ('delivered', 'failed') then return false; end if;

  update public.line_messages
     set status = p_status,
         provider_message_id = coalesce(p_provider_id, provider_message_id),
         provider_cost_cents = coalesce(p_cost_cents, provider_cost_cents),
         provider_cost_usd   = coalesce(p_cost_usd, provider_cost_usd),
         error_code = p_error,
         sent_at = case when p_status in ('sent','delivered')
                        then coalesce(sent_at, now()) else sent_at end
   where id = p_message;

  if p_status = 'failed' then
    -- Hand back everything this message reserved. No money exists to refund on
    -- this line, so the allowance is the only thing that can be made whole.
    perform public.settle_line_allowance(v_line, 'sms', 0, v_segments);
  elsif p_segments is not null and p_segments > 0 and p_segments <> v_segments then
    -- Adjust by the DIFFERENCE, never by re-charging: settle_line_allowance
    -- takes (actual, reserved) precisely so a correction cannot double-count.
    perform public.settle_line_allowance(v_line, 'sms', p_segments, v_segments);
    update public.line_messages set segments = p_segments where id = p_message;
  end if;
  return true;
end;
$fn$;
revoke execute on function public.settle_outbound_message_claim(
  uuid, text, public.line_msg_status, integer, text, integer, numeric)
  from public, anon, authenticated;

-- ── 5. The missing writer for a call's provider ids ────────────────────────
-- `provider_call_session_id` had no writer anywhere in the repo, and it is the
-- ONLY key sync-telnyx-cdr matches on. Every outbound call therefore kept its
-- 120-second reservation forever: 50 dials a month, and no enforcement at all
-- against a call that actually ran long.
--
-- Takes the user id and re-checks ownership: a call id is a client-supplied
-- resource selector, and the client is the only thing that knows the SDK's
-- session id.
create or replace function public.attach_line_call_session(
  p_user uuid, p_call uuid, p_session text, p_leg text default null,
  p_status public.line_call_status default null,
  p_answered_at timestamptz default null,
  p_duration_seconds integer default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_owner uuid; v_settled boolean; v_existing text;
begin
  select user_id, allowance_settled, provider_call_session_id
    into v_owner, v_settled, v_existing
    from public.line_calls where id = p_call for update;
  if not found or v_owner is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_call');
  end if;
  if v_owner <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'unknown_call');
  end if;
  -- A settled call is finished. A late client report must not reopen it or
  -- move the id the CDR already matched on.
  if v_settled then
    return jsonb_build_object('ok', true, 'reason', 'already_settled');
  end if;
  -- The session id is write-once. Two different ids on one row would mean the
  -- client re-used a call row for a second call, and silently repointing it
  -- would settle the wrong call's minutes.
  if v_existing is not null and p_session is not null and v_existing <> p_session then
    return jsonb_build_object('ok', false, 'reason', 'session_conflict');
  end if;

  update public.line_calls
     set provider_call_session_id = coalesce(p_session, provider_call_session_id),
         provider_call_leg_id     = coalesce(p_leg, provider_call_leg_id),
         status                   = coalesce(p_status, status),
         answered_at              = coalesce(p_answered_at, answered_at),
         -- Advisory only, and labelled as such on the column. billed_seconds
         -- from the CDR is the billing truth; this is what the device claimed.
         duration_seconds         = coalesce(p_duration_seconds, duration_seconds),
         ended_at = case when p_status in ('completed','missed','busy','failed','canceled')
                         then coalesce(ended_at, now()) else ended_at end
   where id = p_call;

  return jsonb_build_object('ok', true);
end;
$fn$;
revoke execute on function public.attach_line_call_session(
  uuid, uuid, text, text, public.line_call_status, timestamptz, integer)
  from public, anon, authenticated;

-- ── 6. Calls that never get a CDR ──────────────────────────────────────────
-- A call the client never reported an id for, or that Telnyx never billed,
-- would hold its reservation forever. After the CDR lag is comfortably past,
-- settle it against what the DEVICE reported — advisory, but far better than
-- leaving 120 seconds spent on a call that never connected.
--
-- 6 hours is deliberately double sync-telnyx-cdr's 180-minute lookback, so a
-- merely-late record still wins over this fallback.
create or replace function public.settle_stale_calls(
  p_older_minutes integer default 360
) returns integer
language plpgsql security definer set search_path to 'public' as $fn$
declare v_call record; v_count integer := 0; v_secs integer;
begin
  for v_call in
    select id, duration_seconds
      from public.line_calls
     where allowance_settled = false
       and created_at < now() - make_interval(mins => greatest(coalesce(p_older_minutes, 360), 30))
     limit 200
  loop
    v_secs := greatest(coalesce(v_call.duration_seconds, 0), 0);
    if public.settle_call_claim(
         v_call.id, v_secs, null,
         case when v_secs > 0 then 'completed' else 'missed' end::public.line_call_status,
         'no_cdr') then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$fn$;
revoke execute on function public.settle_stale_calls(integer)
  from public, anon, authenticated;

-- ── 7. Record what the number order was, so an orphan can be traced ────────
-- `provider_order_id` had no writer. It is the only handle on an ASYNCHRONOUS
-- purchase whose poll timed out — exactly the case where a number may still
-- arrive after we stopped looking, and the case the header of
-- verify-line-subscription says the orphan reconciler exists for.
--
-- Signature change, so the old one must go.
drop function if exists public.activate_line_claim(
  uuid, text, text, text, text, text, timestamptz, integer);

create or replace function public.activate_line_claim(
  p_line uuid, p_number_id text, p_connection text, p_msg_profile text,
  p_voice_profile text, p_credential text, p_period_end timestamptz,
  p_monthly_cost_cents integer, p_order_id text default null
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_status public.line_status;
begin
  select status into v_status from public.phone_lines where id = p_line for update;
  if not found or v_status <> 'provisioning' then return false; end if;

  update public.phone_lines
     set provider_number_id        = coalesce(p_number_id, provider_number_id),
         provider_order_id         = coalesce(p_order_id, provider_order_id),
         provider_connection_id    = coalesce(p_connection, provider_connection_id),
         provider_msg_profile_id   = coalesce(p_msg_profile, provider_msg_profile_id),
         provider_voice_profile_id = coalesce(p_voice_profile, provider_voice_profile_id),
         provider_credential_id    = coalesce(p_credential, provider_credential_id),
         monthly_cost_cents        = coalesce(p_monthly_cost_cents, monthly_cost_cents),
         current_period_start      = now(),
         current_period_end        = coalesce(p_period_end, current_period_end),
         allowance_period_start    = now(),
         sms_used = 0, voice_used_seconds = 0,
         status = 'active', activated_at = now(), updated_at = now()
   where id = p_line;
  return true;
end;
$fn$;
revoke execute on function public.activate_line_claim(
  uuid, text, text, text, text, text, timestamptz, integer, text)
  from public, anon, authenticated;

-- Also stamp the order id at the moment the order is PLACED, not only on
-- success. A provision that fails after the buy is exactly when the id is
-- needed, and activate_line_claim never runs on that path.
create or replace function public.record_line_order(p_line uuid, p_order_id text)
returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.phone_lines
     set provider_order_id = coalesce(p_order_id, provider_order_id),
         updated_at = now()
   where id = p_line;
  return found;
end;
$fn$;
revoke execute on function public.record_line_order(uuid, text)
  from public, anon, authenticated;

-- ── 8. The lines that still need a number handed back ──────────────────────
-- Read by `release-lines`. A plain SELECT would do, but the function keeps the
-- cost columns off the wire and gives the sweep one definition of "owes
-- Telnyx a DELETE" shared with the watchdog below.
create or replace function public.lines_awaiting_release(p_limit integer default 50)
returns table (
  line_id uuid, e164 text, provider_number_id text,
  provider_credential_id text, provider_connection_id text
)
language sql security definer set search_path to 'public' as $fn$
  select id, e164, provider_number_id, provider_credential_id, provider_connection_id
    from public.phone_lines
   where status = 'releasing'
   order by updated_at
   limit greatest(coalesce(p_limit, 50), 1);
$fn$;
revoke execute on function public.lines_awaiting_release(integer)
  from public, anon, authenticated;

-- ── 9. Schedule the sweep. THIS is the fix for the cancellation leak ───────
-- Pure SQL through pg_cron, with no HTTP hop and no CRON_SECRET, so it keeps
-- evaluating when the whole edge/secret layer is broken. Every 15 minutes: the
-- hold is measured in days, so the frequency is about the stuck-provisioning
-- and stale-message sweeps, which are measured in minutes.
select cron.unschedule('reclaim-lapsed-lines')
 where exists (select 1 from cron.job where jobname = 'reclaim-lapsed-lines');
select cron.schedule('reclaim-lapsed-lines', '*/15 * * * *',
                     $cron$select public.reclaim_lapsed_lines();$cron$);

-- The stale-call fallback runs hourly: it only ever acts on calls already six
-- hours old, so there is nothing to gain from running it more often.
select cron.unschedule('settle-stale-line-calls')
 where exists (select 1 from cron.job where jobname = 'settle-stale-line-calls');
select cron.schedule('settle-stale-line-calls', '23 * * * *',
                     $cron$select public.settle_stale_calls(360);$cron$);

-- ── 10. `emergency_disabled` has no writer ON PURPOSE ──────────────────────
-- Flagged by an audit as a column nothing writes. It is a column rather than a
-- constant so that enabling E911 later is per-line — which needs a verified
-- user address, an E911 registration at Telnyx and a privacy-policy change,
-- none of which exist. The DEFAULT is the writer, and it is the safe value.
comment on column public.phone_lines.emergency_disabled is
  'Always true today. No writer BY DESIGN — the default is the safe value and '
  'enabling E911 needs a verified address plus provider registration. Do not '
  'add a writer without those.';

-- ── 11. Watchdog: the line checks ─────────────────────────────────────────
-- Regenerated from pg_get_functiondef and diffed clause by clause, per the
-- standing rule — a one-line refactor that changes a watchdog threshold is a
-- monitoring outage. Exactly TWO hunks differ from the live definition: the
-- `v_lines` declaration and the block of line checks before the write-back.
-- Every pre-existing check is byte-identical.

CREATE OR REPLACE FUNCTION public.run_watchdog()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  fails jsonb := '[]'::jsonb;
  prev  jsonb;
  v_ts  timestamptz;
  bad_http int;
  bad_sample text;
  deliv_total int;
  deliv_ok    int;
  deliv7_total int;
  deliv7_ok   int;
  v_push_fail int;
  v_lines int;
begin
  -- The poller heartbeat. Reads 5sim_health, not smspva_health: this check has
  -- always meant "is poll-active-orders alive", and it happened to key on
  -- whichever provider that function wrote first. poll-active-orders stopped
  -- writing smspva_health on 2026-08-03 (SMSPVA serves nothing, eSIMs paused),
  -- so leaving it here would have gone red within ten minutes and, through
  -- winback's `failing === 0` gate, silently closed the stranded-credit cohort
  -- for the FIFTH time.
  select (value->>'checked_at')::timestamptz into v_ts
    from app_config where key = '5sim_health';
  if v_ts is null or v_ts < now() - interval '10 minutes' then
    fails := fails || jsonb_build_object('check','poll-active-orders',
      'detail','balance heartbeat last written '||coalesce(v_ts::text,'never')||
               ' — OTP polling, expiry refunds and balance monitoring are down');
  end if;

  select max(last_checked_at) into v_ts from routes;
  if v_ts is null or v_ts < now() - interval '3 hours' then
    fails := fails || jsonb_build_object('check','sync-prices',
      'detail','newest route price is from '||coalesce(v_ts::text,'never'));
  end if;

  -- sync-5sim owns the provider that serves SMS (cutover 2026-08-03).
  --
  -- This REPLACED the identical HeroSMS check rather than joining it. That one
  -- read `max(herosms_checked_at) where provider='herosms'`, and the moment the
  -- last route is re-homed that matches ZERO rows -> max() is NULL -> the
  -- `v_ts is null` arm fires forever. A permanently-red watchdog is not just
  -- noise: winback gates its stranded-credit cohort on `failing === 0`, so it
  -- would have silently closed that cohort. That is the same bug class as the
  -- daily-credit check fixed hours earlier the same day.
  --
  -- HeroSMS keeps serving temp EMAIL on the same account, so its BALANCE still
  -- matters and is still reported by /balance — but nothing syncs its route
  -- costs any more, so there is nothing here to check.
  select max(fivesim_checked_at) into v_ts from routes where provider = '5sim';
  if v_ts is null or v_ts < now() - interval '3 hours' then
    fails := fails || jsonb_build_object('check','sync-5sim',
      'detail','newest 5sim route cost is from '||coalesce(v_ts::text,'never')||
               ' — stale wholesale passes the margin gate and reservations then fail, '||
               'and the delivery percentages shown in the picker go stale with it');
  end if;

  -- eSIM catalog freshness. Skipped while the product is deliberately paused
  -- (app_config.esim_paused). Pausing to switch providers means the old
  -- provider stops being synced BY DESIGN, so without this the owner is paged
  -- every 6h about a staleness they chose — and alert fatigue on the only
  -- monitoring channel is exactly how a real outage later gets missed.
  -- Compared as jsonb, not cast: value::text::boolean throws on a JSON string.
  if not coalesce((select value = 'true'::jsonb from public.app_config
                   where key = 'esim_paused'), false) then
    select max(last_checked_at) into v_ts from esim_plans;
    if v_ts is null or v_ts < now() - interval '26 hours' then
      fails := fails || jsonb_build_object('check','sync-esim-plans',
        'detail','eSIM catalog last synced '||coalesce(v_ts::text,'never'));
    end if;
  end if;

  select (value->>'last_digest_at')::timestamptz into v_ts
    from app_config where key = 'telegram_bot';
  if v_ts is null or v_ts < now() - interval '7 hours' then
    fails := fails || jsonb_build_object('check','telegram-digest',
      'detail','last digest '||coalesce(v_ts::text,'never'));
  end if;

  if coalesce((select value->>'retired' from app_config
             where key = 'smspva_retired'), 'false') <> 'true' then
  select updated_at into v_ts from app_config where key = 'smspva_operator_sync';
    if v_ts is null or v_ts < now() - interval '30 hours' then
      fails := fails || jsonb_build_object('check','sync-smspva-operators',
        'detail','operator cursor last moved '||coalesce(v_ts::text,'never'));
    end if;
end if;

  if coalesce((select value->>'retired' from app_config
             where key = 'smspva_retired'), 'false') <> 'true' then
  select updated_at into v_ts from app_config where key = 'smspva_conversions_sync';
    if v_ts is null or v_ts < now() - interval '24 hours' then
      fails := fails || jsonb_build_object('check','sync-smspva-conversions',
        'detail','conversions cursor last moved '||coalesce(v_ts::text,'never'));
    end if;
end if;

  -- (c) `is null or`, not `is not null and` — an absent heartbeat means the job
  -- has never once succeeded, which is the loudest thing it could tell us.
  select updated_at into v_ts from app_config where key = 'winback_heartbeat';
  if v_ts is null or v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','winback',
      'detail','winback heartbeat last written '||coalesce(v_ts::text,'never'));
  end if;

  -- Only meaningful while the daily credit is actually ENABLED.
  --
  -- Its cron (relay-daily-credit) was unscheduled on 2026-08-02 and the grant
  -- disabled behind app_config.daily_credit_enabled. The heartbeat's ONLY
  -- writer is the daily-credit function that cron used to call, so the key
  -- froze at 2026-08-01 16:11:20Z and can never be written again. This check
  -- tripped at 18:11Z and has paged every 6h since — about a job that was
  -- deliberately switched off.
  --
  -- Two real costs: alert fatigue on the only monitoring channel, which is
  -- documented here as how the NEXT real outage gets ignored; and winback gates
  -- its stranded-credit cohort on `failing.length === 0` (winback/index.ts:140),
  -- so a permanently-red watchdog silently suppressed the cohort of users whose
  -- last order failed while they still hold idle credits.
  --
  -- Gated, not deleted, so re-enabling the grant restores its monitoring in the
  -- same step rather than leaving a paying job unwatched.
  --
  -- Compared as TEXT, never `::boolean` — a junk value would raise, and this
  -- function is the last thing that still evaluates when the edge/secret layer
  -- is broken. A missing or malformed row reads as "disabled", i.e. silent.
  if coalesce((select value->>'enabled' from app_config
                where key = 'daily_credit_enabled'), 'false') = 'true' then
    select updated_at into v_ts from app_config where key = 'daily_credit_heartbeat';
    if v_ts is null or v_ts < now() - interval '26 hours' then
      fails := fails || jsonb_build_object('check','daily-credit',
        'detail','daily-credit nudge last ran '||coalesce(v_ts::text,'never'));
    end if;
  end if;

  select updated_at into v_ts from app_config where key = 'esim_expiry_heartbeat';
  if v_ts is null or v_ts < now() - interval '2 hours' then
    fails := fails || jsonb_build_object('check','expire-esim-orders',
      'detail','eSIM expiry sweep last ran '||coalesce(v_ts::text,'never'));
  end if;

  -- (b) the e-mail expiry sweep added in this migration. Runs */5, so 2h is the
  -- same generous multiple the eSIM sweep gets.
  select updated_at into v_ts from app_config where key = 'email_expiry_heartbeat';
  if v_ts is null or v_ts < now() - interval '2 hours' then
    fails := fails || jsonb_build_object('check','expire-email-orders',
      'detail','e-mail expiry sweep last ran '||coalesce(v_ts::text,'never')||
               ' — paid addresses are not being refunded');
  end if;

  select coalesce((value->>'consecutive_failures')::int, 0) into v_push_fail
    from app_config where key = 'push_health';
  if v_push_fail >= 10 then
    fails := fails || jsonb_build_object('check','apns',
      'detail',v_push_fail||' consecutive push failures — code-arrived alerts are not reaching anyone');
  end if;

  select count(*), min(coalesce(status_code::text, error_msg, 'timeout'))
    into bad_http, bad_sample
    from net._http_response
   where created >= now() - interval '25 minutes'
     and (status_code is null or status_code < 200 or status_code >= 300
          or timed_out or error_msg is not null);
  if bad_http > 0 then
    fails := fails || jsonb_build_object('check','relay-http',
      'detail',bad_http||' non-2xx cron relay responses in 25 min (e.g. '||coalesce(bad_sample,'?')||')');
  end if;

  -- Delivery outcome. CANCELS ARE EXCLUDED (2026-08-01).
  --
  -- This used to count a cancel as conclusive when the user either held the
  -- number 240s+ or re-ordered the same service within 10 minutes. At a 59%
  -- cancel rate that made the check a measure of user impatience, not provider
  -- health: it fired 'ZERO codes delivered' on 2026-08-01 while non-cancelled
  -- delivery was ~73%. Alert fatigue on the only monitoring channel is how a
  -- real outage later gets missed.
  --
  -- Only `received` (delivered) and `expired` (ran the full window, nothing
  -- arrived) say anything about whether the PROVIDER is working. A cancel is
  -- the user's choice and is evidence about the UI, not the numbers.
  --
  -- Thresholds are set from measured reachability over 30 days, because a gate
  -- above the achievable volume is a silently disabled check — this function
  -- has already shipped that bug once:
  --   72h non-cancelled volume: avg 6, max 12  -> collapse gate 6
  --   7d  non-cancelled volume: min 3, avg 13, max 21 -> degraded gate 12
  -- At a ~73% baseline, zero codes in 6 orders is p ~ 0.0004, so 6 is small
  -- but not noisy. Collapse uses the SHORT window so a real outage is caught
  -- in hours; degradation uses the long one, where a rate is meaningful.
  select count(*), count(*) filter (where o.otp is not null or o.status = 'received')
    into deliv_total, deliv_ok
    from orders o
   where o.closed_at >= now() - interval '72 hours'
     and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and o.smspva_number is not null
     and o.status in ('received','expired');

  select count(*), count(*) filter (where o.otp is not null or o.status = 'received')
    into deliv7_total, deliv7_ok
    from orders o
   where o.closed_at >= now() - interval '7 days'
     and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and o.smspva_number is not null
     and o.status in ('received','expired');

  if deliv_total >= 6 and deliv_ok = 0 then
    fails := fails || jsonb_build_object('check','delivery-collapse',
      'detail',deliv_total||' uncancelled orders in 72h, ZERO codes delivered');
  elsif deliv7_total >= 12 and deliv7_ok::numeric / deliv7_total < 0.30 then
    fails := fails || jsonb_build_object('check','delivery-degraded',
      'detail',deliv7_ok||'/'||deliv7_total||' delivered in 7d (<30%, baseline ~73%)');
  end if;


  -- ── Rented second numbers (added 2026-08-06 with the lifecycle repairs) ──
  -- Every check here covers a path that costs MONEY when it stops, and the
  -- first two cover the failure that actually shipped: `reclaim_lapsed_lines()`
  -- existed, was scheduled in NO cron job, and `release-lines` was never
  -- written — so a cancelled subscriber's number billed us $1/month forever,
  -- discoverable only on the Telnyx invoice.
  select updated_at into v_ts from app_config where key = 'line_reclaim_heartbeat';
  if v_ts is null or v_ts < now() - interval '1 hour' then
    fails := fails || jsonb_build_object('check','reclaim-lapsed-lines',
      'detail','line reclaim sweep last ran '||coalesce(v_ts::text,'never')||
               ' — lapsed numbers are not being reclaimed');
  end if;

  -- Catches the leak DIRECTLY, without depending on any heartbeat being
  -- written: `releasing` is a claim, and a claim nobody drains is rent.
  select count(*) into v_lines from phone_lines
   where status = 'releasing' and updated_at < now() - interval '6 hours';
  if v_lines > 0 then
    fails := fails || jsonb_build_object('check','release-lines',
      'detail',v_lines||' line(s) stuck releasing >6h — still billing at the provider');
  end if;

  -- Well past the 15-minute sweep. A stuck row also BARS that user from
  -- renting again, because phone_lines_one_live_per_user counts the status.
  select count(*) into v_lines from phone_lines
   where status = 'provisioning' and created_at < now() - interval '45 minutes';
  if v_lines > 0 then
    fails := fails || jsonb_build_object('check','line-provisioning-stuck',
      'detail',v_lines||' line(s) stuck provisioning >45m — those users cannot rent');
  end if;

  -- Gated on calls existing. A check that pages about a job with no work is
  -- how alert fatigue starts, and this whole line is pre-launch today.
  if exists (select 1 from line_calls) then
    select updated_at into v_ts from app_config where key = 'telnyx_cdr_heartbeat';
    if v_ts is null or v_ts < now() - interval '2 hours' then
      fails := fails || jsonb_build_object('check','sync-telnyx-cdr',
        'detail','CDR sweep last ran '||coalesce(v_ts::text,'never')||
                 ' — call minutes are not being settled');
    end if;
  end if;

  -- A rejected Telnyx webhook is a rotated signing key or a forged request.
  -- Silence is normal here; anything at all needs a human. Without this the
  -- reject counter is written and read by nobody.
  select (value->>'at')::timestamptz into v_ts
    from app_config where key = 'telnyx_webhook_rejects';
  if v_ts is not null and v_ts > now() - interval '30 minutes' then
    fails := fails || jsonb_build_object('check','telnyx-webhook',
      'detail','Telnyx webhook rejected a request at '||v_ts::text||
               ' — inbound texts may be being dropped; check the signing key');
  end if;

  select value into prev from app_config where key = 'watchdog';
  insert into app_config (key, value)
  values ('watchdog', jsonb_build_object(
    'checked_at', now(), 'failing', fails,
    'alerted', coalesce(prev->'alerted', '[]'::jsonb),
    'last_alert_at', prev->>'last_alert_at'))
  on conflict (key) do update set value = excluded.value;

  return fails;
end;
$function$
;

-- ── 12. Call settle: record the EXACT provider cost ────────────────────────
-- Same defect as line_messages. A 60-second Telnyx call is fractions of a
-- cent, and `Math.round(amount * 100)` rounds it to zero — so every call would
-- have recorded a cost of 0 and any margin arithmetic over it would have been
-- circular, exactly like the eSIM path whose `actual_cost_cents` echoed the
-- cached catalog price.
--
-- Signature change, so the old one must go. `sync-telnyx-cdr` is the only
-- caller and moves in the same commit.
drop function if exists public.settle_call_claim(
  uuid, integer, integer, public.line_call_status, text);

create or replace function public.settle_call_claim(
  p_call uuid, p_billed_seconds integer, p_cost_cents integer,
  p_status public.line_call_status, p_hangup_cause text,
  p_cost_usd numeric default null
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_settled boolean; v_line uuid; v_reserved integer;
begin
  select allowance_settled, line_id, reserved_seconds
    into v_settled, v_line, v_reserved
    from public.line_calls where id = p_call for update;
  if not found or v_settled then return false; end if;

  update public.line_calls
     set billed_seconds = coalesce(p_billed_seconds, billed_seconds),
         provider_cost_cents = coalesce(p_cost_cents, provider_cost_cents),
         provider_cost_usd   = coalesce(p_cost_usd, provider_cost_usd),
         status = p_status,
         hangup_cause = coalesce(p_hangup_cause, hangup_cause),
         ended_at = coalesce(ended_at, now()),
         allowance_settled = true
   where id = p_call;

  perform public.settle_line_allowance(
    v_line, 'voice', coalesce(p_billed_seconds, 0), v_reserved);
  return true;
end;
$fn$;
revoke execute on function public.settle_call_claim(
  uuid, integer, integer, public.line_call_status, text, numeric)
  from public, anon, authenticated;

-- ── 13. Was the number's VOICE actually pointed at its connection? ─────────
-- `mint-line-token` creates the per-line credential connection, attaches the
-- number's voice to it, and stores the connection id — but it stored the id
-- even when the ATTACH failed. The attach only ever runs inside
-- `if (!connectionId)`, so a single failure meant it was never retried and
-- inbound calls never rang, permanently, while outbound kept working and
-- everything looked healthy.
--
-- Three-valued on purpose, and the same distinction as
-- `herosms_real_count`: null = never attempted, false = attempted and failed
-- (retry it), true = confirmed. Collapsing "not tried" into "failed" is how a
-- guard starts punishing its own backlog.
alter table public.phone_lines
  add column if not exists provider_voice_attached boolean;

comment on column public.phone_lines.provider_voice_attached is
  'null = never attempted, false = attach failed (mint-line-token retries), '
  'true = the number''s voice is pointed at its connection. Without this the '
  'attach was attempted exactly once per line and inbound calls stayed dead.';

create or replace function public.record_line_voice_binding(
  p_line uuid, p_connection text, p_credential text, p_attached boolean
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.phone_lines
     set provider_connection_id  = coalesce(p_connection, provider_connection_id),
         provider_credential_id  = coalesce(p_credential, provider_credential_id),
         provider_voice_attached = coalesce(p_attached, provider_voice_attached),
         updated_at = now()
   where id = p_line;
  return found;
end;
$fn$;
revoke execute on function public.record_line_voice_binding(uuid, text, text, boolean)
  from public, anon, authenticated;
