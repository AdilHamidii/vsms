-- International country catalog for the rentable-number line (Phase 1).
--
-- Nothing a shipped build decodes changes here: two new tables, two new
-- client-readable VIEWS, one refresh function, three config keys and one
-- nullable column on phone_lines.
--
-- ── What the 2026-08-26 Telnyx probe settled, and why the shape is this ────
--   * `GET /v2/country_coverage` reports capabilities per (country, NUMBER
--     TYPE). GB `local` has NO SMS while GB `mobile` does, so the PK is
--     (country_code, number_type) and nothing may ever roll capabilities up
--     across types — the country-level `features` blob unions them and lies.
--   * `GET /v2/requirements` returns ONE ROW PER (country, type, action) — a
--     requirement SET — and the documents live in that row's
--     `requirement_types[]`. `data.length` is NOT a document count. Hence two
--     separate columns: `requirement_sets` and `document_count`.
--     The "no paperwork" test is: probed AND (zero sets OR zero documents).
--   * A 429 is not zero requirements. The first probe run took four of them.
--     `requirements_empty` is therefore NULLABLE and NULL means NEVER PROBED,
--     which is BLOCKED. A failed read must leave it untouched and write
--     `last_fault` instead — it must never flip a country to "no documents".

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The catalog
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.line_country_catalog (
  country_code            text not null,
  number_type             text not null,

  -- Capabilities. NULL = never probed, and that is DISTINCT from false.
  supports_voice          boolean,
  supports_sms            boolean,
  supports_mms            boolean,
  supports_emergency      boolean,
  supports_fax            boolean,
  reservable              boolean,
  quickship               boolean,
  coverage_raw            jsonb,
  coverage_checked_at     timestamptz,

  -- Regulatory. `requirements_empty` is the COMPUTED verdict over the probe:
  -- true only when the probe succeeded AND (requirement_sets = 0 OR
  -- document_count = 0). NULL until a successful probe; a fault leaves it as
  -- it was.
  requirements_empty      boolean,
  requirement_sets        integer,
  document_count          integer,
  requirement_summary     jsonb,
  requirements_checked_at timestamptz,
  requirement_group_id    text,
  requirement_group_status text,

  -- Ops-only wholesale samples. NEVER published to a client view.
  sample_monthly_cents    integer,
  sample_upfront_cents    integer,
  sample_currency         text,
  sample_cost_known       boolean,
  sample_quoted_at        timestamptz,
  stock_seen              boolean,

  sell_state              text not null default 'blocked'
                            check (sell_state in ('sellable','blocked')),
  sell_reason             text,
  -- 🔴 'force_block' is the ONLY override, deliberately. There is no
  -- 'force_sell' and one must never be added: no override may sell a country
  -- whose live probe says end-user documents are required. The user would be
  -- charged for a number that arrives dead and stays `pending` for days — the
  -- repo already paid $3.83 learning exactly that on a GB number. The path to
  -- selling a documented country is an APPROVED Requirement Group, which is
  -- evidence, not an opinion.
  sell_override           text check (sell_override in ('force_block')),

  country_name            text,
  last_checked_at         timestamptz default now(),
  last_fault              text,

  primary key (country_code, number_type)
);

comment on table public.line_country_catalog is
  'Per (country, number type) sellability for the rentable-number line, written by sync-line-countries from live Telnyx probes. NULL capability/requirement columns mean NEVER PROBED and are blocking. Ops-only: revoked from anon/authenticated; clients read line_country_menu.';
comment on column public.line_country_catalog.requirements_empty is
  'Computed verdict: true only when a SUCCESSFUL probe found zero requirement sets or zero requirement_types. NULL = never probed (blocking). A 429/fault must leave this untouched and write last_fault.';
comment on column public.line_country_catalog.requirement_sets is
  'Rows returned by GET /v2/requirements for this (country, type, ordering) — a count of requirement SETS, not documents.';
comment on column public.line_country_catalog.document_count is
  'Total length of requirement_types[] across those sets — the actual document count.';
