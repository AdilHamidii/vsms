-- Behavioural checks for the grace / past_due lapse backstop
-- (migration 20260830120000). Everything runs inside a transaction that is
-- ROLLED BACK, so production state is untouched.
--
-- Run: supabase db query --linked --file scripts/verify-line-lapse-backstop.sql
-- Expect: a single 'ALL CHECKS PASSED' notice. Any failure raises.

begin;

-- Case A: grace still running (grace_until in the future) must NOT be touched.
update public.phone_lines
   set status = 'grace', grace_until = now() + interval '5 days', hold_until = null
 where e164 = '+14387951134';

-- Case B: grace expired > 6h ago must be suspended with a 7-day hold.
update public.phone_lines
   set status = 'grace', grace_until = now() - interval '7 hours', hold_until = null
 where e164 = '+14377825495';

-- Case C: grace with NO recorded grace_until, period ended 17 days ago
-- (past Apple's 16-day maximum) must be suspended by the fallback.
update public.phone_lines
   set status = 'grace', grace_until = null, hold_until = null,
       current_period_end = now() - interval '17 days'
 where e164 = '+14377822486';

-- Case D: same, but period ended 5 days ago — still inside the maximum grace
-- window, so the fallback must NOT fire and cut a live grace short.
update public.phone_lines
   set status = 'grace', grace_until = null, hold_until = null,
       current_period_end = now() - interval '5 days'
 where e164 = '+14377804892';

-- Case E: past_due (billing retry, no grace) past its period end must be
-- suspended — the go-forward path now that app-level grace is disabled.
update public.phone_lines
   set status = 'past_due', grace_until = null, hold_until = null,
       current_period_end = now() - interval '1 day'
 where e164 = '+14388393396';

select public.reclaim_lapsed_lines();

do $$
declare
  r record;
begin
  select status, hold_until into r from public.phone_lines where e164 = '+14387951134';
  if r.status <> 'grace' then
    raise exception 'A: live grace was cut short (status=%)', r.status;
  end if;

  select status, hold_until into r from public.phone_lines where e164 = '+14377825495';
  if r.status <> 'suspended' then
    raise exception 'B: expired grace not suspended (status=%)', r.status;
  end if;
  if r.hold_until is null or r.hold_until < now() + interval '6 days' then
    raise exception 'B: expired grace got no 7-day hold (hold_until=%)', r.hold_until;
  end if;

  select status into r from public.phone_lines where e164 = '+14377822486';
  if r.status <> 'suspended' then
    raise exception 'C: grace past the 16-day fallback not suspended (status=%)', r.status;
  end if;

  select status into r from public.phone_lines where e164 = '+14377804892';
  if r.status <> 'grace' then
    raise exception 'D: fallback cut a grace short inside 16 days (status=%)', r.status;
  end if;

  select status, hold_until into r from public.phone_lines where e164 = '+14388393396';
  if r.status <> 'suspended' then
    raise exception 'E: past_due not suspended (status=%)', r.status;
  end if;
  if r.hold_until is null then
    raise exception 'E: past_due got no recovery hold';
  end if;

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
