-- Service visibility must follow real coverage, automatically. During the
-- SMSPool-only cutover 148 services were hidden for having no bookable route;
-- nothing ever un-hid them, so a service whose routes returned (e.g. 'uber'
-- once its SMSPool mapping was fixed) stayed invisible to users indefinitely.
-- Runs at the end of every hourly sync-smspool.
create or replace function public.sync_service_visibility()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_changed integer;
begin
  with target as (
    select s.id,
           exists (select 1 from public.routes r
                   where r.service_id = s.id and r.status = 'active') as should_show
    from public.services s
  ),
  upd as (
    update public.services s
    set visible = t.should_show
    from target t
    where s.id = t.id and s.visible is distinct from t.should_show
    returning 1
  )
  select count(*) into v_changed from upd;
  return v_changed;
end;
$$;

revoke execute on function public.sync_service_visibility() from public, anon, authenticated;

-- Recover services SMSPool carries under bundled alias names that exact-name
-- matching missed (e.g. "Uber / Postmates", "Amazon / Amazon Web Services").
update public.services s set smspool_code = v.code
from (values
  ('uber','951'), ('amazon','39'), ('microsoft','1072'), ('twilio','946'),
  ('match','559'), ('blizzard','70'), ('swagbucks','889'), ('inboxdollars','889'),
  ('topcashback','833'), ('gettaxi','383'), ('myopinions','613')
) as v(id, code)
where s.id = v.id and s.smspool_code is null;
