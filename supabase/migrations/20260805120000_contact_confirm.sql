-- Coconut Corner — claim column for order-contact's confirmation text.
--
-- A new timestamped file, not an edit to 20260805083000_order_contacts.sql:
-- that file may already be applied, and `db push` compares versions, not
-- contents. See CLAUDE.md.
--
-- Safe to push at any time. Purely additive — until it lands, order-contact
-- still saves the number and just logs that it couldn't claim, so no
-- confirmation text goes out and nothing else changes.
--
-- Written by order-contact in the same statement that filters on it (null or
-- older than the cooldown) — the order-ready-sms claim pattern. The endpoint
-- is public, so a burst of POSTs serialises in Postgres and at most one per
-- window actually sends. Saving the number itself has no such limit; only the
-- confirmation text does.
alter table public.order_contacts
  add column if not exists confirm_sent_at timestamptz;

comment on column public.order_contacts.confirm_sent_at is
  'Claimed by order-contact before sending the confirmation text. Rate limit, not idempotency: re-claimed after the cooldown.';
