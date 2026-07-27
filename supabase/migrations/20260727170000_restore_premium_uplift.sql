-- Restore the Real-SIM (premium) 20% uplift.
--
-- Measured 2026-07-27: `premium_credits = retail_credits` on 16,124 of 16,124
-- active priced routes — ZERO carried the intended 1.20x. PREMIUM_MULTIPLIER in
-- sync-smspva-operators and migration 20260725160000 are both correct; what
-- broke it was the divisor backfill run during the 3x -> 6x reprice, whose
-- floor `greatest(retail_credits, ...)` contained no 1.2 term and so overwrote
-- the uplift with the standard price.
--
-- It could not self-heal: sync-smspva-operators is cursor-chunked at 12
-- countries across 6 nightly slots, and until today its MAX_WHOLESALE_CENTS was
-- still 400 while sync-prices had moved to 750, so the whole $4.00-$7.50 band
-- sat outside its window entirely.
--
-- Why this matters even though premium has never sold (0 orders lifetime):
-- price parity makes Standard the irrational choice — identical cost, but
-- premium pins a named carrier, fails fast, and is never silently downgraded to
-- a Donor* VoIP pool. Parity is strictly the worst of the three options
-- (uplift / remove the tier / parity).
--
-- Direction is safe: create-order's premium ceiling is
-- `premium_credits * NET / MIN_MARGIN`, so RAISING premium_credits RAISES the
-- ceiling. It cannot cause margin_too_low — that is the failure mode documented
-- for lowering it.

update public.routes
set premium_credits = greatest(
      ceil(retail_credits * 1.20),
      greatest(1, least(999, ceil(smspva_operator_cents/100.0/0.05))))
where premium_credits is not null
  and smspva_operator_cents is not null
  and retail_credits is not null;

-- Assert: nothing at parity, nothing priced under its own wholesale.
do $$
declare v_parity integer; v_under integer;
begin
  select count(*) filter (where premium_credits = retail_credits),
         count(*) filter (where premium_credits * 0.05 < smspva_operator_cents/100.0)
    into v_parity, v_under
  from public.routes
  where status = 'active' and premium_credits is not null and retail_credits is not null;

  if v_parity > 0 then
    raise exception 'premium uplift did not apply: % routes still at parity', v_parity;
  end if;
  if v_under > 0 then
    raise exception 'premium priced under wholesale on % routes', v_under;
  end if;
end $$;
