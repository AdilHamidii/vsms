-- Hide google/us (owner decision 2026-09-21).
--
-- It delivered ZERO codes out of 25 SETTLED orders in the 14 days to
-- 2026-09-21 (12 cancelled, 13 expired), on 20 orders from the last 7 days
-- alone — the highest-volume route in the app over that week and the only one
-- with a completely empty column. Per-try delivery across the whole catalogue
-- in the same week was 15 of 86.
--
-- ⚠️ THIS IS A DELIBERATE EXCEPTION TO "label, don't hide", so it must not be
-- read as re-opening auto-hide for poor delivery. That rule exists because
-- hiding a bad country regenerates the problem — the next-cheapest route
-- inherits the traffic and you have thrown away the only measurement you had.
-- The distinction here is the SAMPLE: 0 of 25 settled is not a route that
-- performs badly, it is a route that has never once worked, and it is being
-- hidden by hand on the owner's instruction rather than by a rule. Nothing
-- auto-hides; no threshold is introduced.
--
-- It costs us no cash today — 5sim refunds the wholesale on both the cancel
-- and the expiry path, so all 25 were free to us. What it costs is the user:
-- google/us is priced at 7 credits (~$2.80 of the buyer's money per attempt,
-- refunded each time), and a first-time buyer who spends their pack here gets
-- nothing and does not come back. That is the same leak the delivery explainer
-- was built for.
--
-- ⚠️ The route's own numbers do NOT predict this, which is why the hide has to
-- be manual: 5sim publishes pool_rate_pct = 41 (Medium band) and the wholesale
-- is healthy. The vendor's figure and our outcome disagree completely here.
-- Re-check before ever unhiding:
--   select status, count(*), count(*) filter (where otp is not null)
--     from orders where service_id='google' and country_id='us'
--      and created_at > now() - interval '30 days' group by 1;

update public.routes
   set status = 'hidden'
 where service_id = 'google' and country_id = 'us';

-- 🔴 The status write ALONE does not hold. `sync-prices` and the evidence
-- un-hide branches re-activate a route that prices and stocks fine, and
-- `sync-5sim` runs hourly — so without this second half the route is back
-- inside the hour with nothing logging why. `blocked_routes` is the kill list
-- those branches consult, and it is the only guard that survives the sync.
-- Nothing writes it from code; it is a hand-maintained list, so appending is
-- safe here.
update public.app_config
   set value = value || '["google|us"]'::jsonb
 where key = 'blocked_routes'
   and not (value ? 'google|us');
