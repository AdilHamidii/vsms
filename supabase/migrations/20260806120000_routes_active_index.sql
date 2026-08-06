-- `routes.status` had no index, and `routes` was showing ~111.7M sequential
-- tuple reads.
--
-- Nearly every read of this table is scoped to `status = 'active'` — the
-- catalog fetch, all five `refresh_*` evidence functions, every sync's write
-- set, `active_sms_provider()`, and the ops snapshot. On a 9,300-row active
-- set inside a much larger table that is a full scan each time.
--
-- PARTIAL, not a plain index on `status`: the only value anything filters for
-- is 'active', and a partial index is a fraction of the size and stays hot.
-- The provider column rides along because the evidence refreshes and the
-- router both scope by (status, provider) — a route's owner is what decides
-- who serves the NEXT order.
--
-- CONCURRENTLY is deliberately NOT used: it cannot run inside the transaction
-- the migration runner wraps this in, and the table is small enough that the
-- brief lock is irrelevant.
create index if not exists routes_active_provider_idx
  on public.routes (provider, service_id)
  where status = 'active';

-- The catalog fetch itself is keyed on the price being present, which is what
-- `CatalogAPI` filters on.
create index if not exists routes_active_priced_idx
  on public.routes (service_id, country_id)
  where status = 'active' and retail_credits is not null;

analyze public.routes;
