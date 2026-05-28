-- Phase C: orders table + status enum.
-- Lifecycle: waiting -> received | expired | refunded | canceled.

create type order_status as enum ('waiting','received','expired','refunded','canceled');

create table public.orders (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null references auth.users(id) on delete cascade,
    service_id      text not null references public.services(id),
    country_id      text not null references public.countries(id),
    smspva_id       text,
    smspva_number   text,
    cost_credits    int  not null check (cost_credits > 0),
    status          order_status not null default 'waiting',
    otp             text,
    raw_message     text,
    created_at      timestamptz not null default now(),
    expires_at      timestamptz not null default now() + interval '20 minutes',
    arrived_at      timestamptz,
    closed_at       timestamptz
);

create index orders_user_created_idx on public.orders(user_id, created_at desc);
create index orders_waiting_idx on public.orders(user_id) where status = 'waiting';
create index orders_polling_idx on public.orders(expires_at) where status = 'waiting';

alter table public.orders enable row level security;

create policy "orders: self read" on public.orders
    for select to authenticated using (user_id = auth.uid());

-- All writes happen via SECURITY DEFINER edge functions / RPCs.

-- Auto-expire a waiting order: refund credits, mark expired.
create or replace function public.expire_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    rec record;
begin
    select user_id, cost_credits, status
        into rec
        from public.orders
        where id = p_order
        for update;
    if not found or rec.status != 'waiting' then return; end if;

    update public.orders
        set status = 'expired', closed_at = now()
        where id = p_order;

    perform public.wallet_credit(rec.user_id, rec.cost_credits, 'refund', p_order);
end;
$$;
