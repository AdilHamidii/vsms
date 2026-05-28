-- Phase D: device tokens for APNs, plus pg_cron schedule for polling.

create table public.push_devices (
    id           bigserial primary key,
    user_id      uuid not null references auth.users(id) on delete cascade,
    token        text not null,
    environment  text not null check (environment in ('sandbox','production')),
    bundle_id    text not null,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (user_id, token)
);

create index push_devices_user_idx on public.push_devices(user_id);

alter table public.push_devices enable row level security;

create policy "push_devices: self read" on public.push_devices
    for select to authenticated using (user_id = auth.uid());

-- Cron infrastructure: pg_cron + pg_net + vault for the shared secret.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Seed the cron secret in vault if absent. Used by both the cron job's
-- header and the edge function to authenticate the call.
create extension if not exists pgcrypto with schema extensions;

do $$
begin
    if not exists (select 1 from vault.secrets where name = 'cron_secret') then
        perform vault.create_secret(
            encode(extensions.gen_random_bytes(32), 'hex'),
            'cron_secret'
        );
    end if;
end$$;

-- Helper that fetches our cron secret (for the cron job to read at fire time).
create or replace function private_cron_secret()
returns text
language sql
security definer
set search_path = vault, public
as $$
    select decrypted_secret::text
    from vault.decrypted_secrets
    where name = 'cron_secret'
    limit 1
$$;

-- Hardcoded project URL — substitute if you fork to a different Supabase ref.
-- (cron.schedule can't read env vars; this lives in the SQL.)
select cron.schedule(
    'relay-poll-active-orders',
    '* * * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/poll-active-orders',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    );
    $cmd$
);
