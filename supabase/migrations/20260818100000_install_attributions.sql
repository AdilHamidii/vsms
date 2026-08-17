-- Apple Search Ads attribution — the measurement that was missing entirely.
--
-- The app spends ~€20/day on Search Ads. ASA reports installs per campaign and
-- keyword; `iap_receipts` records who paid. Nothing has ever joined the two, so
-- the single question the spend exists to answer — WHICH keyword produces a
-- paying user — has been unanswerable for the life of the product. Every
-- bidding decision so far has been made on installs, i.e. on the cheap half of
-- the funnel.
--
-- `record-attribution` (edge function, JWT-verified) resolves the client's
-- AdServices token against Apple and writes exactly one row per user here.
--
-- Three deliberate choices:
--
--   * **This table DOES cascade from auth.users**, unlike the three credit
--     tombstones (`signup_grants`, `iap_grants`). Those must survive Delete
--     Account because they answer "have we already paid this out?"; this one is
--     ordinary user data and answering it about a deleted account is neither
--     needed nor wanted. Do not "fix" it to match the tombstones.
--
--   * **`attributed` is NOT NULL and means what Apple said.** A 404 from
--     Apple's endpoint after the retry is a real answer — organic — and is
--     stored as `false`. When Apple was UNREACHABLE the function writes no row
--     at all and the client leaves its pref unset, so the next cold launch
--     retries. Absence therefore means "not measured yet", never "organic".
--
--   * **RLS on, zero policies.** The client only ever WRITES, through the
--     service role inside the edge function, and never reads. Campaign/keyword
--     ids are not user-facing data and there is no reason for the publishable
--     key to reach them — the same reasoning that put `phone_lines` behind the
--     `my_line` view.

create table if not exists public.install_attributions (
    user_id           uuid primary key references auth.users(id) on delete cascade,
    attributed        boolean     not null,
    org_id            bigint,
    campaign_id       bigint,
    ad_group_id       bigint,
    keyword_id        bigint,
    ad_id             bigint,
    conversion_type   text,
    claim_type        text,
    country_or_region text,
    raw               jsonb,
    recorded_at       timestamptz not null default now()
);

alter table public.install_attributions enable row level security;

-- No policies: anon/authenticated can reach no row. The service role bypasses
-- RLS, which is the only writer.
revoke all on public.install_attributions from anon, authenticated;

create index if not exists install_attributions_campaign_idx
    on public.install_attributions (campaign_id, keyword_id)
    where attributed;


-- ── The payoff query ──────────────────────────────────────────────────────
--
-- Per (campaign, keyword): installs measured, how many of those users bought,
-- and how many credits they bought. `/revenue` deliberately reads price out of
-- the signed JWS rather than a hardcoded ladder (storefront pricing differs);
-- this function does NOT repeat that, because the question here is comparative
-- across campaigns and credits are the common unit. If a per-campaign USD
-- figure is ever wanted, join `jws_payload(raw_jws)` the way
-- `revenue_snapshot` does — do not invent a price table.
--
-- Sandbox receipts are excluded (they cost $0 and any Apple ID can mint them),
-- matching `revenue_snapshot`. `granted_credits > 0` is the "actually paid"
-- predicate, since a receipt row exists before credits land.
--
-- Rows with no attribution row at all are absent by construction: an install we
-- never measured is not evidence about any campaign.
create or replace function public.attribution_summary()
returns table (
    campaign_id  bigint,
    keyword_id   bigint,
    attributed   boolean,
    installs     bigint,
    buyers       bigint,
    purchases    bigint,
    credits      bigint
)
language sql
security definer
set search_path = public
as $$
    with buys as (
        select r.user_id,
               count(*)                          as purchases,
               coalesce(sum(r.granted_credits),0) as credits
        from public.iap_receipts r
        where r.environment = 'Production'
          and coalesce(r.granted_credits, 0) > 0
        group by r.user_id
    )
    select a.campaign_id,
           a.keyword_id,
           a.attributed,
           count(*)                                       as installs,
           count(b.user_id)                               as buyers,
           coalesce(sum(b.purchases), 0)::bigint          as purchases,
           coalesce(sum(b.credits), 0)::bigint            as credits
    from public.install_attributions a
    left join buys b on b.user_id = a.user_id
    group by a.campaign_id, a.keyword_id, a.attributed
    order by credits desc, installs desc;
$$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC, and anon/authenticated are members
-- of PUBLIC — so revoking from those two alone is a NO-OP. Revoke PUBLIC too.
-- See 20260727240000.
revoke execute on function public.attribution_summary() from public, anon, authenticated;
