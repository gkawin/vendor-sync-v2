-- ============================================================
--  Coconut Corner — order-ready board
--  Run this once in Supabase Studio → SQL Editor
-- ============================================================

create table if not exists orders (
  id              uuid primary key default gen_random_uuid(),
  square_order_id text unique,                 -- from Square, used to de-dupe webhook fires
  ticket          text not null,               -- what the customer sees: "23", "Lhao", etc.
  status          text not null default 'preparing'
                    check (status in ('preparing','ready','picked_up')),
  created_at      timestamptz not null default now(),
  ready_at        timestamptz
);

-- Board only ever queries recent, still-relevant rows — keep it fast.
create index if not exists orders_active_idx
  on orders (created_at desc)
  where status <> 'picked_up';

-- Realtime so the board + staff panel update live (no refresh, no polling).
alter publication supabase_realtime add table orders;

-- ============================================================
--  Row Level Security
-- ============================================================
alter table orders enable row level security;

-- Anyone can READ (the customer board is public via the QR code).
-- Only ticket numbers + status are exposed — no personal data.
create policy "public can read orders"
  on orders for select
  using ( true );

-- ------------------------------------------------------------
--  WRITES — pick ONE of the two approaches below.
-- ------------------------------------------------------------

-- (A) FESTIVAL-SIMPLE  ▸ start here.
--     Staff panel writes with the anon key, gated by a PIN in the page.
--     Risk: anyone who has the staff URL + PIN could mark orders.
--     Low stakes for a stall, fine for v1. Comment these out to disable.
create policy "anon can insert orders"
  on orders for insert
  with check ( true );

create policy "anon can update orders"
  on orders for update
  using ( true )
  with check ( true );

-- (B) LOCKED-DOWN  ▸ graduate to this once it matters.
--     Delete policies (A) above, keep only the SELECT policy, and do all
--     writes from a trusted backend using the SERVICE ROLE key:
--       • your existing Square webhook  → inserts new orders
--       • a tiny Supabase Edge Function → marks ready (checks a secret)
--     The service role bypasses RLS, so no write policy is needed.
--     The board never gets write access; nobody can spoof "ready".

-- ============================================================
--  What your Square webhook inserts
-- ============================================================
--  On order.created / payment completed, after you fetch the ticket
--  name via the Orders API, upsert so a double-fire can't duplicate:
--
--    insert into orders (square_order_id, ticket)
--    values ($square_order_id, $ticket_name)
--    on conflict (square_order_id) do nothing;

alter table orders add column if not exists items jsonb;
alter table orders add column if not exists checked jsonb default '[]'::jsonb;
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
