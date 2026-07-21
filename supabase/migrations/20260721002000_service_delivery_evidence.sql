-- Per-SERVICE delivery evidence, so the app can warn about the specific thing
-- a user is buying instead of making one generic claim to everyone.
--
-- Per-ROUTE sample is unreachable (5,258 routes, ~25 orders/day) but per
-- SERVICE it is decisive. A cancel counts as conclusive if it ran >=240s (no
-- SMS came) or the user re-ordered the same service within 10 minutes (the
-- number-shopping signature — the platform rejected the number at its form).
--
-- SCOPED TO provider='smspool': evidence must describe the provider that will
-- actually serve the order. Counting every provider produced a false promise —
-- Leboncoin would have shown "21 of the last 34 attempts got a code" when all
-- 34 were on SMSPVA and SMSPool has served it ZERO times. Services with no
-- history on the active provider now correctly say nothing.
alter table public.services
  add column if not exists observed_codes    integer,
  add column if not exists observed_attempts integer;

comment on column public.services.observed_attempts is
  'Conclusive attempts on the ACTIVE provider; NULL or small = no claim made.';

create or replace function public.refresh_service_delivery(
  p_lookback interval default interval '30 days'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer;
begin
  update public.services
  set observed_attempts = null, observed_codes = null
  where observed_attempts is not null;

  with classified as (
    select o.service_id,
      (o.status = 'received') as is_code,
      (
        o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from public.orders n
              where n.user_id = o.user_id
                and n.service_id = o.service_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from public.orders o
    where o.created_at >= now() - p_lookback
      and o.closed_at is not null
      and o.provider = 'smspool'
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
  ),
  agg as (
    select service_id,
           count(*) filter (where is_conclusive) as attempts,
           count(*) filter (where is_code)       as codes
    from classified group by service_id
  ),
  upd as (
    update public.services s
    set observed_attempts = agg.attempts,
        observed_codes    = agg.codes
    from agg where s.id = agg.service_id
    returning 1
  )
  select count(*) into v_updated from upd;
  return v_updated;
end;
$$;

revoke execute on function public.refresh_service_delivery(interval)
  from public, anon, authenticated;
