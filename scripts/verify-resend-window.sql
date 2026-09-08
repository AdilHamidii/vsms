-- Behavioural checks for the second-code resend window.
--
--   supabase db query --linked --file scripts/verify-resend-window.sql
--
-- Everything happens inside a transaction that ROLLS BACK — this runs against
-- production. A structural check cannot catch this class: the columns can exist
-- and be perfectly correct while nothing reads them, which is exactly how
-- sync-telnyx-cdr ran green for twenty days matching nothing.
begin;

do $$
declare
  v_user uuid;
  v_open uuid;
  v_lapsed uuid;
  v_none uuid;
  n int;
begin
  select id into v_user from auth.users limit 1;
  if v_user is null then raise exception 'no users to test against'; end if;

  -- An eligible pool (virtual51), window open.
  insert into public.orders
    (user_id, service_id, country_id, provider, operator_used, status, otp,
     smspva_number, smspva_id, cost_credits, expires_at, resend_watch_until,
     otp_history)
  values
    (v_user, 'whatnot', 'us', '5sim', 'virtual51', 'received', '111111',
     '+15550000001', 'test-resend-open', 1, now() + interval '8 minutes',
     now() + interval '5 minutes',
     '[{"code":"111111","text":null,"at":"2026-09-08T00:00:00Z"}]'::jsonb)
  returning id into v_open;

  -- An eligible pool whose window has already lapsed.
  insert into public.orders
    (user_id, service_id, country_id, provider, operator_used, status, otp,
     smspva_number, smspva_id, cost_credits, expires_at, resend_watch_until)
  values
    (v_user, 'whatnot', 'us', '5sim', 'virtual51', 'received', '222222',
     '+15550000002', 'test-resend-lapsed', 1, now() + interval '8 minutes',
     now() - interval '1 minute')
  returning id into v_lapsed;

  -- An INELIGIBLE pool (virtual63 — the second-biggest source of real codes,
  -- and it sits alongside virtual51 on whatnot/us). Must carry no window.
  insert into public.orders
    (user_id, service_id, country_id, provider, operator_used, status, otp,
     smspva_number, smspva_id, cost_credits, expires_at, resend_watch_until)
  values
    (v_user, 'whatnot', 'us', '5sim', 'virtual63', 'received', '333333',
     '+15550000003', 'test-resend-ineligible', 1, now() + interval '8 minutes', null)
  returning id into v_none;

  -- 1. The sweep's selector picks up exactly the two windowed rows.
  select count(*) into n from public.orders
   where id in (v_open, v_lapsed, v_none) and resend_watch_until is not null;
  if n <> 2 then raise exception '1. expected 2 windowed rows, got %', n; end if;

  -- 2. Exactly one of them is lapsed, i.e. the one the sweep must close.
  select count(*) into n from public.orders
   where id in (v_open, v_lapsed) and resend_watch_until <= now();
  if n <> 1 then raise exception '2. expected 1 lapsed row, got %', n; end if;

  -- 3. The promotion claim is .eq(otp, <the code we polled against>). Against
  --    the CURRENT otp it matches once — the winning run.
  update public.orders
     set otp = '444444',
         otp_history = coalesce(otp_history, '[]'::jsonb) ||
                       jsonb_build_object('code','444444','text',null,'at',now()),
         resend_watch_until = now() + interval '5 minutes'
   where id = v_open and otp = '111111';
  get diagnostics n = row_count;
  if n <> 1 then raise exception '3. promotion should match once, matched %', n; end if;

  -- 4. A second run polling the SAME old code matches nothing — no double
  --    append, no double push. This is the property the claim exists for.
  update public.orders
     set otp = '444444',
         otp_history = coalesce(otp_history, '[]'::jsonb) ||
                       jsonb_build_object('code','444444','text',null,'at',now())
   where id = v_open and otp = '111111';
  get diagnostics n = row_count;
  if n <> 0 then raise exception '4. double promotion should match 0, matched %', n; end if;

  -- 5. History accumulated rather than replaced, and otp holds the NEWEST.
  select jsonb_array_length(otp_history) into n from public.orders where id = v_open;
  if n <> 2 then raise exception '5. expected 2 history entries, got %', n; end if;
  perform 1 from public.orders where id = v_open and otp = '444444';
  if not found then raise exception '5. otp should hold the newest code'; end if;

  -- 6. The clock RESTARTED on the promotion rather than running down. 5sim
  --    gives 5 minutes from the LAST message, so a window that merely survived
  --    would expire early and cut off a third code.
  perform 1 from public.orders
   where id = v_open and resend_watch_until > now() + interval '4 minutes';
  if not found then raise exception '6. promotion must reset the clock to +5m'; end if;

  -- 7. Closing the window nulls it, so the row leaves the sweep for good.
  update public.orders set resend_watch_until = null where id = v_lapsed;
  select count(*) into n from public.orders
   where id = v_lapsed and resend_watch_until is not null;
  if n <> 0 then raise exception '7. lapsed row should have left the sweep'; end if;

  -- 8. Status never changed. A new order_status value would throw on decode
  --    and take the Orders tab down on every shipped build.
  select count(*) into n from public.orders
   where id in (v_open, v_lapsed, v_none) and status <> 'received';
  if n <> 0 then raise exception '8. status must stay received, % rows differ', n; end if;

  raise notice 'all 8 resend-window checks passed';
end $$;

rollback;
