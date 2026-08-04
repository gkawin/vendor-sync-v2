-- ============================================================
--  Coconut Corner — cashier accept step (physical queue cards 1–100)
--
--  Square no longer decides what the customer sees. An order lands as 'new',
--  waits in the cashier's Incoming list, and only reaches the board once a
--  cashier types the number of the card they just handed over.
--
--  Run this BY HAND in Supabase Studio → SQL Editor. Nothing runs the files
--  in supabase/migrations/. Split in two parts on purpose — see DEPLOY ORDER
--  at the bottom before you paste anything.
-- ============================================================


-- ============================================================
--  PART A — additive only.
--  Safe to run mid-service: behaviour is identical to before until PART B.
-- ============================================================

-- 'new' = arrived from Square, no queue card handed out yet.
-- The inline CHECK in the init migration is auto-named orders_status_check.
-- If this DROP turns out to be a no-op, find the real name with:
--   select conname from pg_constraint
--    where conrelid = 'orders'::regclass and contype = 'c';
alter table orders drop constraint if exists orders_status_check;
alter table orders add constraint orders_status_check
  check (status in ('new','preparing','ready','picked_up'));

-- An incoming order has no card yet, and the webhook no longer invents one.
alter table orders alter column ticket drop not null;

-- Square's ticket_name is demoted to a prefill hint and moves to its own
-- column, so an `order.updated` fire can never overwrite the number the
-- cashier typed. After this, `ticket` is written by staff.html and nothing else.
alter table orders add column if not exists square_ticket text;

-- When the cashier accepted the order and handed the card over.
alter table orders add column if not exists accepted_at timestamptz;

-- Existing rows were accepted implicitly the moment the webhook wrote them,
-- so leave their status alone and just fill in the new columns.
update orders
   set square_ticket = coalesce(square_ticket, ticket),
       accepted_at   = coalesce(accepted_at, created_at)
 where status <> 'picked_up';

-- A queue card is a physical object: while it is in a customer's hand, no other
-- order can carry that number. This index is the real guarantee — a check in
-- staff.html would lose the race between two devices. 'new' rows have
-- ticket = null and Postgres allows duplicate NULLs in a unique index, so
-- unaccepted orders never collide with each other.
--
-- ⚠️ This CREATE fails if active rows already share a number — Square happily
-- let you type the same ticket_name twice. Check first, and clear the stale
-- ones (set status = 'picked_up') before running it:
--   select ticket, count(*) from orders
--    where status in ('preparing','ready')
--    group by ticket having count(*) > 1;
create unique index if not exists orders_active_ticket_idx
  on orders (ticket)
  where status in ('new','preparing','ready');


-- ============================================================
--  PART B — the switch. One line, run it together with the webhook deploy.
-- ============================================================

-- The webhook's upsert deliberately omits `status` so staff taps survive an
-- `order.updated`. Flipping the DEFAULT is therefore the entire mechanism that
-- routes new orders through the cashier — nothing writes the column on insert.
-- Re-running the init migration would reset this to 'preparing' and orders
-- would start skipping the cashier again.
alter table orders alter column status set default 'new';

-- Rollback:
--   alter table orders alter column status set default 'preparing';
--   ...and redeploy the previous square-webhook.


-- ============================================================
--  DEPLOY ORDER — getting this wrong loses orders
-- ============================================================
--  1. Run PART A here.                       → nothing changes yet
--  2. Push staff.html + board.html to Pages. → Incoming list sits empty
--  3. Run PART B, then immediately:
--       supabase functions deploy square-webhook --no-verify-jwt
--
--  Steps 3a and 3b belong together. Deploy the webhook before PART B and new
--  orders land as 'preparing' with ticket = null — a blank token on the
--  customer board. Do step 3 before opening, not mid-service.
-- ============================================================
