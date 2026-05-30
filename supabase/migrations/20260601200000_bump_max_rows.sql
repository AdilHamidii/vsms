-- After sync-prices runs, routes.retail_credits is set for every
-- (service, country) pair. CatalogAPI fetches all such rows on app
-- launch, so we need PostgREST to return more than the default 1000.
--
-- Tell the authenticator role to expose up to 25000 rows per response;
-- then ask PostgREST to reload its config so the change takes effect
-- without waiting for the next restart.

alter role authenticator set pgrst.db_max_rows = '25000';
select pg_notify('pgrst', 'reload config');
