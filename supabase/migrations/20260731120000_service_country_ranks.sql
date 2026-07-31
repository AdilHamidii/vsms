-- Client-readable projection of HeroSMS's per-(service, country) deliverability.
--
-- `vendor_deliverability` holds raw payloads and is RLS-locked with no client
-- grants — it is a competitor's quality book. This table is the narrow slice the
-- app actually needs: service, country, percent, rank. 387 rows today.
--
-- ⚠️ EXPOSURE, stated plainly because it is a real trade: rendering these
-- figures in the app publishes HeroSMS's quality data to anyone holding the
-- publishable key. That is inherent to the feature — you cannot show users a
-- number without shipping it — but it is worth knowing we are doing it, not
-- least because we are simultaneously asking them to expose the endpoint by API.
-- Only the four columns below ship; the raw payloads, intervals and filters stay
-- server-side.
--
-- ⚠️ THE TWO RULES THAT GOVERN EVERY CONSUMER OF THIS TABLE:
--
-- 1. It is HeroSMS's aggregate across ALL their customers, NOT our delivery. It
--    must never be written into routes.success_rate, never scored by
--    SuccessBadge, and never rendered in the same visual language as
--    "Worked X of Y times". The app's own badge is a claim about orders WE
--    placed; this is a third party's report. They are different kinds of
--    statement and the UI must keep them apart — that distinction is exactly
--    what the seeded SMSPVA grade violated when it ranked never-sold routes as
--    "proven" and had to be demoted to .notTested.
--
-- 2. ABSENCE MEANS NOTHING. The source is a top-10 ranking gated at ">50
--    successful activations" in the window, so a country is missing either
--    because it ranked 11th or because it had too little traffic to score. No
--    consumer may treat a missing row as a low rate.
create table if not exists public.service_country_ranks (
  service_id     text        not null references public.services(id)  on delete cascade,
  country_id     text        not null references public.countries(id) on delete cascade,
  vendor_percent numeric(5,2) not null,
  vendor_rank    smallint    not null,
  provider       text        not null default 'herosms',
  updated_at     timestamptz not null default now(),
  primary key (service_id, country_id, provider)
);

alter table public.service_country_ranks enable row level security;

-- authenticated only. anon gets nothing: the app is past AuthGate before it can
-- render any of this, and there is no reason to serve a provider's quality book
-- to an unauthenticated caller. (Contrast `routes`, which carries a `public
-- read` policy and is therefore readable with no account at all.)
grant select on public.service_country_ranks to authenticated;
revoke all on public.service_country_ranks from anon;

drop policy if exists "service_country_ranks: read" on public.service_country_ranks;
create policy "service_country_ranks: read" on public.service_country_ranks
  for select to authenticated using (true);

comment on table public.service_country_ranks is
  'HeroSMS per-(service,country) success rates, top-10 per service. VENDOR AGGREGATE '
  'across all their customers — steering input and an attributed display, never the '
  'app''s own delivery badge. A MISSING ROW MEANS NO INFORMATION, not a low rate.';

-- Rebuild from the raw payloads. Called after a collection run; safe to repeat.
create or replace function public.refresh_service_country_ranks()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_rows int; v_services int;
begin
  -- Full rebuild inside one transaction. A service whose latest payload came
  -- back empty correctly ends up with NO rows, which is the honest encoding of
  -- "no country cleared the threshold" — and is why this deletes rather than
  -- upserting: an upsert would leave yesterday's ranking behind forever.
  delete from public.service_country_ranks where provider = 'herosms';

  insert into public.service_country_ranks
    (service_id, country_id, vendor_percent, vendor_rank, provider, updated_at)
  select m.service_id, m.country_id, m.vendor_percent, m.vendor_rank, 'herosms', now()
    from public.vendor_deliverability_mapped m
  on conflict (service_id, country_id, provider) do update
    set vendor_percent = excluded.vendor_percent,
        vendor_rank    = excluded.vendor_rank,
        updated_at     = excluded.updated_at;

  select count(*), count(distinct service_id) into v_rows, v_services
    from public.service_country_ranks where provider = 'herosms';

  return jsonb_build_object('rows', v_rows, 'services', v_services);
end;
$function$;

revoke execute on function public.refresh_service_country_ranks()
  from public, anon, authenticated;

select public.refresh_service_country_ranks();
