-- 20260813100000_uber_uk_floor_and_stamp.sql
--
-- Owner request 2026-08-13: price uber/uk at 3 credits and reset its
-- statistics. Both halves would silently revert if done as bare UPDATEs, so
-- each goes through the mechanism that re-derives the value hourly:
--
-- ── Why uber/uk, and why 3 ───────────────────────────────────────────────────
--
-- The signup grant was restored to 2 credits on 2026-08-08, and `bestStarter`
-- (1.9+) resolves a 2-credit wallet to uber/uk — its pool publishes 83%, the
-- best affordable rate. Measured 08-09 → 08-13: 27 of 28 uber/uk orders in the
-- 30d window are brand-new accounts (11s–28min from signup), zero purchases,
-- wallet exactly 2 — the default-landed cohort, numbers nobody ever submitted
-- (see CLAUDE.md "The default-landed orders were numbers NOBODY EVER
-- SUBMITTED"). They had driven the route's visible record to "Worked 1 of 28
-- times" — evidence about our own steering, not the route.
--
-- At 3 credits the route sits above the 2-credit grant, so free wallets can no
-- longer land on it. ⚠️ THE PRICE FLOOR REGENERATES (CLAUDE.md, steering
-- section): the starter will now land the cohort on the next-best affordable
-- route, and `stamp_default_landed()`'s route list must learn THAT pair when
-- it is observed. The durable fix is 2.0 adoption — its client stamps
-- `from_default` itself.
--
-- ── 1. The price, via `app_config.route_price_floors` ────────────────────────
--
-- `sync-5sim` rewrites `retail_credits` from wholesale every hour (:07), and
-- uber/uk's ~5–8¢ pool computes to 2 credits — a bare UPDATE lasts under an
-- hour. The floor map (same "service|country" key shape as `blocked_routes`)
-- is read by sync-5sim as of this commit and applied as
-- max(computed, floor). A floor only ever RAISES retail, which only LOOSENS
-- the order-time ceiling (credits × NET / MIN_MARGIN grows with credits), so
-- it can never produce margin_too_low. The lockstep rule is bent only in the
-- safe direction — the same direction the cost ratchet already bends it.
-- ⚠️ Applied by sync-5sim ONLY; re-homing a floored route to another provider
-- silently drops the floor.

insert into public.app_config (key, value)
values ('route_price_floors', '{"uber|uk": 3}'::jsonb)
on conflict (key) do update set value = excluded.value;

-- Take effect now rather than at the next :07 run.
update public.routes
set retail_credits = greatest(coalesce(retail_credits, 1), 3)
where service_id = 'uber' and country_id = 'uk';

-- ── 2. The statistics, via the stamp + evidence exclusion ────────────────────
--
-- The evidence refreshes recompute route/service/country stats hourly from the
-- last 30 days of orders, already excluding `from_default = true`
-- (20260808170000). Wiping the columns without stamping the orders would
-- last one hour. So: add uber/uk to `stamp_default_landed()`'s observed
-- route list and re-run it — the function's own account-age (<60 min) guard
-- keeps veteran accounts' genuine uber/uk orders unflagged, and it never
-- overwrites a client-stamped value. Body identical to 20260808180000 except
-- for the added pair; see that migration's header for the full reasoning.

create or replace function public.stamp_default_landed()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_stamped integer;
begin
  with upd as (
    update public.orders o
    set from_default = true
    -- NEVER overwrite a client-stamped value. NULL means "not recorded"
    -- (pre-2.0); false means a 2.0+ client positively said the user chose
    -- this service. Only NULL is ours to fill in.
    where o.from_default is null
      -- the observed default-landing set; see the header before editing.
      -- ('uber','uk') added 2026-08-13: the 2-credit grant era's landing.
      and (o.service_id, o.country_id) in
        (('olx','us'), ('deliveroo','us'), ('deliveroo','ge'), ('uber','uk'))
      -- the grant-cohort era begins here
      and o.created_at >= timestamptz '2026-07-26'
      -- account age at order time. Catches the first order AND the
      -- same-session retries that follow it, which are the same event.
      and exists (
        select 1 from auth.users u
        where u.id = o.user_id
          and o.created_at - u.created_at < interval '60 minutes'
      )
    returning 1
  )
  select count(*) into v_stamped from upd;
  return v_stamped;
end;
$function$;

comment on function public.stamp_default_landed() is
  'Bridge until 2.0+ clients stamp orders.from_default themselves. Flags orders '
  'on the app''s observed default-landing routes placed by accounts under 60 '
  'minutes old. Never overwrites a client-stamped value, so it is a permanent '
  'no-op once 2.0 dominates. Called hourly from sync-prices.';

revoke execute on function public.stamp_default_landed() from public, anon, authenticated;

-- Backfill through the function, so the catch-up and the hourly job cannot
-- drift apart.
select public.stamp_default_landed();

-- Rebuild the evidence now rather than at the next hourly sync-prices run —
-- with the cohort excluded, the conditional wipe returns uber/uk (and the
-- service/country roll-ups) to "Not tested".
select public.refresh_evidence_all_providers(interval '30 days', 3);

-- ⚠️ The refresh alone does NOT clear this route, and the reason is a real gap
-- worth knowing: `refresh_route_observed_success`'s wipe fires only when ZERO
-- eligible orders remain in the window, while its write fires only at >= 2–3
-- conclusive ones. uber/uk sits between — exactly one eligible non-stamped
-- order (a 25h-old account, so the age heuristic rightly spares it) — so the
-- stale "1 of 28" would have survived both branches indefinitely. Clear it
-- explicitly; nothing re-writes these columns until real non-default evidence
-- reaches the thresholds, which is precisely the intended "Not tested" state.
update public.routes
set success_rate = null, rate_source = null, success_sample = null, success_codes = null
where service_id = 'uber' and country_id = 'uk' and rate_source = 'measured';
