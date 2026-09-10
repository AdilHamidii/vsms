-- Widen the reorder nudge's lookback from 14 to 90 days.
--
-- The cohort is "a code came through, credits remain, nothing ordered in 3
-- days". At 14 days it missed the buyers most worth reaching: on 2026-09-10,
-- 12 pack buyers were idle 14+ days holding 168 paid credits with a DELIVERED
-- last order, and no cohort could reach them — stranded requires a failed
-- last order, reorder required the code inside 14 days. The 3-sends-14-days-
-- apart cap and the 3-day quiet period are unchanged.
--
-- Applied live via MCP apply_migration as version 20260910083152; this file is
-- the repo copy of the same SQL.

create or replace function public.reorder_candidates(p_limit integer default 200)
returns table(user_id uuid, balance integer, last_service text)
language sql
security definer
set search_path to 'public'
as $function$
  select w.user_id, w.balance, s.name as last_service
    from public.wallets w
    join public.profiles p on p.user_id = w.user_id
    join lateral (
      select o.service_id, o.created_at
        from public.orders o
       where o.user_id = w.user_id
         and (o.status = 'received' or o.otp is not null)
       order by o.created_at desc
       limit 1
    ) last_ok on true
    left join public.services s on s.id = last_ok.service_id
   where w.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and w.balance > 0
     and p.reorder_nudge_count < 3
     and (p.reorder_nudge_sent_at is null
          or p.reorder_nudge_sent_at < now() - interval '14 days')
     -- Past the same-session burst, inside a window that still reaches an
     -- idle buyer whose credits are sitting there (was 14 days; 2026-09-10).
     and last_ok.created_at < now() - interval '3 days'
     and last_ok.created_at > now() - interval '90 days'
     and not exists (
           select 1 from public.orders o
            where o.user_id = w.user_id
              and o.created_at >= now() - interval '3 days')
     and exists (select 1 from public.push_devices d where d.user_id = w.user_id)
   order by w.balance desc
   limit p_limit;
$function$;

revoke execute on function public.reorder_candidates(integer) from public, anon, authenticated;
