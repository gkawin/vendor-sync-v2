-- Coconut Corner — phone numbers for the "your order is ready" text.
--
-- A new timestamped file, not an edit to the baseline: `db push` compares
-- versions, not contents, so editing 20260804044114_init.sql would change
-- nothing on the remote. See CLAUDE.md.
--
-- Safe to push at any time. Nothing existing reads or writes this table, and
-- card.html degrades to a plain live status page if it is missing.
--
-- ── Why a separate table ────────────────────────────────────────────────
-- `public can read orders` (baseline) has no `to` clause, and the anon key is
-- a constant in every page we serve. A phone column on `orders` would
-- therefore be readable by anyone who opened the page source — the whole
-- event's phone list, one request away.
--
-- So: its own table, RLS on, and *deliberately no policies at all*. Neither
-- anon nor authenticated can select, insert or update it. The only writer is
-- the service role, which bypasses RLS — that is the square-webhook function
-- and the order-contact function, both of which read their keys from the
-- environment.
--
-- Consequence worth knowing: staff.html cannot see who signed up for a text,
-- by design. Adding a `to authenticated` select policy would put customer
-- phone numbers on any till left unattended.

create table if not exists public.order_contacts (
  -- One number per order, enforced by the primary key rather than a unique
  -- index: a customer fixing a typo is an upsert on this column.
  order_id     uuid primary key references public.orders(id) on delete cascade,

  phone        text        not null,          -- E.164, always +1……… here
  created_at   timestamptz not null default now(),

  -- The idempotency guard, and the reason this column is not derived from
  -- orders.status. 'ready' is not a one-time event: ↩ back-to-making clears
  -- ready_at and a second "Ready ✓" fires again, and the 10s undo bar flips
  -- picked_up back to ready. Both would send a duplicate text. The sender must
  -- check `notified_at is null` and nothing else.
  notified_at  timestamptz,

  -- Whatever Twilio said if it refused. Kept because a Canadian carrier can
  -- silently filter a message that the API reported as accepted, and the only
  -- trail we get is here.
  notify_error text
);

alter table public.order_contacts enable row level security;

-- No policies. This is not an oversight — see the header.

comment on table public.order_contacts is
  'Customer phone numbers for ready-notification SMS. Service role only: RLS is on with zero policies. Delete after the event.';
