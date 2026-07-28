-- Country-level delivery evidence.
--
-- WHY THIS EXISTS
-- Steering falls back to a tie-break whenever the exact (service, country)
-- route has no measured record — which is almost always: 7 routes out of
-- ~17,800 have ever delivered. That tie-break was PRICE, so the app steered to
-- the cheapest country in the catalog. That is Colombia (rank 1 of 69, avg
-- wholesale $0.109), and measured 2026-07-28 its two measured routes read
-- 1-of-3 and 0-of-2.
--
-- Hiding Colombia does not fix it: the next-cheapest country simply inherits
-- the traffic, and where those have been measured they are worse (cl 2/13,
-- za 0/8, id 0/5, ph 0/2, bd 0/1). The floor regenerates. The tie-break has to
-- stop being about price.
--
-- Rolling route-level evidence up per country (client-side, off routes.success_*)
-- is not enough on its own, for two reasons measured 2026-07-28:
--   * A country's failures spread thinly across many routes, so no single route
--     reaches the 3-attempt threshold and the country stays invisible. The
--     client could see 12 of the 25 countries we have ever ordered from;
--     aggregating from `orders` raises that to 20.
--   * routes.success_* carries no provider scoping the client can apply, so a
--     client-side roll-up silently mixes in RETIRED providers. Indonesia's 5
--     failures are all smspool/virtualsms numbers we no longer sell — they say
--     nothing about what we would hand out today, and this function drops them
--     via active_sms_provider(). Same for 5 of South Africa's 8.
--
-- Mirrors refresh_service_delivery exactly, including all four evidence rules
-- learned the hard way (see CLAUDE.md):
--   1. is_code is `otp is not null`, NOT status='received' — a rescued code
--      lives on a canceled row.
--   2. Orders that never held a number are not evidence (`smspva_number is not
--      null`) — margin_too_low / stockout close in <1s and are not a delivery
--      outcome.
--   3. 30-day lookback, not 3 — at ~10 orders/day a short window leaves the
--      catalog with almost nothing measured.
--   4. The wipe is CONDITIONAL — a quiet country keeps its evidence rather
--      than being reset to NULL and becoming unrankable.

alter table public.countries
  add column if not exists observed_attempts integer,
  add column if not exists observed_codes    integer,
  add column if not exists observed_orders   integer;

comment on column public.countries.observed_attempts is
  'Conclusive orders in this country over the lookback (30d). Steering input only — never rendered as a per-route claim.';
comment on column public.countries.observed_codes is
  'Of those, how many produced a code (otp is not null, so rescued codes count).';
comment on column public.countries.observed_orders is
  'All orders that held a number, conclusive or not. Superset of observed_attempts.';

create or replace function public.refresh_country_delivery(
  p_lookback interval default '30 days'::interval,
  p_provider text default null
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_updated integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
begin
  -- Conditional wipe: only clear a country the new window genuinely has
  -- nothing to say about. An unconditional reset leaves quiet countries NULL
  -- and permanently unrankable.
  update public.countries c
  set observed_attempts = null, observed_codes = null, observed_orders = null
  where (c.observed_attempts is not null or c.observed_orders is not null)
    and not exists (
      select 1 from public.orders o
      where o.country_id = c.id
        and o.provider = v_provider
        and o.tier = 'standard'
        and o.created_at >= now() - p_lookback
        and o.closed_at is not null
        and o.smspva_number is not null
        and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
    );

  with classified as (
    select o.country_id,
      -- A rescued code sits on a `canceled` row, so status is not the signal.
      (o.otp is not null) as is_code,
      (
        o.otp is not null
        or o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from public.orders n
              where n.user_id = o.user_id
                and n.country_id = o.country_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from public.orders o
    where o.created_at >= now() - p_lookback
      and o.closed_at is not null
      and o.provider = v_provider
      and o.tier = 'standard'
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
      -- Orders that never held a number are not delivery evidence.
      and o.smspva_number is not null
  ),
  agg as (
    select country_id,
           count(*) filter (where is_conclusive) as attempts,
           count(*) filter (where is_code)       as codes,
           count(*)                              as orders
    from classified group by country_id
  ),
  upd as (
    update public.countries c
    set observed_attempts = agg.attempts,
        observed_codes    = agg.codes,
        observed_orders   = agg.orders
    from agg where agg.country_id = c.id
    returning 1
  )
  select count(*) into v_updated from upd;

  return v_updated;
end;
$function$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC, and anon/authenticated are members
-- of PUBLIC — so revoking from anon/authenticated alone is a NO-OP and the
-- function stays callable at /rest/v1/rpc/. Revoke from PUBLIC explicitly.
revoke execute on function public.refresh_country_delivery(interval, text)
  from public, anon, authenticated;