comment on column public.line_country_catalog.sell_override is
  'Only ''force_block'' exists. See the table definition: no override may sell a documented country.';

alter table public.line_country_catalog enable row level security;
revoke all on public.line_country_catalog from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Localities (replaces the hardcoded CITIES maps)
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.line_localities (
  id           text primary key,
  country_code text not null,
  label        text not null,
  region_label text,
  -- Ordered MOST-STOCK-FIRST, which in Canada is generally the overlay rather
  -- than the original: 416/514/613/403 are exhausted, 437/438/343/587 are not.
  area_codes   text[] not null default '{}',
  -- Telnyx's non-NANP search filters. NANP walks area_codes instead.
  locality     text,
  admin_area   text,
  number_type  text not null default 'local',
  sort_order   integer not null default 100,
  enabled      boolean not null default true
);

comment on table public.line_localities is
  'Curated localities per country for the number picker. Ops-only: clients read line_locality_menu.';

alter table public.line_localities enable row level security;
revoke all on public.line_localities from anon, authenticated;

create index if not exists line_localities_country_idx
  on public.line_localities (country_code, number_type, sort_order);

-- Seeded BYTE-IDENTICAL (ids, labels, area codes and their order) to the
-- CITIES map in supabase/functions/search-line-numbers/index.ts, which this
-- table is destined to replace. Region labels match LineCity.region's offline
-- switch in VirtualSIM/Models/LineModels.swift.
insert into public.line_localities
  (id, country_code, label, region_label, area_codes, number_type, sort_order)
values
  ('toronto',   'CA', 'Toronto',   'Ontario',          array['437','647','416','905','289'], 'local', 10),
  ('montreal',  'CA', 'Montreal',  'Quebec',           array['438','514'],                   'local', 20),
  ('vancouver', 'CA', 'Vancouver', 'British Columbia', array['604','778','236'],             'local', 30),
  ('calgary',   'CA', 'Calgary',   'Alberta',          array['587','403','825'],             'local', 40),
  ('ottawa',    'CA', 'Ottawa',    'Ontario',          array['343','613'],                   'local', 50),
  ('halifax',   'CA', 'Halifax',   'Nova Scotia',      array['902','782'],                   'local', 60),
  ('winnipeg',  'CA', 'Winnipeg',  'Manitoba',         array['204','431'],                   'local', 70)
on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Client views (the my_line / voice_rate_card precedent)
-- ─────────────────────────────────────────────────────────────────────────────
-- Deliberately NOT security_invoker: SELECT on the base tables is revoked, so
-- an invoker-rights view would need the caller to hold exactly the grant we
-- removed. The view IS the boundary — it is the column filter RLS cannot be.

create or replace view public.line_country_menu as
select
  c.country_code,
  c.country_name,
  c.number_type,
  coalesce(c.supports_voice,     false) as supports_voice,
  coalesce(c.supports_sms,       false) as supports_sms,
  coalesce(c.supports_mms,       false) as supports_mms,
  coalesce(c.supports_emergency, false) as supports_emergency,
  coalesce(c.supports_fax,       false) as supports_fax,
  (c.sell_state = 'sellable')           as available,
  c.sell_reason,
  exists (
    select 1 from public.line_localities l
    where l.country_code = c.country_code
      and l.number_type  = c.number_type
      and l.enabled
  ) as has_localities
from public.line_country_catalog c
where c.coverage_checked_at is not null;

comment on view public.line_country_menu is
  '🔴 PUBLIC. Capabilities + sellability only. NEVER add a cost column (sample_monthly_cents/upfront/currency), a requirement column (requirement_summary/document_count/requirement_sets/requirement_group_id) or coverage_raw: the first is our wholesale cost book, the second is a compliance record, and this view is readable by anon. Capabilities are coalesced to false so a never-probed value can never render as a capability. Rows appear only once coverage has actually been probed.';

