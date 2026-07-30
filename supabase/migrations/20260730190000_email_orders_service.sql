-- email_orders needs to remember WHICH SERVICE the address was bought for.
--
-- The first cut stored only `site` (the domain we hand the provider, e.g.
-- "discord.com"). That is what the API needs but not what a history row needs:
-- rendering "Discord" with its logo requires the service id, and `site` cannot
-- be reversed into one reliably — several services can share a domain, and 11
-- visible services have no domain at all.
--
-- Nullable and ON DELETE SET NULL: a catalog cleanup must never delete a user's
-- order history, and rows written before this column existed keep working.

alter table public.email_orders
  add column if not exists service_id text
  references public.services(id) on delete set null;

create index if not exists email_orders_service_idx
  on public.email_orders (service_id)
  where service_id is not null;

comment on column public.email_orders.service_id is
  'Service the address was bought for. `site` is the provider-facing domain; '
  'this is what the UI renders. Nullable so catalog deletes cannot destroy history.';

-- begin_email_order now records it. Signature CHANGES (p_service added), so the
-- old one is dropped rather than left as an overload — two functions differing
-- only in arity is exactly how a caller ends up silently invoking the stale one.
drop function if exists public.begin_email_order(uuid, text, text, integer);

create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text, p_credits integer
) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_existing uuid; v_order uuid; v_ok boolean;
  v_free_today integer; v_cap integer;
begin
  if p_credits is null or p_credits < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id into v_existing from public.email_orders
   where user_id = p_user and site = p_site and domain = p_domain
     and status = 'waiting' and created_at > now() - interval '2 minutes'
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  if p_credits = 0 then
    select coalesce((value #>> '{}')::integer, 3) into v_cap
      from public.app_config where key = 'email_free_daily_cap';
    v_cap := coalesce(v_cap, 3);
    select count(*) into v_free_today from public.email_orders
     where user_id = p_user and cost_credits = 0
       and created_at >= date_trunc('day', now() at time zone 'utc');
    if v_free_today >= v_cap then
      return jsonb_build_object('ok', false, 'reason', 'free_limit_reached', 'cap', v_cap);
    end if;
  end if;

  insert into public.email_orders (user_id, service_id, site, domain, cost_credits, status)
  values (p_user, p_service, p_site, p_domain, p_credits, 'waiting')
  returning id into v_order;

  if p_credits > 0 then
    select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
    if not coalesce(v_ok, false) then
      delete from public.email_orders where id = v_order;
      return jsonb_build_object('ok', false, 'reason', 'insufficient');
    end if;
    update public.wallet_transactions set email_order_id = v_order
     where id = (select id from public.wallet_transactions
                  where user_id = p_user and reason = 'spend' and email_order_id is null
                  order by created_at desc, id desc limit 1);
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order);
end $$;

revoke execute on function public.begin_email_order(uuid, text, text, text, integer)
  from public, anon, authenticated;
