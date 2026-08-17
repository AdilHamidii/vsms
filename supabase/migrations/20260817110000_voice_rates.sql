-- International calling, billed in credits at 5x wholesale.
--
-- WHY THIS EXISTS. The rented line sells a MINUTE allowance — 100 minutes, hard
-- stop. That is safe while the only reachable destinations are US and Canada,
-- where termination is flat and sub-cent. It is an unbounded liability the
-- moment international is enabled, because a minute-denominated bucket cannot
-- tell a $0.005/min call from a $3.62/min one: 100 minutes to a premium
-- Portuguese prefix costs ~$362 against $8.49 of subscription revenue. That is
-- International Revenue Share Fraud's whole business model, and it targets
-- small operators precisely because their allowance logic assumes minutes are
-- fungible.
--
-- So: DOMESTIC (NANP) stays on the minute allowance, exactly as sold.
-- INTERNATIONAL is charged from the credit wallet, per minute, at 5x.
--
-- ── Why credits are charged in BLOCKS, not per minute ─────────────────────
-- A credit nets $0.40. At 5x, France costs $0.075/min — which is 0.19 credits,
-- and the wallet is an integer. Rounding up to 1 credit/min would price France
-- at $0.40/min: a 26x margin, and ~20x what a consumer VoIP app charges. So a
-- credit buys a DESTINATION-SPECIFIC number of seconds instead:
--
--     seconds_per_credit = 60 / credits_per_min
--
--     France  $0.015/min -> 0.1875 cr/min -> 1 credit buys 320 seconds
--     Spain   $0.72/min  -> 9.0    cr/min -> 1 credit buys 6.7 seconds
--
-- The margin is 5x at every price point and the wallet stays integer.
--
-- ⚠️ THE RATES BELOW ARE PROVISIONAL AND DELIBERATELY CONSERVATIVE (rounded
-- UP). Telnyx publishes per-destination pricing as a downloadable RATE DECK,
-- not as an API — probed 2026-08-17, no v2 endpoint returns it. This repo's
-- standing rule is never to encode a guess about a vendor's numbers, so these
-- are set HIGH on purpose: the failure mode is "we charged the user too much",
-- never "we sold below cost". REPLACE THEM FROM THE REAL RATE DECK BEFORE
-- ENABLING A DESTINATION, and treat a missing prefix as uncallable rather than
-- cheap — see `voice_rate_for()`.

create table if not exists public.voice_rates (
  -- E.164 prefix WITHOUT the leading '+'. Longest match wins, so a premium
  -- sub-range ('35191') can override its country ('351') without a special case.
  prefix                text primary key,
  iso2                  text not null,
  label                 text not null,
  -- What Telnyx charges US per minute, USD.
  wholesale_usd_per_min numeric(10,5) not null check (wholesale_usd_per_min >= 0),
  -- Covered by the plan's minute allowance instead of the wallet. True only for
  -- NANP: that is what the $9.99 subscription actually sells.
  covered_by_allowance  boolean not null default false,
  -- 🔴 THE MARGIN LIVES HERE AND NOWHERE ELSE. A constant duplicated across
  -- files WILL drift — this repo has paid for that with CREDIT_DIVISOR and
  -- MAX_WHOLESALE_CENTS. Generated in the schema means the client, the quote
  -- endpoint and the settlement path cannot disagree about the price.
  --   5.0  = the margin (owner decision 2026-08-17)
  --   0.40 = NET_USD_PER_CREDIT, the MEASURED net per credit after Apple's cut
  credits_per_min numeric(10,4)
    generated always as (round(wholesale_usd_per_min * 5.0 / 0.40, 4)) stored,
  enabled               boolean not null default false,
  updated_at            timestamptz not null default now()
);

comment on column public.voice_rates.enabled is
  'Telnyx outbound voice profiles allow US/CA ONLY by default, and many '
  'destinations need Level 2 verification before they activate. A row is a '
  'PRICE, not permission — never dial a prefix whose destination has not been '
  'enabled at the provider, or the call fails after the credits are reserved.';

