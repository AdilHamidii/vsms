-- Counter helpers for the recurring nudges. Kept as SECURITY DEFINER RPCs so
-- the edge function does one call instead of a read-modify-write race.
create or replace function public.bump_winback_sent(p_user uuid)
returns void language sql security definer set search_path to 'public' as $function$
  update public.profiles
     set winback_sent_at = now(),
         winback_sent_count = coalesce(winback_sent_count, 0) + 1
   where user_id = p_user;
$function$;

create or replace function public.bump_reorder_nudge(p_user uuid)
returns void language sql security definer set search_path to 'public' as $function$
  update public.profiles
     set reorder_nudge_sent_at = now(),
         reorder_nudge_count = coalesce(reorder_nudge_count, 0) + 1
   where user_id = p_user;
$function$;

revoke execute on function public.bump_winback_sent(uuid) from public, anon, authenticated;
revoke execute on function public.bump_reorder_nudge(uuid) from public, anon, authenticated;
