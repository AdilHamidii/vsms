-- One-shot scheduled reminders, paged from the Telegram bot (owner request
-- 2026-08-29: "add it to the telegram bot, huge reminder a week or a month
-- before or both"). The owner is hands-off and must not depend on an external
-- calendar for the one silent failure the watchdog cannot see coming: the
-- Apple VoIP push certificate expiring 2027-09-05 (inbound ringing dies with
-- no error anywhere).
--
-- telegram-notify sweeps this table every minute. The row's `sent_at` IS the
-- claim: stamped before sending (update … where sent_at is null), cleared
-- back on a failed send so the next minute retries — same shape as
-- telegram_events, without widening its kind constraint for a one-shot.
-- `what`/`action` are rendered as raw Telegram HTML (alertHtml escapes only
-- the title) — keep seeded text free of unescaped < > & outside deliberate
-- tags.

create table if not exists public.ops_reminders (
  id        bigint generated always as identity primary key,
  remind_at timestamptz not null,
  sev       text not null default '🔴',
  title     text not null,
  what      text not null,
  action    text not null,
  sent_at   timestamptz
);
alter table public.ops_reminders enable row level security;
revoke all on public.ops_reminders from anon, authenticated;

insert into public.ops_reminders (remind_at, sev, title, what, action) values
(
  '2027-08-05 07:00:00+00', '🔴',
  'VoIP certificate expires in ONE MONTH — Sep 5, 2027',
  'When it lapses, rented numbers SILENTLY stop ringing for incoming calls — no error, no page. SMS and outbound calls are unaffected.',
  'Ten minutes: Apple developer portal → renew the VoIP Services Certificate against the SAME key (<code>~/Desktop/telnyx-voip/voip.key</code> — do not lose it) → upload to Telnyx (mobile push credentials). If the line product has no subscribers left, you may deliberately let it lapse.'
),
(
  '2027-08-29 07:00:00+00', '🔴',
  'LAST CALL: VoIP certificate expires in ONE WEEK — Sep 5, 2027',
  'After Sep 5, rented numbers SILENTLY stop ringing for incoming calls. This is the final reminder.',
  'Apple developer portal → renew the VoIP Services Certificate with <code>~/Desktop/telnyx-voip/voip.key</code> → upload to Telnyx. Ten minutes.'
);
