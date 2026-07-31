-- Store for HeroSMS's own per-(service, country) deliverability numbers.
--
-- Source: GET /api/v1/stats/deliverability?service=&interval=&successCount=,
-- the endpoint behind their dashboard's Statistics panel. It is REAL but
-- session-scoped — all four API-key schemes return 401 Unauthenticated (see
-- CLAUDE.md). The vendor has been asked to open it to API keys and has only
-- acknowledged, so until then it is collected by hand, one service at a time.
--
-- WHY RAW. We have never seen the response body — only the rendered panel. This
-- codebase's most expensive recurring mistake is encoding a guess about a
-- vendor's vocabulary (the eSIM refund path shipped a status literal that was
-- not in the enum, discarded the error, and silently kept users' money). So
-- this stores the payload VERBATIM and maps nothing. The mapper gets written
-- once a real payload exists to read.
--
-- WHAT THIS IS FOR, and the line it must not cross: these are HeroSMS's
-- aggregates across ALL their customers, not our delivery. They are steering
-- input — deciding which countries we OFFER for a service — and must never
-- reach a badge. That is the same class of number as SMSPVA's seeded
-- per-country grade, which ranked as "proven", beat genuinely untested
-- countries, and had to be demoted to `.notTested`. Writing any of this into
-- routes.success_rate with rate_source='measured' would make the UI claim
-- "Worked X of Y times" about deliveries we never made.
--
-- Consumption is therefore CLIENT-SIDE and ships in 1.7: bestCountry(),
-- affordableFallbackCountry(), CountrySheet's "Best success" and the retry
-- picker are all in AppState. The one thing this can do server-side today is
-- inform blocked_routes, which every shipped build already honours.

-- One row per HeroSMS service code, merged independently so collection can be
-- paced (one service per 10 minutes, most-ordered first) and stop anywhere
-- without losing what came before. Partial data is useful immediately: 4
-- services cover 64% of all orders ever placed, 12 cover 88%.
create table if not exists public.vendor_deliverability (
  provider        text        not null default 'herosms',
  service_code    text        not null,
  params          jsonb       not null,
  payload         jsonb       not null,
  fetched_at      timestamptz not null default now(),
  primary key (provider, service_code)
);

alter table public.vendor_deliverability enable row level security;

-- No policy, and no grants to anon/authenticated. This is a competitor's
-- quality book; it has no business reaching a phone. Edge functions read it on
-- the service role, which bypasses RLS.
revoke all on public.vendor_deliverability from anon, authenticated;

comment on table public.vendor_deliverability is
  'Raw HeroSMS /api/v1/stats/deliverability payloads, collected by hand because '
  'the endpoint is session-scoped. Vendor aggregate across all their customers — '
  'STEERING INPUT ONLY, never a badge, never routes.success_rate.';

-- Merge exactly one service. Idempotent, and deliberately does not touch any
-- other service's row, so a paced collection run can be interrupted and resumed.
create or replace function public.merge_vendor_deliverability(
  p_service_code text,
  p_params       jsonb,
  p_payload      jsonb,
  p_provider     text default 'herosms')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_countries int;
begin
  if p_service_code is null or btrim(p_service_code) = '' then
    return jsonb_build_object('ok', false, 'reason', 'missing_service_code');
  end if;
  -- Reject an empty payload rather than storing it: a failed fetch that lands
  -- as `{}` would look identical to "this service has no deliverability data",
  -- and the whole point of collecting is to distinguish those.
  if p_payload is null or p_payload = '{}'::jsonb or p_payload = '[]'::jsonb then
    return jsonb_build_object('ok', false, 'reason', 'empty_payload');
  end if;

  insert into public.vendor_deliverability (provider, service_code, params, payload, fetched_at)
  values (p_provider, p_service_code, coalesce(p_params, '{}'::jsonb), p_payload, now())
  on conflict (provider, service_code) do update
    set params = excluded.params, payload = excluded.payload, fetched_at = excluded.fetched_at;

  -- Best-effort shape probe, logged not trusted. Tells us on the FIRST real
  -- payload whether it is an array or an object, which is what the mapper needs.
  v_countries := case
    when jsonb_typeof(p_payload) = 'array'  then jsonb_array_length(p_payload)
    when jsonb_typeof(p_payload) = 'object' then (select count(*) from jsonb_object_keys(p_payload))
    else 0 end;

  return jsonb_build_object(
    'ok', true, 'service_code', p_service_code,
    'payload_type', jsonb_typeof(p_payload), 'top_level_entries', v_countries);
end;
$function$;

revoke execute on function public.merge_vendor_deliverability(text, jsonb, jsonb, text)
  from public, anon, authenticated;

-- Collection worklist: which service to pull next, most-ordered first, skipping
-- anything already collected in the last 7 days. Answers "where am I up to"
-- for a paced run without anyone having to track it by hand.
create or replace function public.vendor_deliverability_worklist(p_limit integer default 20)
returns table(rank bigint, service_id text, service_code text, orders bigint, collected_at timestamptz)
language sql
stable security definer
set search_path to 'public'
as $function$
  with vol as (
    select o.service_id, count(*) n
      from public.orders o
     where o.smspva_number is not null
       and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     group by 1
  )
  select row_number() over (order by coalesce(vol.n, 0) desc, s.id) as rank,
         s.id, s.herosms_code, coalesce(vol.n, 0) as orders, vd.fetched_at
    from public.services s
    left join vol on vol.service_id = s.id
    left join public.vendor_deliverability vd
           on vd.service_code = s.herosms_code and vd.provider = 'herosms'
   where s.herosms_code is not null
     and s.visible
     and (vd.fetched_at is null or vd.fetched_at < now() - interval '7 days')
   order by coalesce(vol.n, 0) desc, s.id
   limit p_limit;
$function$;

revoke execute on function public.vendor_deliverability_worklist(integer)
  from public, anon, authenticated;
