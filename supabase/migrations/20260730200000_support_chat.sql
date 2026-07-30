-- Live support chat: user types in the app, the owner answers from Telegram.
--
-- Why this is worth building at THIS size and not later: the product's whole
-- problem is delivery, and the measured failure is impatience. Cancels land at
-- a median of 57s while codes land at a median of 58s, and 28 of 37 first-time
-- users who cancelled never got a code as a result. A human saying "give it
-- thirty more seconds" converts directly into the one event that drives
-- retention (0 codes -> 2.1 lifetime orders, 2+ codes -> 14.8). With ~1 order
-- an hour and one operator, a single human can cover essentially all of it.
--
-- ── Transport, and why Telegram rather than a console ───────────────────────
-- The ops bot already exists, is already the owner's alert channel, and its
-- webhook is already gated twice (matching secret token AND owner chat id).
-- Reusing it means no new auth surface and no new app to watch.
--
-- The owner answers by REPLYING to the message the bot posted. That is why
-- `support_messages.tg_message_id` exists: every message we relay to Telegram
-- records the id Telegram assigned it, so an inbound
-- `message.reply_to_message.message_id` resolves back to a thread. Matching on
-- the LAST message id of a thread would break the moment the owner scrolls up
-- and answers an older one, which is exactly what happens with two conversations
-- in flight.

-- ── 1. Status vocabulary ───────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_type where typname = 'support_status') then
    create type public.support_status as enum (
      'open',      -- user wrote, nobody has picked it up
      'assigned',  -- owner accepted; they are the agent for this thread
      'closed'     -- resolved, or aged out
    );
  end if;
end $$;

-- ── 2. Threads: one live conversation per user ─────────────────────────────
create table if not exists public.support_threads (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  status          public.support_status not null default 'open',
  -- Denormalised so the owner's list and the unread badge do not need a join
  -- or an aggregate on every poll.
  last_message_at timestamptz not null default now(),
  last_sender     text not null default 'user' check (last_sender in ('user','agent')),
  created_at      timestamptz not null default now(),
  closed_at       timestamptz
);

-- At most ONE live thread per user. A second "open" row would split the
-- conversation and the owner would answer half of it.
create unique index if not exists support_threads_one_live_per_user
  on public.support_threads (user_id)
  where status <> 'closed';

create index if not exists support_threads_live_idx
  on public.support_threads (status, last_message_at desc)
  where status <> 'closed';

-- ── 3. Messages ────────────────────────────────────────────────────────────
create table if not exists public.support_messages (
  id             uuid primary key default gen_random_uuid(),
  thread_id      uuid not null references public.support_threads(id) on delete cascade,
  sender         text not null check (sender in ('user','agent')),
  body           text not null check (length(btrim(body)) between 1 and 2000),
  -- Telegram's id for the copy we relayed. Set only on messages we PUSHED to
  -- Telegram; it is how an owner's reply finds its way home. See the header.
  tg_message_id  bigint,
  created_at     timestamptz not null default now(),
  -- Stamped when the user's client has actually rendered it, so the app can
  -- show an unread badge without guessing.
  read_at        timestamptz
);

create index if not exists support_messages_thread_idx
  on public.support_messages (thread_id, created_at);

create unique index if not exists support_messages_tg_id_key
  on public.support_messages (tg_message_id)
  where tg_message_id is not null;

-- ── 4. RLS ─────────────────────────────────────────────────────────────────
alter table public.support_threads  enable row level security;
alter table public.support_messages enable row level security;

drop policy if exists "support_threads: self read" on public.support_threads;
create policy "support_threads: self read" on public.support_threads
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "support_messages: self read" on public.support_messages;
create policy "support_messages: self read" on public.support_messages
  for select to authenticated
  using (exists (
    select 1 from public.support_threads t
     where t.id = thread_id and t.user_id = (select auth.uid())
  ));

-- Reads only. Every write goes through an edge function on the service role:
-- RLS is row-level and cannot stop a client from inserting a row with
-- sender = 'agent' and impersonating support.
revoke insert, update, delete, truncate on public.support_threads  from anon, authenticated;
revoke insert, update, delete, truncate on public.support_messages from anon, authenticated;

-- ── 5. post_support_message — one transaction, per-user serialised ─────────
--
-- Same advisory-lock discipline as begin_order: without it a double-tap can
-- create two "open" threads, and the unique index above would turn the second
-- into a raw 23505 the client cannot interpret.
create or replace function public.post_support_message(
  p_user uuid, p_body text, p_sender text default 'user'
) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_thread uuid;
  v_id uuid;
  v_body text := btrim(p_body);
  v_new_thread boolean := false;
begin
  if v_body = '' or length(v_body) > 2000 then
    return jsonb_build_object('ok', false, 'reason', 'bad_body');
  end if;
  if p_sender not in ('user','agent') then
    return jsonb_build_object('ok', false, 'reason', 'bad_sender');
  end if;

  perform pg_advisory_xact_lock(hashtext('support:' || p_user::text));

  select id into v_thread from public.support_threads
   where user_id = p_user and status <> 'closed'
   limit 1;

  if v_thread is null then
    insert into public.support_threads (user_id, last_sender)
    values (p_user, p_sender)
    returning id into v_thread;
    v_new_thread := true;
  end if;

  insert into public.support_messages (thread_id, sender, body)
  values (v_thread, p_sender, v_body)
  returning id into v_id;

  update public.support_threads
     set last_message_at = now(), last_sender = p_sender
   where id = v_thread;

  return jsonb_build_object('ok', true, 'thread_id', v_thread,
                            'message_id', v_id, 'new_thread', v_new_thread);
end $$;

revoke execute on function public.post_support_message(uuid, text, text)
  from public, anon, authenticated;

comment on table public.support_threads is
  'Live support conversations. One non-closed thread per user, enforced by a '
  'partial unique index. Owner answers from Telegram by replying to the relayed '
  'message — see support_messages.tg_message_id.';
