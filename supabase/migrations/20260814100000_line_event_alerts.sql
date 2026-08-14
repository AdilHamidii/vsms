-- 20260814100000_line_event_alerts.sql
--
-- Owner request 2026-08-14: Telegram notifications for the second-number
-- lifecycle — renewals, cancellations (auto-renew off), billing grace,
-- expiry. The rental alert already exists (kind 'line', sent instantly by
-- verify-line-subscription); this widens the telegram_events kind check with
-- ONE generic 'line_event' kind whose refs are prefixed unique ids
-- ('renew:<txid>', 'cancel:<notificationUUID>', …), so future lifecycle
-- alerts need no further constraint change.
--
-- ⚠️ Apply BEFORE deploying apple-notifications: a kind the constraint
-- rejects fails the claim insert, and the alert goes missing with no trace
-- at all (the exact failure mode the claim pattern's comment warns about).

alter table public.telegram_events drop constraint telegram_events_kind_check;
alter table public.telegram_events add constraint telegram_events_kind_check
  check (kind = any (array[
    'signup', 'purchase', 'esim', 'email', 'line',
    'line_refund', 'line_orphan', 'line_provision_failed', 'iap_unknown',
    'line_event'
  ]));
