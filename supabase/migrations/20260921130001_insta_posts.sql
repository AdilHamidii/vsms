-- Instagram drafts: owner-approved posting for the app's own Instagram account.
--
-- insta-draft (cron, daily) writes ONE row per draft and sends it to the
-- owner's Telegram with Post / Skip buttons. Nothing is ever published without
-- that tap: telegram-webhook claims the row pending → publishing atomically,
-- so a double-tap or a stale button cannot publish twice.
--
-- status: pending    — drafted, shown to the owner, awaiting a decision
--         publishing — Post tapped and claimed; the Instagram call is running.
--                      A row STUCK here means the worker died mid-publish:
--                      check the Instagram account by hand before re-posting,
--                      because the post may have gone out.
--         published  — live on Instagram (ig_media_id set)
--         skipped    — owner tapped Skip
--         failed     — generation, validation, Telegram or Instagram failed
--                      (see error)

create table if not exists public.insta_posts (
  id               uuid primary key default gen_random_uuid(),
  status           text not null default 'pending',
  kind             text not null,
  theme            text,
  headline         text,
  caption          text,
  image_path       text,          -- object path inside the `insta` bucket
  image_url        text,          -- public URL Instagram fetches
  caption_model    text,
  image_model      text,          -- null for the screenshot kind
  ig_container_id  text,
  ig_media_id      text,
  error            text,
  tg_message_id    bigint,
  created_at       timestamptz not null default now(),
  decided_at       timestamptz,
  published_at     timestamptz,

  constraint insta_posts_status_ck
    check (status in ('pending','publishing','published','skipped','failed')),
  constraint insta_posts_kind_ck
    check (kind in ('screenshot','ai'))
);

comment on table public.insta_posts is
  'Instagram drafts. Written by insta-draft, decided by the owner''s Post/Skip '
  'tap in telegram-webhook. Nothing publishes without that tap.';

-- insta-draft reads the last few rows to alternate kind and avoid repeating a
-- theme; that is the only hot path.
create index if not exists insta_posts_created_idx
  on public.insta_posts (created_at desc);

-- Ops-only: no client ever reads it. RLS on with zero policies, and the
-- default grants Supabase hands anon/authenticated on a new public table are
-- revoked, then service_role is granted explicitly (REVOKE-then-GRANT).
alter table public.insta_posts enable row level security;
revoke all on public.insta_posts from public, anon, authenticated;
grant select, insert, update, delete on public.insta_posts to service_role;

-- PUBLIC bucket, deliberately: the Instagram Content Publishing API only
-- accepts an image at a publicly reachable URL. Public here means "readable by
-- exact URL"; there are no storage.objects policies, so anon cannot LIST the
-- bucket, and only the service role (which bypasses RLS) can write.
--   posts/<id>.jpg   drafts written by insta-draft
--   screens/*.png    app screenshots, uploaded by hand
--   probe/*.jpg      output of insta-draft {"probe":"image"}
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('insta', 'insta', true, 10485760, array['image/jpeg','image/png'])
on conflict (id) do nothing;
