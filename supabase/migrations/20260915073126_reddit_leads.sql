-- Reddit radar: surfaces high-intent threads for the owner to answer BY HAND.
--
-- There is deliberately no posting path anywhere in this feature. The Reddit
-- credential is app-only (grant_type=client_credentials), which carries read
-- scope and cannot submit, comment or vote even if code asked it to. That is
-- the safety property: not a flag that can be flipped, an absent capability.
-- Undisclosed automated promotion is a Reddit Rule 2 violation and the
-- penalty lands on the DOMAIN, not the account.

create table if not exists public.reddit_queries (
  id            bigint generated always as identity primary key,
  query         text not null,
  -- null = site-wide search. A comma-separated list restricts to those subs.
  subreddits    text,
  active        boolean not null default true,
  note          text,
  created_at    timestamptz not null default now()
);

comment on table public.reddit_queries is
  'Search terms for reddit-scan. Tunable without a deploy — a term that stops '
  'earning its keep is turned off here, not edited into the function.';

create table if not exists public.reddit_leads (
  id            bigint generated always as identity primary key,
  -- Reddit's own fullname (t3_abc123). UNIQUE is the whole design: the scan
  -- re-reads the same search window every run, so this is what stops the same
  -- thread being pushed to Telegram hourly forever.
  reddit_id     text not null unique,
  subreddit     text not null,
  author        text,
  title         text not null,
  body          text,
  permalink     text not null,
  posted_at     timestamptz,
  score         integer,
  num_comments  integer,
  matched_query text,

  -- classifier output (null until reddit-scan's Kimi pass reaches this row)
  classified_at timestamptz,
  relevance     smallint,           -- 0..100
  intent        text,               -- buying | discussion | support | irrelevant
  need          text,               -- what the person actually wants, one line
  sub_policy    text,               -- permissive | restricted | unknown
  draft_reply   text,               -- a SUGGESTION. Never sent by this system.
  classify_error text,

  notified_at   timestamptz,
  status        text not null default 'new',  -- new | notified | replied | skipped
  acted_at      timestamptz,
  created_at    timestamptz not null default now(),

  constraint reddit_leads_status_ck
    check (status in ('new','notified','replied','skipped')),
  constraint reddit_leads_relevance_ck
    check (relevance is null or (relevance >= 0 and relevance <= 100))
);

comment on column public.reddit_leads.draft_reply is
  'A drafted reply for the owner to edit and post themselves. Nothing in this '
  'codebase posts it — see the table comment on reddit_queries and CLAUDE.md.';

-- The scan's two hot paths: "what have I not classified yet" and "what have I
-- not shown the owner yet".
create index if not exists reddit_leads_unclassified_idx
  on public.reddit_leads (created_at)
  where classified_at is null;

create index if not exists reddit_leads_pending_idx
  on public.reddit_leads (relevance desc)
  where notified_at is null and classified_at is not null;

create index if not exists reddit_leads_status_idx
  on public.reddit_leads (status, posted_at desc);

-- Both tables are ops-only. No client ever reads them; the bot reaches them on
-- the service role. RLS on with zero policies = deny to anon/authenticated,
-- which is the same shape app_events uses.
alter table public.reddit_queries enable row level security;
alter table public.reddit_leads   enable row level security;

revoke all on public.reddit_queries from anon, authenticated;
revoke all on public.reddit_leads   from anon, authenticated;

-- Seed terms. Every one of these is a question a person asks when they are
-- looking for what vSMS actually sells; none is a brand term.
insert into public.reddit_queries (query, subreddits, note) values
  ('"second phone number" app',      null, 'core line intent'),
  ('burner number app',              null, 'core line intent'),
  ('app to receive sms verification', null, 'temp SMS intent'),
  ('temporary phone number verification', null, 'temp SMS intent'),
  ('temp mail disposable email',     null, 'temp mail intent'),
  ('second number for selling marketplace', null, 'the honest use case'),
  ('number for verification code',   'privacy,VOIP,NoContract', 'sub-restricted')
on conflict do nothing;
