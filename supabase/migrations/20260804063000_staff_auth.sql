-- ============================================================
--  Coconut Corner — staff writes move behind Supabase Auth
--
--  Until now the anon key printed in staff.html could update `orders`, and
--  the only thing in front of it was a PIN compared in JavaScript. Both are
--  public: Pages serves the repo root, so anyone who opened the source could
--  flip a status, release a queue card, or acknowledge a cancel alert.
--
--  After this, writes require a signed-in user. Reads do not change — the
--  customer board is anonymous by design.
--
--  ⚠️ DEPLOY ORDER — getting this wrong stops staff working mid-service:
--    1. Supabase dashboard → Authentication → Users → Add user.
--         email: staff@coconutcorner.app   (must match STAFF_EMAIL in staff.html)
--         "Auto Confirm User" ON — there is no inbox behind that address.
--    2. Push staff.html to Pages, then sign in on every till/phone that
--       uses it. They keep working on the anon policy while you do this.
--    3. Only then: supabase db push
--
--  Reversing step 3 is the rollback — see the bottom of this file.
-- ============================================================


-- ------------------------------------------------------------
--  The new write path. Additive: harmless to apply early, since the anon
--  policy below still permits the same writes until it is dropped.
-- ------------------------------------------------------------

-- staff.html updates status, ticket, ready_at, accepted_at, checked and
-- cancel_ack_at. Postgres has no column-level RLS, so this is row-level and
-- permissive — the guarantee it buys is "a signed-in human did this", not
-- "only these columns". The webhook is unaffected either way: the service
-- role bypasses RLS entirely.
create policy "staff can update orders"
  on orders for update
  to authenticated
  using ( true )
  with check ( true );


-- ------------------------------------------------------------
--  The switch. Everything above must already be true on the devices.
-- ------------------------------------------------------------

drop policy if exists "anon can update orders" on orders;

-- Vestigial since the cashier-accept change: neither page has ever called
-- .insert(), and the webhook inserts as the service role. Nothing replaces it.
drop policy if exists "anon can insert orders" on orders;


-- ------------------------------------------------------------
--  Deliberately left alone: "public can read orders" (select, using(true),
--  no `to` clause, so it covers anon and authenticated alike). board.html
--  has no session and must keep reading; staff.html's load(), loadCancels()
--  and findHolder() ride the same policy, which is why a dead session there
--  leaves the screen populated but every tap silently rejected — staff.html's
--  `lostSession()` exists to turn that into a visible sign-in prompt.
-- ------------------------------------------------------------

-- Rollback:
--   create policy "anon can update orders" on orders for update
--     using ( true ) with check ( true );
--   drop policy "staff can update orders" on orders;
--   ...and redeploy the previous staff.html.
