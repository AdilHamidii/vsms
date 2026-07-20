-- SMSPool-only cutover (owner decision 2026-07-20). Everything here is
-- REVERSIBLE: routes/services are hidden (not deleted), crons unscheduled
-- (not dropped). To restore a provider: un-hide its routes, re-schedule its
-- sync cron, and restore the fallback chain in _shared/providers.ts.

-- 1) Hide every route not owned/priced by SMSPool. Their prices came from
--    SMSPVA/virtualsms syncs and no longer have a fulfilment path.
update public.routes
set status = 'hidden'
where provider <> 'smspool' and status = 'active';

-- 2) Hide services with no bookable route left, so the picker doesn't fill
--    with permanently-Unavailable rows. (Un-hide by setting visible = true
--    when coverage returns.)
update public.services s
set visible = false
where s.visible = true
  and not exists (
    select 1 from public.routes r
    where r.service_id = s.id and r.status = 'active'
  );

-- 3) Retire the SMSPVA + virtualsms pricing crons. sync-prices would
--    otherwise re-activate the hidden SMSPVA catalog on its next daily run.
select cron.unschedule('relay-sync-prices');
select cron.unschedule('relay-virtualsms-sync');
