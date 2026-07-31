-- Sell the Real SIM tier on HeroSMS routes, and stop hiding what it can serve.
--
-- Checkout has rendered Standard / Real SIM chips at a +20% uplift since
-- `859fa29`, and that UI is in the 1.5 archive currently awaiting review — so
-- populating `premium_credits` on HeroSMS routes makes the choice appear with
-- no client change the moment 1.5 ships. `create-order` refused the tier for
-- HeroSMS only because there was no carrier to pin; there is now
-- (`herosms_real_operator`).

-- Routes where the VoIP tier must not be offered at all: the service rejects
-- VoIP outright (Meta's properties). These used to be HIDDEN when they had no
-- real-SIM stock; with a Real SIM tier they become sellable as real-only, which
-- recovers catalog breadth we were rendering as "Unavailable".
alter table public.routes
  add column if not exists real_sim_only boolean not null default false;

comment on column public.routes.real_sim_only is
  'Service rejects VoIP, so only the Real SIM tier may be sold here. The client '
  'hides the Standard chip and create-order refuses tier=standard.';

-- Operators known to be VoIP rather than a mobile carrier. `textnow` alone is
-- ~96% of the US pool (458,985 of ~477,000 for badoo) and is a VoIP texting
-- service, which is the bulk of the problem in one name.
--
-- Classification is BY EXCLUSION and is the weakest part of this feature: an
-- operator absent from this list is assumed to be a real carrier. That is why
-- the tier's copy promises "a named mobile carrier", not a delivery rate, and
-- why `orders.route_physical_count` exists to measure whether it actually helps.
insert into public.app_config (key, value)
values ('voip_operators', '["textnow","moabits","joltmobile","smartone","free","virtual","voip"]'::jsonb)
on conflict (key) do nothing;

-- The US list is no longer a FORCE — it becomes the seed of the per-country
-- real-carrier resolution, which now derives candidates from getOperators for
-- every country rather than a hand-written list.
delete from public.app_config where key = 'force_physical_operator';

-- Cursor for the chunked per-country operator probe (mirrors
-- sync-smspva-operators, which paginates 12 countries per run).
insert into public.app_config (key, value)
values ('herosms_operator_cursor', '0'::jsonb)
on conflict (key) do nothing;
