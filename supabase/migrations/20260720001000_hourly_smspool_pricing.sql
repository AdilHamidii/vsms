-- Display prices must track SMSPool's real cost closely: bump relay-sync-smspool
-- from daily (0 3 * * *) to hourly. The bulk pricing phase is one API call per
-- run; the success-rate enrichment stays cursor-paced (120 combos/run), so the
-- hourly cadence adds negligible API load. With this, the price a user sees is
-- at most ~1h behind SMSPool, and the order-time max_price cap covers the gap.
select cron.alter_job(
  (select jobid from cron.job where jobname = 'relay-sync-smspool'),
  schedule := '7 * * * *'
);
