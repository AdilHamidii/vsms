-- Hide combos that structurally never deliver: US WhatsApp / Google / OpenAI /
-- Twitter. SMSPVA can't fulfil them (VoIP is blocked by those services) and
-- virtualsms has no US supply, so selling them just rents a doomed number and
-- frustrates new users. sync-prices reads this list and keeps them 'hidden';
-- edit the array to add/remove combos without a redeploy.
insert into public.app_config(key, value) values
  ('blocked_routes', '["whatsapp|us","google|us","openai|us","twitter-x|us"]'::jsonb)
on conflict (key) do nothing;

-- Apply immediately rather than waiting for the next sync-prices run.
update public.routes set status = 'hidden'
 where status = 'active' and provider = 'smspva'
   and (service_id, country_id) in
       (('whatsapp','us'), ('google','us'), ('openai','us'), ('twitter-x','us'));
