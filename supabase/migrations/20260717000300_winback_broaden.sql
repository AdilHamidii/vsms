-- Broaden winback beyond "never ordered". The analytics scan showed a chunk of
-- churn is users who DID try, never got a working code, and still hold credits —
-- exactly the people a nudge (and the now-fixed push path) can win back. Add
-- "ordered but never received a code" alongside "never ordered". Still gated on
-- balance > 0, a registered device, 3-day age, and the once-per-user guard.
create or replace function public.winback_candidates(p_limit int default 200)
returns table (user_id uuid)
language sql
security definer
set search_path = public
as $$
  select p.user_id
  from public.profiles p
  join public.wallets w on w.user_id = p.user_id
  where p.winback_sent_at is null
    and w.balance > 0
    and p.created_at < now() - interval '3 days'
    and exists (select 1 from public.push_devices d where d.user_id = p.user_id)
    and (
      not exists (select 1 from public.orders o where o.user_id = p.user_id)
      or not exists (
        select 1 from public.orders o
        where o.user_id = p.user_id and o.status = 'received'
      )
    )
  order by p.created_at
  limit greatest(p_limit, 0);
$$;

revoke execute on function public.winback_candidates(int) from public, anon, authenticated;
