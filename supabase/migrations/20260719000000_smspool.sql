-- SMSPool becomes the primary provider (SMSPVA stays as fallback). This adds the
-- code mapping columns (mirroring smspva_code / virtualsms_code) and a per-route
-- success_rate that SMSPool reports per service+country — used to steer users
-- onto reliable routes and to show an honest delivery badge in the app.

alter table public.services  add column if not exists smspool_code text;
alter table public.countries add column if not exists smspool_code text;

-- 0-100, SMSPool self-reported delivery success for this (service, country).
-- Nullable: a route without an enriched rate simply shows no badge.
alter table public.routes    add column if not exists success_rate int;
