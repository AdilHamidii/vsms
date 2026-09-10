-- Pre-expiry nudges for rented lines whose subscriber turned auto-renew OFF.
--
-- There is no hold on lapse: reclaim_lapsed_lines suspends and release-lines
-- deletes the number at Telnyx within ~30 minutes of expires_at. On 2026-09-10
-- six of the eight active monthly subscribers had auto-renew off while
-- averaging 27 calls in 8 days, and nothing told them the number they were
-- using would be deleted. winback (daily) sends two pushes per billing period,
-- 3 days and 1 day out.
--
-- Dedupe is keyed on the expires_at each push was sent FOR, not a boolean, so a
-- renewal (which moves expires_at) re-arms both stages automatically.
--
-- Applied live via MCP apply_migration as version 20260910082724; this file is
-- the repo copy of the same SQL.

alter table public.line_subscriptions
  add column if not exists expiry_nudged_3d_for timestamptz,
  add column if not exists expiry_nudged_1d_for timestamptz;

comment on column public.line_subscriptions.expiry_nudged_3d_for is
  'expires_at the 3-day pre-expiry push was sent for; keyed on the period so a renewal re-arms it';
comment on column public.line_subscriptions.expiry_nudged_1d_for is
  'expires_at the 1-day pre-expiry push was sent for';

create or replace function public.line_expiry_nudge_candidates(p_limit integer default 100)
returns table(user_id uuid, original_transaction_id text, e164 text, expires_at timestamptz, stage text)
language sql stable security definer
set search_path to 'public'
as $$
  select s.user_id, s.original_transaction_id, l.e164, s.expires_at,
         case when s.expires_at <= now() + interval '36 hours' then '1d' else '3d' end as stage
    from public.line_subscriptions s
    join public.phone_lines l
      on l.original_transaction_id = s.original_transaction_id
     and l.status = 'active'
   where s.state = 'active'
     and s.auto_renew = false
     and s.expires_at > now()
     and s.expires_at <= now() + interval '4 days'
     and case when s.expires_at <= now() + interval '36 hours'
              then s.expiry_nudged_1d_for is distinct from s.expires_at
              else s.expiry_nudged_3d_for is distinct from s.expires_at
         end
     and exists (select 1 from public.push_devices d where d.user_id = s.user_id)
   order by s.expires_at
   limit p_limit;
$$;

revoke execute on function public.line_expiry_nudge_candidates(integer) from public, anon, authenticated;

create or replace function public.mark_line_expiry_nudged(
  p_original_transaction_id text, p_stage text, p_expires_at timestamptz)
returns void
language sql security definer
set search_path to 'public'
as $$
  update public.line_subscriptions
     set expiry_nudged_3d_for = case when p_stage = '3d' then p_expires_at else expiry_nudged_3d_for end,
         expiry_nudged_1d_for = case when p_stage = '1d' then p_expires_at else expiry_nudged_1d_for end
   where original_transaction_id = p_original_transaction_id;
$$;

revoke execute on function public.mark_line_expiry_nudged(text, text, timestamptz) from public, anon, authenticated;
