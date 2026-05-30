-- iOS Service.tintHex maps from JSON "tint_hex" via .convertFromSnakeCase.
-- Old column name was "tint" which decoded as "tint" and failed
-- decoding with "Key 'tintHex' not found".

alter table public.services rename column tint to tint_hex;
