-- routes is ONE row per (service_id, country_id) with provider as a column, so
-- every combo SMSPool had claimed was left stranded: marked provider='smspool'
-- and hidden, while sync-prices deliberately SKIPS smspool-owned combos and so
-- would never reprice them. That silently killed leboncoin/nl (8 of 13) and
-- leboncoin/ro (9 of 17) — the two best-delivering routes in the app.
--
-- Hand every combo SMSPVA can actually serve back to SMSPVA so sync-prices
-- owns and prices it again.
update public.routes r
set provider = 'smspva'
from public.services s, public.countries c
where r.service_id = s.id
  and r.country_id = c.id
  and s.smspva_code is not null
  and c.smspva_code is not null
  and r.provider <> 'smspva';
