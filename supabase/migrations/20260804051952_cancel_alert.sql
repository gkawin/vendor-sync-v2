-- ============================================================
--  Coconut Corner — cancelled-order alert (void / refund / return)
--
--  A refund, return or void in Square takes the order off the board on its
--  own, and frees its queue-card number the moment the row goes 'picked_up'.
--  But the customer is still holding the physical card. These columns are how
--  the webhook tells staff.html to block the screen until someone confirms
--  they have it back.
--
--  This is the FIRST file meant to travel by `supabase db push` rather than
--  being pasted into Studio by hand. It had to be its own file: the
--  consolidated 20260804044114_init.sql is already recorded as applied, so
--  editing it changes nothing on the remote — push compares versions, not
--  contents.
--
--  Additive only. Safe to run mid-service, and safe in either order relative
--  to the webhook deploy: until something writes canceled_at, staff.html's
--  alert query just finds nothing.
-- ============================================================

-- When the webhook saw Square cancel/refund/return this order. Non-null means
-- a queue card went out and nobody has confirmed getting it back yet.
alter table orders add column if not exists canceled_at   timestamptz;

-- Which of the three it was: 'canceled' | 'refunded' | 'returned'.
-- Free text on purpose — an unknown value only changes the label on the alert.
alter table orders add column if not exists cancel_reason text;

-- When a staff member confirmed the queue card is back in the box. Written by
-- staff.html and nothing else. NULL = the alert is still up, on every
-- signed-in device.
alter table orders add column if not exists cancel_ack_at timestamptz;

-- staff.html's loadCancels() asks for exactly this set on every load.
create index if not exists orders_cancel_alert_idx
  on orders (canceled_at desc)
  where canceled_at is not null and cancel_ack_at is null;

-- Rollback:
--   drop index if exists orders_cancel_alert_idx;
--   ...and redeploy the previous square-webhook. Leave the columns; dropping
--   them while the old pages are still cached would break their SELECT list.
