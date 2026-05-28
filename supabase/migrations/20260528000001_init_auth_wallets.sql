-- Phase A: profiles, wallets, wallet_transactions
-- Auth users themselves are managed by Supabase auth.users.

create table public.profiles (
    user_id      uuid primary key references auth.users(id) on delete cascade,
    display_name text,
    created_at   timestamptz not null default now()
);

create table public.wallets (
    user_id     uuid primary key references auth.users(id) on delete cascade,
    balance     int  not null default 0 check (balance >= 0),
    updated_at  timestamptz not null default now()
);

create type wallet_reason as enum ('signup_bonus', 'purchase', 'spend', 'refund', 'adjustment');

create table public.wallet_transactions (
    id          bigserial primary key,
    user_id     uuid not null references auth.users(id) on delete cascade,
    delta       int  not null,
    reason      wallet_reason not null,
    order_id    uuid,
    iap_receipt_id bigint,
    created_at  timestamptz not null default now()
);

create index wallet_transactions_user_idx on public.wallet_transactions(user_id, created_at desc);

-- On a new auth.user, create their profile + wallet seeded with 5 free credits.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (user_id, display_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)));

    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, 5, now());

    insert into public.wallet_transactions (user_id, delta, reason)
    values (new.id, 5, 'signup_bonus');

    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- Atomic wallet spend. Returns true on success, false if insufficient.
create or replace function public.wallet_spend(p_user uuid, p_amount int, p_reason wallet_reason, p_order uuid default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    updated_rows int;
begin
    update public.wallets
    set balance = balance - p_amount, updated_at = now()
    where user_id = p_user and balance >= p_amount;

    get diagnostics updated_rows = row_count;
    if updated_rows = 0 then
        return false;
    end if;

    insert into public.wallet_transactions (user_id, delta, reason, order_id)
    values (p_user, -p_amount, p_reason, p_order);

    return true;
end;
$$;

-- Atomic wallet credit (refund / purchase / adjustment).
create or replace function public.wallet_credit(p_user uuid, p_amount int, p_reason wallet_reason, p_order uuid default null, p_receipt bigint default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.wallets
    set balance = balance + p_amount, updated_at = now()
    where user_id = p_user;

    insert into public.wallet_transactions (user_id, delta, reason, order_id, iap_receipt_id)
    values (p_user, p_amount, p_reason, p_order, p_receipt);
end;
$$;

-- ===== RLS =====
alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;

create policy "profiles: self read"  on public.profiles
    for select to authenticated using (user_id = auth.uid());
create policy "profiles: self write" on public.profiles
    for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "wallets: self read" on public.wallets
    for select to authenticated using (user_id = auth.uid());

create policy "wallet_transactions: self read" on public.wallet_transactions
    for select to authenticated using (user_id = auth.uid());
