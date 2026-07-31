-- Hold Real-SIM-ONLY routes back until a client exists that can express the
-- constraint. Client-first, exactly like the two deferred column revokes.
--
-- The released build (1.5 / build 18) has no `real_sim_only` in its Route model,
-- so it renders the Standard chip AND preselects it — `checkoutPremium` defaults
-- to false and `defaultPremium` only ships in build 19. `create-order` then
-- refuses with `real_sim_required`, a code that build has no case for, so the
-- user reads the generic 409 copy: "Not available right now. Try a different
-- option."
--
-- That lands on facebook / instagram / whatsapp — together ~50% of order volume
-- — across 49 routes including facebook/us and instagram/us. The copy steers to
-- another COUNTRY, which is frequently another real-SIM-only route, while the
-- Real SIM chip that WOULD have worked sits unexplained on the same screen. No
-- money is at risk: the refusal precedes begin_order, so nothing is charged. It
-- is a dead-ended funnel on the highest-traffic services.
--
-- Hiding them restores exactly the state that existed before the tier — 47/47/43
-- standard-bookable routes for the three services, which was deliberate and
-- accepted. `sync-herosms` still WRITES `real_sim_only`, so flipping this flag
-- to true is all that is needed once build 19 is adopted. No deploy.
--
--   update public.app_config set value = 'true'::jsonb
--   where key = 'real_sim_only_sellable';
--
-- A missing key reads as false in `sync-herosms`, so the gate fails to the safe
-- side; this row exists so the switch is discoverable rather than implicit.

insert into public.app_config (key, value)
values ('real_sim_only_sellable', 'false'::jsonb)
on conflict (key) do nothing;