create or replace view public.line_locality_menu as
select
  l.id,
  l.country_code,
  l.label,
  l.region_label,
  l.number_type,
  l.sort_order
from public.line_localities l
join public.line_country_catalog c
  on c.country_code = l.country_code
 and c.number_type  = l.number_type
where l.enabled
  and c.sell_state = 'sellable';

comment on view public.line_locality_menu is
  '🔴 PUBLIC. Enabled localities of SELLABLE countries only. area_codes/locality/admin_area are deliberately withheld: which prefixes we walk and in what order is server-side steering, and publishing it would let a client promise a city we cannot fill.';

grant select on public.line_country_menu  to anon, authenticated;
grant select on public.line_locality_menu to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Sellability
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.refresh_line_country_sellability()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_changed integer;
begin
  with computed as (
    select
      c.country_code,
      c.number_type,
      -- Reason for a BLOCK, or NULL when nothing blocks. Every NULL fails
      -- closed on the way in: `is not true` catches both false and unprobed.
      case
        when c.sell_override = 'force_block'          then 'owner_blocked'
        when c.coverage_checked_at is null            then 'never_probed'
        when c.reservable is not true                 then 'not_reservable'
        when c.supports_voice is not true             then 'no_voice'
        when c.requirements_empty is true             then null
        when c.requirement_group_id is not null
         and c.requirement_group_status = 'approved'  then null
        when c.requirements_checked_at is null        then 'never_probed'
        else 'documents_required'
      end as blocked_by,
      c.sell_state as old_state,
      c.sell_reason as old_reason
    from public.line_country_catalog c
  ),
  resolved as (
    select
      country_code,
      number_type,
      old_state,
      old_reason,
      -- 'order_rejected' is written by verify-line-subscription when Telnyx
      -- refuses an order the catalog said was sellable. It is EVIDENCE that
      -- beats our own probe, so it survives a refresh that would otherwise
      -- re-open the country. It clears only when something else starts
      -- blocking (a real reason wins) or when a sync writes the row's state
      -- itself after a coverage change.
      case
        when blocked_by is null
         and old_reason = 'order_rejected'
         and old_state = 'blocked' then 'blocked'
        when blocked_by is null    then 'sellable'
        else 'blocked'
      end as new_state,
      case
        when blocked_by is null
         and old_reason = 'order_rejected'
         and old_state = 'blocked' then 'order_rejected'
        else blocked_by
      end as new_reason
    from computed
  )
  update public.line_country_catalog t
     set sell_state  = r.new_state,
         sell_reason = r.new_reason
    from resolved r
   where t.country_code = r.country_code
     and t.number_type  = r.number_type
     and (t.sell_state is distinct from r.new_state
       or t.sell_reason is distinct from r.new_reason);

  get diagnostics v_changed = row_count;
  return v_changed;
end;
$$;

comment on function public.refresh_line_country_sellability() is
  'Recomputes sell_state/sell_reason for every catalog row and returns the number of rows actually changed. Sellable requires: no force_block, reservable IS TRUE, supports_voice IS TRUE, and (requirements_empty IS TRUE or an approved requirement group). Every NULL blocks.';

revoke execute on function public.refresh_line_country_sellability()
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Config — a SAFETY ceiling, never a pricing input
-- ─────────────────────────────────────────────────────────────────────────────
-- Deliberately NOT added to the app_config_read RLS whitelist: these are
-- wholesale figures and a freshness policy, not something a client needs.

insert into public.app_config (key, value) values
  ('line_country_catalog_max_age_hours',      to_jsonb(48)),
  ('line_wholesale_ceiling_monthly_cents',    to_jsonb(300)),
  ('line_wholesale_ceiling_upfront_cents',    to_jsonb(500))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. phone_lines gains the locality it was swapped within
-- ─────────────────────────────────────────────────────────────────────────────
-- Nullable and decoded by nothing: a country-aware swap needs to know which
-- locality the line was bought in, because outside NANP there is no area code
-- to extract it from.

alter table public.phone_lines add column if not exists locality text;
