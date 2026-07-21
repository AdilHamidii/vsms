-- The catalog sits at 18,492 rows against a 25,000 PostgREST cap — 74%. If it
-- ever crosses, PostgREST TRUNCATES SILENTLY: no error, no warning, the app
-- just receives fewer routes than exist. Every missing route then renders as
-- "Unavailable" or keeps a stale cached price — exactly the class of "the
-- prices in the list aren't accurate" symptom that cannot be diagnosed from
-- the client.
--
-- Route count is not stable: it moved 6,962 -> 16,320 in one day purely by
-- changing which provider owns SMS, and re-enabling a provider or adding
-- countries moves it again in thousands. Headroom is nearly free; the failure
-- mode is silent and expensive.
alter role authenticator set pgrst.db_max_rows = '60000';
notify pgrst, 'reload config';
