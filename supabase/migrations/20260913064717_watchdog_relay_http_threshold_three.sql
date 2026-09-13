-- relay-http: page at THREE or more non-2xx cron relay responses in 25 minutes,
-- not one.
--
-- Why. Every `* * * * *` relay fires at second :00, and on the free-tier compute
-- PostgREST kills ~1% of that burst after ~5s (measured 2026-09-12: 1,229 REST
-- 504s in 24h, 89% in seconds 0-2 of the minute). Any cron function whose FIRST
-- read lands in the burst answers 500, and at `> 0` a single such response
-- turned this check red for 25 minutes. Once the largest offender (rc-sync)
-- was fixed the check stopped being solidly red and started FLAPPING — several
-- red/green transitions an hour, each one a Telegram page plus an all-clear.
-- A real relay outage (rotated secret, a 401 storm, the edge layer down) fails
-- every minutely relay: three per minute, so `>= 3` still catches it inside
-- one minute. What it no longer catches is a stray timeout, which is the point.
--
-- How. This is a SURGICAL patch: the live definition is read back, the one
-- clause is replaced, the replacement is asserted to have matched EXACTLY
-- ONCE, and the result is executed. A previous rebuild of run_watchdog from a
-- dump silently deleted a delivery branch and invented a column; touching one
-- string and asserting the match count is how that class of accident is
-- excluded here. If a later migration rewrites the clause, this one raises
-- rather than silently doing nothing.
do $$
declare
  d text;
  needle constant text := 'if bad_http > 0 then';
  replacement constant text := 'if bad_http >= 3 then';
  n int;
begin
  d := pg_get_functiondef('public.run_watchdog_core'::regproc);
  n := (length(d) - length(replace(d, needle, ''))) / length(needle);
  if n <> 1 then
    raise exception 'run_watchdog_core: expected exactly one "%", found %', needle, n;
  end if;
  execute replace(d, needle, replacement);
end $$;
