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