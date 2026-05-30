-- Phase J: corrections to SMSPVA service codes based on the official v2
-- alternative-API mapping table in their docs.
-- Verified via https://docs.smspva.com (activation_alternative_lists tag).
-- Codes for services NOT in that mapping are still best-effort guesses —
-- run /activation/servicesprices against your account to confirm.

update public.services set smspva_code = 'opt20'  where id = 'whatsapp';   -- was opt0
update public.services set smspva_code = 'opt11'  where id = 'viber';      -- was opt8
update public.services set smspva_code = 'opt31'  where id = 'wechat';     -- was opt7
update public.services set smspva_code = 'opt72'  where id = 'uber';       -- was opt5
update public.services set smspva_code = 'opt104' where id = 'tiktok';     -- was opt167
update public.services set smspva_code = 'opt69'  where id = 'vk';         -- was opt3
update public.services set smspva_code = 'opt19'  where id = 'amazon';     -- 'ot' = "other/Amazon"
update public.services set smspva_code = 'opt23'  where id = 'yahoo';      -- 'ya' = opt23 (was opt12)

-- Confirmed correct codes (no-op updates kept for clarity):
-- telegram     = opt29
-- google/gmail = opt1
-- facebook     = opt2
-- twitter-x    = opt41
-- instagram    = opt16
