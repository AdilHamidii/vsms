-- Block, report, and mark-read for line threads.
--
-- `line_threads.blocked` shipped as a column with no writer: every write to
-- these tables is revoked from `authenticated` (RLS is row-level and cannot
-- stop a client inserting `direction='inbound'` and forging a message from
-- someone), so the column existed and nothing could ever set it.
--
-- ⚠️ App Review 1.2 requires report/block on any surface displaying content
-- from arbitrary third parties, and a rented number is exactly that. It also
-- doubles as inbound-flood defence, which is the uncapped cost risk on this
-- line — the user cannot control who texts them, and every inbound message
-- costs us.

-- Blocking is per (user, thread) and verified against the caller, never taken
-- on trust: a thread id is a client-supplied resource selector.
create or replace function public.set_thread_blocked(
  p_user uuid, p_thread uuid, p_blocked boolean
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_owner uuid;
begin
  select user_id into v_owner from public.line_threads where id = p_thread;
  if v_owner is null or v_owner <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'thread_not_found');
  end if;

  update public.line_threads
     set blocked = coalesce(p_blocked, true),
         -- Blocking clears the unread badge. Leaving it would keep advertising
         -- messages the user has just said they do not want to see.
         unread_count = case when coalesce(p_blocked, true) then 0 else unread_count end
   where id = p_thread;

  return jsonb_build_object('ok', true, 'blocked', coalesce(p_blocked, true));
end;
$fn$;
revoke execute on function public.set_thread_blocked(uuid, uuid, boolean)
  from public, anon, authenticated;

-- Mark-read. Separate from blocking because opening a thread is not a
-- judgement about it.
create or replace function public.mark_thread_read(p_user uuid, p_thread uuid)
returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
begin
  update public.line_threads
     set unread_count = 0
   where id = p_thread and user_id = p_user and unread_count > 0;
  return found;
end;
$fn$;
revoke execute on function public.mark_thread_read(uuid, uuid)
  from public, anon, authenticated;

-- Reporting spam. Recorded rather than acted on automatically: an automatic
-- block on report would let one tap silence a number the user still wants, and
-- the point of a report is that a HUMAN looks at it.
create table if not exists public.line_reports (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  thread_id   uuid not null references public.line_threads(id) on delete cascade,
  peer_e164   text not null,
  reason      text,
  created_at  timestamptz not null default now(),
  -- One standing report per thread. A user tapping twice is not two reports,
  -- and without this a frustrated user generates an unbounded queue.
  unique (user_id, thread_id)
);
alter table public.line_reports enable row level security;
revoke all on public.line_reports from anon, authenticated;

create or replace function public.report_thread(
  p_user uuid, p_thread uuid, p_reason text
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_owner uuid; v_peer text;
begin
  select user_id, peer_e164 into v_owner, v_peer
    from public.line_threads where id = p_thread;
  if v_owner is null or v_owner <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'thread_not_found');
  end if;

  insert into public.line_reports (user_id, thread_id, peer_e164, reason)
  values (p_user, p_thread, v_peer, p_reason)
  on conflict (user_id, thread_id) do nothing;

  return jsonb_build_object('ok', true);
end;
$fn$;
revoke execute on function public.report_thread(uuid, uuid, text)
  from public, anon, authenticated;

do $$
declare n integer;
begin
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('set_thread_blocked','mark_thread_read','report_thread')
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if n > 0 then
    raise exception 'line thread actions are client-callable (% found)', n;
  end if;
end $$;
