-- Local StoreKit testing in Xcode reports environment = "Xcode" in the
-- signed transaction. The previous CHECK constraint only allowed
-- 'Sandbox' or 'Production', so dev purchases failed to persist with
-- iap_receipts_environment_check violations.

alter table public.iap_receipts
    drop constraint if exists iap_receipts_environment_check;

alter table public.iap_receipts
    add constraint iap_receipts_environment_check
    check (environment in ('Sandbox','Production','Xcode'));
