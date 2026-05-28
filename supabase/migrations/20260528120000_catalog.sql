-- Phase B: services, countries, routes catalog.
-- Public read, no writes (admin-only via service_role).
-- Route table tracks per-(service,country) availability + retail price; the
-- last_cost_cents column gets populated by the Phase C sync worker.

create table public.services (
    id            text primary key,
    name          text not null,
    category      text not null,
    smspva_code   text not null,
    tint          text not null,          -- hex like "#0088CC"
    glyph         text not null,          -- single uppercase letter
    cost          int  not null default 1 check (cost > 0),
    success_rate  int  not null default 95 check (success_rate between 0 and 100),
    eta_seconds   int  not null default 30 check (eta_seconds > 0),
    sort_order    int  not null default 100,
    created_at    timestamptz not null default now()
);

create table public.countries (
    id            text primary key,
    name          text not null,
    smspva_code   text not null,
    dial_code     text not null,
    flag          text not null,
    stock         text not null default 'high' check (stock in ('high','medium','low')),
    avg_seconds   int  not null default 30 check (avg_seconds > 0),
    sort_order    int  not null default 100,
    created_at    timestamptz not null default now()
);

create table public.routes (
    service_id      text references public.services(id) on delete cascade,
    country_id      text references public.countries(id) on delete cascade,
    retail_credits  int,
    status          text not null default 'active' check (status in ('active','hidden','premium')),
    last_cost_cents int,
    last_checked_at timestamptz,
    primary key (service_id, country_id)
);

alter table public.services  enable row level security;
alter table public.countries enable row level security;
alter table public.routes    enable row level security;

create policy "services: public read"  on public.services  for select to anon, authenticated using (true);
create policy "countries: public read" on public.countries for select to anon, authenticated using (true);
create policy "routes: public read"    on public.routes    for select to anon, authenticated using (true);

-- ===== Seed catalog =====
-- smspva_code values are best-effort guesses based on common SMSPVA mappings.
-- Verify against SMSPVA's actual service codes before Phase C goes live —
-- the codes drive every real activation call.

insert into public.services (id, name, category, smspva_code, tint, glyph, cost, success_rate, eta_seconds, sort_order) values
    ('telegram',  'Telegram',  'Messaging', 'opt29',  '#0088CC', 'T', 1, 98, 22, 10),
    ('whatsapp',  'WhatsApp',  'Messaging', 'opt0',   '#25D366', 'W', 1, 96, 28, 20),
    ('discord',   'Discord',   'Social',    'opt22',  '#5865F2', 'D', 1, 97, 25, 30),
    ('instagram', 'Instagram', 'Social',    'opt16',  '#E4405F', 'I', 1, 94, 35, 40),
    ('facebook',  'Facebook',  'Social',    'opt2',   '#1877F2', 'F', 1, 93, 38, 50),
    ('twitter',   'Twitter / X','Social',   'opt41',  '#0F0F0F', 'X', 1, 92, 42, 60),
    ('google',    'Google',    'Tech',      'opt15',  '#4285F4', 'G', 1, 99, 20, 70),
    ('microsoft', 'Microsoft', 'Tech',      'opt55',  '#0078D4', 'M', 1, 97, 26, 80),
    ('openai',    'OpenAI',    'AI',        'opt177', '#10A37F', 'O', 2, 95, 32, 90),
    ('tiktok',    'TikTok',    'Media',     'opt167', '#0F0F0F', 'T', 1, 91, 45, 100),
    ('amazon',    'Amazon',    'Commerce',  'opt19',  '#FF9900', 'A', 1, 96, 30, 110),
    ('uber',      'Uber',      'Transport', 'opt77',  '#0F0F0F', 'U', 1, 95, 33, 120);

insert into public.countries (id, name, smspva_code, dial_code, flag, stock, avg_seconds, sort_order) values
    ('us',  'United States',  'US',  '+1',   '🇺🇸',  'high',   25, 10),
    ('uk',  'United Kingdom', 'UK',  '+44',  '🇬🇧',  'high',   30, 20),
    ('de',  'Germany',        'DE',  '+49',  '🇩🇪',  'high',   28, 30),
    ('nl',  'Netherlands',    'NL',  '+31',  '🇳🇱',  'high',   30, 40),
    ('fr',  'France',         'FR',  '+33',  '🇫🇷',  'medium', 36, 50),
    ('it',  'Italy',          'IT',  '+39',  '🇮🇹',  'medium', 35, 60),
    ('es',  'Spain',          'ES',  '+34',  '🇪🇸',  'medium', 38, 70),
    ('pl',  'Poland',         'PL',  '+48',  '🇵🇱',  'medium', 40, 80),
    ('in',  'India',          'IN',  '+91',  '🇮🇳',  'high',   41, 90),
    ('br',  'Brazil',         'BR',  '+55',  '🇧🇷',  'medium', 52, 100);

-- Bulk-mark every (service, country) pair as active. Phase C will adjust
-- per real SMSPVA availability.
insert into public.routes (service_id, country_id, status)
select s.id, c.id, 'active'
from public.services s
cross join public.countries c;
