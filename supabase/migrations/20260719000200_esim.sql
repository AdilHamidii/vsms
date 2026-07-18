-- eSIM data-plan product line (SMSPool), sold via credits at 3x wholesale.
-- Kept fully separate from the OTP `orders` table — different lifecycle
-- (delivered instantly as a QR/LPA profile; validity in days from activation;
-- data-usage tracked, no 20-min refund window).

create type esim_status as enum (
  'provisioning', 'installed', 'active', 'depleted', 'expired', 'refunded', 'failed'
);

-- Catalog: one row per SMSPool plan tier. id == SMSPool numeric plan id (text).
create table public.esim_plans (
  id                  text primary key,        -- SMSPool plan id, e.g. '1107'
  name                text not null,           -- display, e.g. 'Austria'
  country_code        text,                    -- ISO cc for flag/grouping ('AT'); null/'region' for multi-country
  region              text,                    -- label for regional plans ('Asia'); null for single-country
  data_mb             int,                     -- allowance in MB (SMSPool GB * 1000)
  validity_days       int,
  speed               text,                    -- '3G/4G/5G'
  extendable          boolean not null default false,
  retail_credits      int,                     -- 3x wholesale, in credits
  last_cost_cents     int,
  smoothed_cost_cents int,
  status              text not null default 'active',   -- 'active' | 'hidden'
  last_checked_at     timestamptz,
  sort_order          int not null default 1000
);

create table public.esim_orders (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  provider          text not null default 'smspool',
  plan_id           text references public.esim_plans(id),
  smspool_tx        text,                      -- SMSPool transactionId
  cost_credits      int  not null check (cost_credits > 0),
  actual_cost_cents int,
  status            esim_status not null default 'provisioning',
  -- delivery payload (from /esim/profile)
  activation_code   text,                      -- full LPA string: LPA:1$smdp$token
  smdp_address      text,
  matching_id       text,                      -- the activation token
  apn               text,
  -- usage (from /esim/profile remainingData/totalData)
  data_total_mb     int,
  data_used_mb      int,
  activated         boolean not null default false,
  activated_at      timestamptz,
  expires_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index esim_orders_user_idx on public.esim_orders(user_id, created_at desc);

alter table public.esim_plans  enable row level security;
alter table public.esim_orders enable row level security;

-- Catalog is public (fetched with the publishable key, like services/routes).
create policy "esim_plans: public read" on public.esim_plans
  for select using (true);
-- Orders are private to the buyer. All writes go through SECURITY DEFINER /
-- service-role edge functions.
create policy "esim_orders: self read" on public.esim_orders
  for select to authenticated using (user_id = (select auth.uid()));
