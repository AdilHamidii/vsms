-- Swap a rented line's phone number for a fresh one, paid in credits.
--
-- ── Why the row is MUTATED IN PLACE rather than replaced ───────────────────
--
-- `phone_lines_one_apple_line_per_user` is a partial unique index covering
-- provisioning|active|grace|past_due|suspended|releasing. So there is no
-- window in which a second row can exist for an Apple-billed user: an
-- insert-then-release design is rejected by the index, and a
-- release-then-insert design leaves the user with NO line if the insert
-- fails after the release. Mutating `e164` / `provider_number_id` on the
-- existing row sidesteps both, and it preserves the things that must not
-- move: the line id (the Telnyx connection is named `vsms-<line id>`), the
-- subscription binding, the allowance counters and the period dates.
--
-- ── Why `status` never changes ─────────────────────────────────────────────
--
-- Adding a 'swapping' value to `line_status` would mean shipping the client
-- first (the repo's standing client-first-schema-second rule), and it would
-- be a lie anyway: the OLD number keeps working right up to the cutover, so
-- the line really is active for the whole operation. In-flight state lives in
-- `line_number_swaps` instead, where a partial unique index makes concurrent
-- swaps impossible without touching the enum.
--
-- ── The money discipline ───────────────────────────────────────────────────
--
-- Claim and refund are ONE transaction, never two round trips — the rule this
-- repo has broken on eight separate close paths. `fail_line_swap` claims the
-- swap row and refunds inside the same function, so a worker killed midway
-- either did both or neither.

create table if not exists public.line_number_swaps (
  id                      uuid primary key default gen_random_uuid(),
  line_id                 uuid not null references public.phone_lines(id) on delete cascade,
  user_id                 uuid not null,
  state                   text not null default 'claimed',
  credits_charged         integer not null,
  old_e164                text,
  old_provider_number_id  text,
  new_e164                text,
  new_provider_number_id  text,
  -- Null while the OLD number is still ours. A sweep drains these; without a
  -- record here the old number is invisible the moment the row is mutated,
  -- which is exactly how a number bills forever with nothing pointing at it.
  old_released_at         timestamptz,
  failure                 text,
  created_at              timestamptz not null default now(),
  completed_at            timestamptz,
  constraint line_number_swaps_state_check
    check (state in ('claimed', 'done', 'failed'))
);

-- One swap in flight per line. A double-tap cannot buy two numbers.
create unique index if not exists line_number_swaps_one_inflight
  on public.line_number_swaps (line_id) where state = 'claimed';

-- The release sweep's working set.
create index if not exists line_number_swaps_release_pending
  on public.line_number_swaps (completed_at)
  where state = 'done' and old_provider_number_id is not null
        and old_released_at is null;

create index if not exists line_number_swaps_user_idx
  on public.line_number_swaps (user_id, created_at desc);

alter table public.line_number_swaps enable row level security;
revoke all on public.line_number_swaps from anon, authenticated;

insert into public.app_config (key, value) values
  ('line_swap_credits', '5'::jsonb),
  -- 0 = no cooldown. A cooldown is the abuse brake if rerolling ever gets
  -- expensive; it is off at launch because nobody has worn a number out yet.
  ('line_swap_cooldown_days', '0'::jsonb)
on conflict (key) do nothing;


-- ── begin_line_swap ────────────────────────────────────────────────────────
create or replace function public.begin_line_swap(p_user uuid, p_line uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner    uuid;
  v_status   public.line_status;
  v_e164     text;
  v_number   text;
  v_credits  integer;
  v_cooldown integer;
  v_last     timestamptz;
  v_bal      integer;
  v_swap     uuid;
begin
  if p_user is null or p_line is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- The same per-user lock `begin_order`, `begin_intl_call_claim` and
  -- `post_support_message` take. Without it a double-tap passes the in-flight
  -- check twice and charges twice.
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select user_id, status, e164, provider_number_id
    into v_owner, v_status, v_e164, v_number
    from public.phone_lines where id = p_line for update;
  if not found or v_owner <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;

  -- Deliberately ACTIVE only, not 'grace'. A line in grace is one Apple
  -- notification away from suspension, and buying a fresh number for a
  -- subscription that is lapsing spends float we may never recover.
  if v_status <> 'active' then
    return jsonb_build_object('ok', false, 'reason', 'line_not_active',
                              'status', v_status);
  end if;

  if exists (select 1 from public.line_number_swaps
              where line_id = p_line and state = 'claimed') then
    return jsonb_build_object('ok', false, 'reason', 'swap_in_progress');
  end if;

  select coalesce((value #>> '{}')::int, 5) into v_credits
    from public.app_config where key = 'line_swap_credits';
  v_credits := greatest(coalesce(v_credits, 5), 0);

  select coalesce((value #>> '{}')::int, 0) into v_cooldown
    from public.app_config where key = 'line_swap_cooldown_days';
  v_cooldown := greatest(coalesce(v_cooldown, 0), 0);

  if v_cooldown > 0 then
    select max(completed_at) into v_last
      from public.line_number_swaps
     where line_id = p_line and state = 'done';
    if v_last is not null and v_last > now() - make_interval(days => v_cooldown) then
      return jsonb_build_object(
        'ok', false, 'reason', 'swap_too_soon',
        'retry_after', v_last + make_interval(days => v_cooldown));
    end if;
  end if;

  select balance into v_bal from public.wallets where user_id = p_user;

  -- `wallet_spend_line` RAISES on a non-positive amount, so a free swap must
  -- skip the spend entirely rather than call it with 0 — the same shape as
  -- the free e-mail tier.
  if v_credits > 0 then
    if not public.wallet_spend_line(p_user, v_credits, p_line) then
      return jsonb_build_object(
        'ok', false, 'reason', 'insufficient_credits',
        'needed', v_credits, 'balance', coalesce(v_bal, 0),
        'shortfall', greatest(v_credits - coalesce(v_bal, 0), 0));
    end if;
  end if;

  insert into public.line_number_swaps (
    line_id, user_id, credits_charged, old_e164, old_provider_number_id)
  values (p_line, p_user, v_credits, v_e164, v_number)
  returning id into v_swap;

  -- `old_provider_number_id` is returned rather than re-read by the caller
  -- because this read happened under the row lock above. The caller releases
  -- that number after the cutover, and releasing the WRONG number is the most
  -- expensive mistake available here.
  return jsonb_build_object(
    'ok', true, 'swap_id', v_swap, 'credits_charged', v_credits,
    'old_e164', v_e164, 'old_provider_number_id', v_number,
    'balance', coalesce(v_bal, 0) - v_credits);
end;
$$;


-- ── complete_line_swap ─────────────────────────────────────────────────────
create or replace function public.complete_line_swap(
  p_swap uuid, p_new_e164 text, p_new_number_id text, p_order_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line uuid;
  v_n    integer;
begin
  if p_swap is null or p_new_e164 is null then return false; end if;

  -- The claim. Anything but exactly one row means another worker already
  -- settled this swap, and settling it twice would release the wrong number.
  update public.line_number_swaps
     set state = 'done',
         new_e164 = p_new_e164,
         new_provider_number_id = p_new_number_id,
         completed_at = now()
   where id = p_swap and state = 'claimed'
  returning line_id into v_line;
  get diagnostics v_n = row_count;
  if v_n <> 1 then return false; end if;

  -- `provider_voice_attached` goes FALSE because the new number's voice is
  -- not pointed at the connection yet. `provisionLineVoice` keys its repair
  -- step on exactly this flag, so leaving it true would mean the line never
  -- rings again and nothing would ever notice.
  update public.phone_lines
     set e164 = p_new_e164,
         provider_number_id = p_new_number_id,
         provider_order_id = coalesce(p_order_id, provider_order_id),
         provider_voice_attached = false,
         updated_at = now()
   where id = v_line;

  return true;
end;
$$;


-- ── fail_line_swap ─────────────────────────────────────────────────────────
-- Claim AND refund in one transaction. Splitting them is what leaves a
-- terminal row with the charge never returned, and no sweep revisits it.
create or replace function public.fail_line_swap(p_swap uuid, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user    uuid;
  v_line    uuid;
  v_credits integer;
  v_n       integer;
begin
  if p_swap is null then return false; end if;

  update public.line_number_swaps
     set state = 'failed',
         failure = coalesce(p_reason, 'unknown'),
         completed_at = now()
   where id = p_swap and state = 'claimed'
  returning user_id, line_id, credits_charged into v_user, v_line, v_credits;
  get diagnostics v_n = row_count;
  if v_n <> 1 then return false; end if;

  if coalesce(v_credits, 0) > 0 then
    perform public.wallet_move_line(v_user, v_credits, 'refund', v_line);
  end if;

  return true;
end;
$$;


-- ── mark_swap_old_released ─────────────────────────────────────────────────
create or replace function public.mark_swap_old_released(p_swap uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.line_number_swaps
     set old_released_at = now()
   where id = p_swap and old_released_at is null;
  return found;
end;
$$;


-- ── swaps_pending_release ──────────────────────────────────────────────────
-- The sweep's working set: a completed swap whose OLD number we still own.
create or replace function public.swaps_pending_release(p_limit integer default 20)
returns table (swap_id uuid, provider_number_id text, e164 text)
language sql
security definer
set search_path = public
as $$
  select id, old_provider_number_id, old_e164
    from public.line_number_swaps
   where state = 'done'
     and old_provider_number_id is not null
     and old_released_at is null
   order by completed_at
   limit greatest(coalesce(p_limit, 20), 1);
$$;

revoke execute on function public.begin_line_swap(uuid, uuid)                from public, anon, authenticated;
revoke execute on function public.complete_line_swap(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.fail_line_swap(uuid, text)                 from public, anon, authenticated;
revoke execute on function public.mark_swap_old_released(uuid)               from public, anon, authenticated;
revoke execute on function public.swaps_pending_release(integer)             from public, anon, authenticated;
