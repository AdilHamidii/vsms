-- Collect rent on credit-billed lines, daily.
--
-- Daily rather than monthly because `next_debit_at` is per line: a line falls
-- due on its own 30-day anniversary, and a daily sweep is what notices. It is
-- also the retry cadence during grace — a user who tops up on day two of a
-- three-day grace should be charged that day, not left waiting a month.
--
-- PURE SQL on pg_cron, deliberately, with no HTTP hop. This is the only thing
-- that collects money for this product line, so it must keep working when the
-- edge layer is down — the same reasoning that keeps `run_watchdog` and
-- `reclaim_lapsed_lines` out of an edge function. It calls no provider, so
-- there is no network failure mode to survive in the first place.
--
-- 05:19 rather than 05:00: every scheduler on the planet fires on the hour.
select cron.unschedule('debit-credit-lines')
 where exists (select 1 from cron.job where jobname = 'debit-credit-lines');

select cron.schedule('debit-credit-lines', '19 5 * * *',
                     $$select public.debit_credit_lines(3);$$);

do $$
begin
  if not exists (select 1 from cron.job
                  where jobname = 'debit-credit-lines' and active) then
    raise exception 'the rent sweep is not scheduled — nothing would collect rent';
  end if;
end $$;
