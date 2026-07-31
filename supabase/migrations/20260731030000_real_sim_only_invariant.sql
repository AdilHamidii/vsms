-- A real-SIM-only route MUST carry a premium price.
--
-- `create-order` refuses tier=standard when `real_sim_only` is true, and
-- refuses tier=premium when `premium_credits` is null. A route with
-- `real_sim_only = true` and no premium price is therefore unbookable on EITHER
-- tier — and the client would not even know to hide the Standard chip, because
-- `AppState.realSimOnly` requires both fields. The user taps Standard and gets
-- `real_sim_required`, taps Real SIM and gets `premium_unavailable`: a dead end
-- with no visible way out.
--
-- `sync-herosms` avoids this by construction (it only sets `real_sim_only` when
-- a carrier was found, and prices the tier off the same carrier), but nothing
-- ENFORCED it — the two consumers just happened to agree. 0 live rows violate
-- it today; this makes it impossible to introduce one.
alter table public.routes
  add constraint routes_real_sim_only_needs_premium
  check (not real_sim_only or premium_credits is not null) not valid;

alter table public.routes validate constraint routes_real_sim_only_needs_premium;
