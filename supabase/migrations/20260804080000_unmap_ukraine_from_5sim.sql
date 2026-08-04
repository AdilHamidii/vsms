-- Ukraine is NOT a 5sim country. Clear the mapping.
--
-- `countries.fivesim_country` was seeded with the slug 'ukraine', which 5sim
-- rejects with HTTP 400 "country is incorrect". Verified 2026-08-04 against
-- GET /v1/guest/countries: 153 countries, NONE matching /ukr/i, and of our 61
-- mapped slugs this is the only one absent from their list.
--
-- Cost of leaving it wrong, per hourly sync-5sim run:
--   * two doomed requests (the initial call plus the retry) -> the two "400"s
--     in `fetch_faults` on every run,
--   * `countries_failed: 1` / `failed_countries: ["ukraine"]`, which reads as a
--     transient network fault and hid a permanent mapping error,
--   * `skipped_failed_country: 268` — the guard that refuses to treat a failed
--     fetch as "5sim does not serve it" fires for 268 routes every hour,
--   * and 98 active Ukrainian routes (65 herosms + 33 smspva) look like
--     re-home candidates forever while being unservable by 5sim.
--
-- NULL is the correct value and is what `sync-5sim` already handles: with no
-- slug it hits `if (!pick && !slug) continue;` and leaves the row entirely
-- alone, so Ukraine keeps its current provider rather than being hidden.
-- This deliberately does NOT touch routes.provider or routes.status.
update public.countries set fivesim_country = null where id = 'ua';

do $$
declare n_bad int; n_ua int;
begin
  select count(*) into n_bad from public.countries where fivesim_country = 'ukraine';
  if n_bad <> 0 then raise exception 'ukraine slug still mapped on % row(s)', n_bad; end if;

  select count(*) into n_ua from public.routes r
    join public.countries c on c.id = r.country_id
   where c.id = 'ua' and r.status = 'active';
  raise notice 'ukraine unmapped; % active UA routes keep their current provider', n_ua;
end $$;