-- ── The catalogue. Conservative, provisional, fail-closed. ────────────────
insert into public.voice_rates (prefix, iso2, label, wholesale_usd_per_min, covered_by_allowance, enabled) values
  -- NANP: the plan's own territory. Priced for reference only — these are paid
  -- out of the minute allowance and never touch the wallet.
  ('1',   'US', 'United States & Canada', 0.01000, true,  true),
  -- Western Europe, fixed-line. Mobile termination is dearer nearly everywhere,
  -- so these are set at roughly mobile rates rather than landline: a single
  -- rate per country that is wrong LOW on mobile would lose money on the calls
  -- people actually make.
  ('33',  'FR', 'France',         0.06000, false, false),
  ('44',  'GB', 'United Kingdom', 0.06000, false, false),
  ('49',  'DE', 'Germany',        0.06000, false, false),
  ('34',  'ES', 'Spain',          0.06000, false, false),
  ('39',  'IT', 'Italy',          0.06000, false, false),
  ('351', 'PT', 'Portugal',       0.08000, false, false),
  ('31',  'NL', 'Netherlands',    0.06000, false, false),
  ('32',  'BE', 'Belgium',        0.08000, false, false),
  ('41',  'CH', 'Switzerland',    0.08000, false, false),
  ('43',  'AT', 'Austria',        0.06000, false, false),
  ('353', 'IE', 'Ireland',        0.06000, false, false),
  ('45',  'DK', 'Denmark',        0.05000, false, false),
  ('46',  'SE', 'Sweden',         0.05000, false, false),
  ('47',  'NO', 'Norway',         0.06000, false, false),
  ('358', 'FI', 'Finland',        0.08000, false, false),
  ('48',  'PL', 'Poland',         0.05000, false, false),
  ('420', 'CZ', 'Czechia',        0.06000, false, false),
  ('30',  'GR', 'Greece',         0.06000, false, false),
  ('40',  'RO', 'Romania',        0.06000, false, false),
  ('36',  'HU', 'Hungary',        0.06000, false, false),
  ('359', 'BG', 'Bulgaria',       0.06000, false, false),
  ('385', 'HR', 'Croatia',        0.08000, false, false),
  ('421', 'SK', 'Slovakia',       0.06000, false, false),
  ('386', 'SI', 'Slovenia',       0.08000, false, false),
  ('370', 'LT', 'Lithuania',      0.08000, false, false),
  ('371', 'LV', 'Latvia',         0.08000, false, false),
  ('372', 'EE', 'Estonia',        0.08000, false, false),
  -- Rest of world, common destinations.
  ('61',  'AU', 'Australia',      0.04000, false, false),
  ('64',  'NZ', 'New Zealand',    0.04000, false, false),
  ('81',  'JP', 'Japan',          0.05000, false, false),
  ('82',  'KR', 'South Korea',    0.04000, false, false),
  ('65',  'SG', 'Singapore',      0.04000, false, false),
  ('852', 'HK', 'Hong Kong',      0.04000, false, false),
  ('91',  'IN', 'India',          0.03000, false, false),
  ('55',  'BR', 'Brazil',         0.06000, false, false),
  ('52',  'MX', 'Mexico',         0.06000, false, false),
  ('54',  'AR', 'Argentina',      0.08000, false, false),
  ('56',  'CL', 'Chile',          0.06000, false, false),
  ('57',  'CO', 'Colombia',       0.06000, false, false),
  ('27',  'ZA', 'South Africa',   0.08000, false, false),
  ('212', 'MA', 'Morocco',        0.20000, false, false),
  ('216', 'TN', 'Tunisia',        0.25000, false, false),
  ('213', 'DZ', 'Algeria',        0.25000, false, false),
  ('90',  'TR', 'Turkey',         0.06000, false, false),
  ('972', 'IL', 'Israel',         0.05000, false, false),
  ('971', 'AE', 'United Arab Emirates', 0.15000, false, false),
  ('20',  'EG', 'Egypt',          0.20000, false, false),
  ('234', 'NG', 'Nigeria',        0.15000, false, false),
  ('254', 'KE', 'Kenya',          0.15000, false, false)
on conflict (prefix) do nothing;

create index if not exists voice_rates_enabled_idx
  on public.voice_rates (prefix) where enabled;

-- ── Longest-prefix lookup. ────────────────────────────────────────────────
-- FAILS CLOSED: an unmatched destination returns NULL and the caller must
-- refuse the call. Defaulting an unknown prefix to a cheap rate is exactly how
-- a $3.62/min premium range gets billed at $0.06 — the whole reason IRSF works.
-- ⚠️ `returns SETOF`, NOT `returns public.voice_rates`. A scalar composite
-- return yields ONE ALL-NULL ROW when nothing matches, so `if not found` never
-- fires and the caller proceeds with a null rate — fail-OPEN, in the one
-- function whose entire job is to fail closed. Verified live before this was
-- changed: `select count(*) from voice_rate_for('+999…')` returned 1.
-- With SETOF, no match is zero rows and `not found` means what it says.
create or replace function public.voice_rate_for(p_e164 text)
returns setof public.voice_rates
language sql
stable
security definer
set search_path = public
as $$
  select r.* from public.voice_rates r
   where ltrim(p_e164, '+') like r.prefix || '%'
   order by length(r.prefix) desc
   limit 1;
$$;

revoke execute on function public.voice_rate_for(text) from public, anon, authenticated;

-- ── What clients may read. ────────────────────────────────────────────────
-- 🔴 THE BASE TABLE PUBLISHES OUR WHOLESALE COST. `routes` and `esim_plans`
-- both leak exactly that to anyone holding the publishable key, and both are
-- still open because the fix needs a client release first. This table is NEW,
-- so it gets the `my_line` treatment from day one: SELECT is revoked outright
-- and clients read a view that carries the retail price and nothing else.
revoke select on public.voice_rates from anon, authenticated;

create or replace view public.voice_rate_card as
  select prefix, iso2, label, credits_per_min, covered_by_allowance
    from public.voice_rates
   where enabled;

grant select on public.voice_rate_card to anon, authenticated;

comment on view public.voice_rate_card is
  'Retail-only projection of voice_rates. NEVER add wholesale_usd_per_min '
  'here — the view exists precisely because the base table is the cost book.';
