# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

There is no build system, package manager, linter, or test suite.

```bash
python3 -m http.server 8000   # preview locally: /board.html and /staff.html
```

**Deploying the pages:** push to `main`. [.github/workflows/static.yml](.github/workflows/static.yml) uploads the **entire repo root** to GitHub Pages, so every file committed here is publicly served — this file, and `supabase/` included. `workflow_dispatch` allows a manual redeploy.

**Deploying the webhook** (not covered by CI — this is a manual step):

```bash
supabase functions deploy square-webhook --no-verify-jwt   # Square sends no Supabase JWT
supabase secrets set SQUARE_SIGNATURE_KEY=... SQUARE_NOTIFICATION_URL=... SQUARE_ACCESS_TOKEN=...
```

`SQUARE_ENV` defaults to `production` (set `sandbox` to hit Square's sandbox API). `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by Supabase — don't set them. There is no `supabase/config.toml`, so CLI commands need a linked project or `--project-ref`.

**Migrations are a record, not a pipeline.** Nothing runs [supabase/migrations/](supabase/migrations/) — the init file says to paste it into Supabase Studio's SQL editor, and the two `alter table` files were applied the same way. Adding a column means writing the migration file *and* running it by hand.

## Architecture

Order board for Coconut Corner, a small food stall. Three independent pieces, one `orders` table; Supabase is the only backend.

**Two clients, no shared code.** [board.html](board.html) is the customer-facing display (read-only); [staff.html](staff.html) is the staff console (read + write, behind a client-side PIN). The CSS custom-property palette (`--iron`, `--cream`, `--gold`, `--pandan`, …), the Supabase client setup, and the load/render loop are **duplicated by design** in each file. A change to the palette or the query shape must be made in both.

**One webhook.** [supabase/functions/square-webhook/index.ts](supabase/functions/square-webhook/index.ts) is a Deno edge function: it verifies Square's HMAC signature, re-fetches the order from the Orders API to get `ticket_name` and line items, and upserts on `square_order_id`. Neither HTML page ever inserts an order.

```
Square order.created/.updated  →  webhook upsert (status defaults 'preparing')
                               →  staff taps "Ready ✓"    → status='ready', ready_at=now
                               →  staff taps "Picked up"  → status='picked_up'
                    ↩ back to making  ← status='preparing', ready_at=null
                    ↩ Undo (10s bar)  ← status='ready'
```

Every transition is a straight `update` on `orders` from staff.html — there is no state machine and nothing rejects a backwards move. Both reversals matter when reasoning about the table: **↩** on a Ready row sends it back to Making and **nulls `ready_at`**, and the transient undo bar after a pickup flips `picked_up` back to `ready` within ~10s. So `ready_at` is not monotonic and a row can leave and re-enter the UI.

The undo bar holds only the row id in a DOM `dataset` — a page reload during that window drops the offer, and the row is then only reachable via SQL.

`picked_up` rows are filtered out of both UIs. The webhook reuses that as a *hide* mechanism: a CANCELED order, or one carrying a `returns`/`refunds` block (Square spawns a whole new order for every refund/return/exchange), gets force-set to `picked_up` instead of being upserted. So `picked_up` means "off the board," not necessarily "collected."

Square's `COMPLETED` state only means *paid* — the webhook deliberately does **not** auto-mark an order ready. Staff do that.

**`orders` table** — schema lives in [supabase/migrations/](supabase/migrations/):

| column | notes |
|---|---|
| `id` | uuid, primary key |
| `square_order_id` | text **unique** — the webhook's upsert conflict target, de-dupes repeat fires |
| `ticket` | text, the big number/code on both screens; Square's `ticket_name`, or the last 4 of the order id |
| `status` | `preparing` \| `ready` \| `picked_up` (CHECK constraint) |
| `created_at`, `ready_at` | timestamptz; `ready_at` set by staff.html on "Ready ✓" and **cleared** on ↩ back-to-making |
| `items` | jsonb array of `{name, qty}`; `name` is pre-composed by the webhook as `Item (variation) +mods — note` |
| `checked` | jsonb array of booleans, **index-aligned with `items`** |

The upsert writes only `square_order_id`, `ticket`, and `items` — `status`, `created_at`, `ready_at`, and `checked` are left alone, so anything staff tapped survives a later `order.updated`.

**Realtime.** Both pages subscribe to `postgres_changes` on `public.orders` (`event: "*"`) and respond to any event by re-running `load()` — a full re-query and full re-render; the payload is ignored. A 30s `setInterval` backstops missed events and refreshes wait-time labels. staff.html doesn't subscribe at all until the PIN is accepted (`start()`). Adding a column the UI needs means updating the `.select()` list in the relevant file.

## Gotchas

- **Time-window filters.** `load()` only fetches rows newer than a cutoff — 3h on the board, 6h on staff. An order left un-picked-up past that window silently disappears from the screen while still sitting in the table.
- **`checked` alignment is fragile by construction.** `normChecked()` truncates/pads `checked` to `items.length`, so mismatched lengths degrade quietly rather than erroring. The live hazard: an `order.updated` fire rewrites `items` wholesale but leaves `checked` untouched, so editing an order in Square after staff have started ticking re-points existing checkmarks at the wrong items.
- **Item taps write through immediately.** `toggleItem()` updates the DOM optimistically, PATCHes the row, and reverts the class only if the write fails — so every device stays in sync, but a tap is a database round-trip.
- **Two write paths with different privileges.** The webhook uses the **service role** key (bypasses RLS entirely). staff.html updates `status`, `ready_at`, and `checked` with the **anon** key, so the `anon can update orders` policy in the init migration must keep working — anything that tightens RLS has to preserve that path or move those writes into a function. (The `anon can insert orders` policy alongside it is vestigial now that only the webhook inserts.)
- **Everything here is publicly served.** `SUPABASE_URL`, `SUPABASE_ANON`, and `STAFF_PIN` are constants at the top of each `<script>`; the PIN is a client-side speed bump, not access control (the code says so). Because Pages uploads the repo root, the webhook source ships publicly too — it reads every secret from `Deno.env`, and it must stay that way.
- **Signature verification is URL-bound.** The HMAC covers `SQUARE_NOTIFICATION_URL + rawBody`, so that secret must match the URL registered in Square *exactly* or every delivery 403s.

## Conventions

Vanilla DOM APIs only in the pages — no framework, no bundler, no npm. The one browser dependency is `@supabase/supabase-js@2` from a CDN `<script>` tag; the edge function imports the same library via `npm:`. Rendering builds elements with `createElement` and `textContent` (never `innerHTML` for data). Styles are one inline `<style>` block per file. UI copy is English; Thai appears in menu item names coming from Square.
