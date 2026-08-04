# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

No build step, linter, or test suite. `package.json` exists only to pin the Supabase CLI as a devDependency — the pages have no npm dependencies and ship exactly as they are on disk.

```bash
python3 -m http.server 8000   # preview locally: /board.html and /staff.html
npm run dev                   # supabase functions serve — the webhook, locally
```

**Deploying the pages:** push to `main`. [.github/workflows/static.yml](.github/workflows/static.yml) uploads the **entire repo root** to GitHub Pages, so every file committed here is publicly served — this file, `package.json`, and `supabase/` included. `workflow_dispatch` allows a manual redeploy.

**Deploying the webhook** (not covered by CI — this is a manual step):

```bash
supabase functions deploy square-webhook --no-verify-jwt   # Square sends no Supabase JWT
supabase secrets set SQUARE_SIGNATURE_KEY=... SQUARE_NOTIFICATION_URL=... SQUARE_ACCESS_TOKEN=...
```

⚠️ **`npm run deploy` is not that command.** It is a bare `supabase functions deploy` — no function name, and **no `--no-verify-jwt`** — and there is no `[functions.square-webhook] verify_jwt = false` in `supabase/config.toml` to compensate. Use the explicit command above, or Square's deliveries start failing auth.

`SQUARE_ENV` defaults to `production` (set `sandbox` to hit Square's sandbox API). `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by Supabase — don't set them. `config.toml`'s `project_id` names the *local* stack, not the remote project, so commands against production still need `supabase link` or `--project-ref`.

**Migrations are a record, not a pipeline — against production.** Nothing applies [supabase/migrations/](supabase/migrations/) to the live project; the file says to paste it into Supabase Studio's SQL editor, and that is how every change so far was applied. (`[db.migrations] enabled = true` in config.toml means a *local* `supabase db reset` would run it, but nothing here depends on the local stack.) Adding a column means editing the migration *and* running it by hand.

Everything is consolidated into one [20260804044114_init.sql](supabase/migrations/20260804044114_init.sql), which leaves two traps in it:

- **It is not a script to paste whole into a live database.** Its tail is the cashier-accept change, deliberately split into a PART A (additive, safe any time) and a one-line PART B that flips `status`'s DEFAULT. PART B and the webhook deploy are a single cutover — running the file top-to-bottom fires PART B immediately, and doing that mid-service puts blank tokens on the customer board. The header's "Run this once" is true of a *fresh* database only.
- **PART C (the cancellation-alert columns) is the exception** — additive only, safe to paste mid-service, and safe in either order relative to the webhook deploy. Run it *before* pushing the pages, though: staff.html's alert query selects those columns and fails soft (no alert at all) until they exist.
- **The `create table` at the top is no longer the truth.** It declares `ticket not null`, `status default 'preparing'`, and a CHECK without `'new'` — all three are undone further down the same file. Read the bottom before believing the top.

## Architecture

Order board for Coconut Corner, a small food stall. Three independent pieces, one `orders` table; Supabase is the only backend.

**Two clients, no shared code.** [board.html](board.html) is the customer-facing display (read-only); [staff.html](staff.html) is the staff console (read + write, behind a client-side PIN). The CSS custom-property palette (`--iron`, `--cream`, `--gold`, `--pandan`, …), the Supabase client setup, and the load/render loop are **duplicated by design** in each file. A change to the palette or the query shape must be made in both.

**One webhook.** [supabase/functions/square-webhook/index.ts](supabase/functions/square-webhook/index.ts) is a Deno edge function: it verifies Square's HMAC signature, re-fetches the order from the Orders API to get `ticket_name` and line items, and upserts on `square_order_id`. Neither HTML page ever inserts an order.

```
Square order.created/.updated  →  webhook upsert (status takes DEFAULT 'new')
                               →  cashier types the card no. + "Accept"
                                        → ticket='12', status='preparing', accepted_at=now
                               →  staff taps "Ready ✓"    → status='ready', ready_at=now
                               →  staff taps "Picked up"  → status='picked_up'
                    ↩ back to making  ← status='preparing', ready_at=null
                    ↩ Undo (10s bar)  ← status='ready'

Square void / refund / return  →  webhook hides the row (status='picked_up')
                                  + stamps canceled_at if a card was out
                               →  staff.html blocks the screen until someone
                                  taps "Already got the … card" → cancel_ack_at
```

**The cashier owns the number, Square doesn't.** Customers get a physical queue card (1–100) at the counter, so the order sits in staff.html's *Incoming* list until someone types the number of the card they just handed over. Square's `ticket_name` survives only as `square_ticket`, which prefills that box — the webhook never writes `ticket` at all. **`status` has no writer either**: its column DEFAULT of `'new'` is the entire mechanism routing orders through the cashier, precisely because the upsert omits the column. Re-running the init migration would reset that default and orders would start skipping the cashier.

Every transition is a straight `update` on `orders` from staff.html — there is no state machine and nothing rejects a backwards move. Both reversals matter when reasoning about the table: **↩** on a Ready row sends it back to Making and **nulls `ready_at`**, and the transient undo bar after a pickup flips `picked_up` back to `ready` within ~10s. So `ready_at` is not monotonic and a row can leave and re-enter the UI.

The undo bar holds only the row id in a DOM `dataset` — a page reload during that window drops the offer, and the row is then only reachable via SQL.

Both pages query by an explicit `.in("status", …)` allow-list rather than excluding `picked_up`, because `new` has to be hidden too: board.html asks for `preparing`/`ready` only (an unaccepted order has no number to print), staff.html adds `new` for the Incoming list. `picked_up` is the universal *hide* mechanism, and the webhook reuses it: a CANCELED order, or one carrying a `returns`/`refunds` block (Square spawns a whole new order for every refund/return/exchange), gets force-set to `picked_up` instead of being upserted — which also frees its queue card. So `picked_up` means "off the board," not necessarily "collected."

**A cancellation frees the card in the database but not in the customer's hand.** That gap is what `canceled_at` / `cancel_reason` / `cancel_ack_at` exist for. In the cancel branch the webhook runs *two* updates: the first hides only rows that are `preparing`/`ready` **with a non-null `ticket`** and stamps `canceled_at` on them; the second hides whatever is left for those ids (a `new` row — no card was ever handed over, so there is nothing to chase). staff.html then raises a blocking alert for every stamped row, and the button — the only way to dismiss it — writes `cancel_ack_at`. That first update's status filter is also the idempotency guard: Square re-fires `order.updated` freely, and the second fire finds the row already `picked_up`, so an acknowledged alert can't be resurrected.

A **return** arrives as its own new Square order, so its own id matches no row of ours; the card belongs to the original sale, named in `returns[].source_order_id`. The webhook unions that into the id list it updates. A same-order refund carries a `refunds` block and no `returns`, and there the event's own order id is already the right row.

Square's `COMPLETED` state only means *paid* — the webhook deliberately does **not** auto-mark an order ready. Staff do that.

**`orders` table** — schema lives in [supabase/migrations/](supabase/migrations/):

| column | notes |
|---|---|
| `id` | uuid, primary key |
| `square_order_id` | text **unique** — the webhook's upsert conflict target, de-dupes repeat fires |
| `ticket` | text, **nullable** — the physical queue-card number the cashier typed, and the big number on both screens. Null until Accept. Written by staff.html *only* |
| `square_ticket` | text, Square's `ticket_name`; a prefill hint for the cashier's box and nothing more |
| `status` | `new` \| `preparing` \| `ready` \| `picked_up` (CHECK constraint); **DEFAULT `new`** |
| `created_at`, `ready_at`, `accepted_at` | timestamptz; `ready_at` set on "Ready ✓" and **cleared** on ↩ back-to-making; `accepted_at` set on Accept |
| `items` | jsonb array of `{name, qty}`; `name` is pre-composed by the webhook as `Item (variation) +mods — note` |
| `checked` | jsonb array of booleans, **index-aligned with `items`** |
| `canceled_at` | timestamptz, set by the webhook **only** on a void/refund/return of a row that had a card out. Non-null = staff.html owes an alert |
| `cancel_reason` | text, `canceled` \| `refunded` \| `returned` — free text, it only picks the label on the alert |
| `cancel_ack_at` | timestamptz, written by staff.html when someone confirms the card is back. Null = the alert is still up, on every device |

The upsert writes only `square_order_id`, `square_ticket`, and `items`. Everything else — `status`, `ticket`, `created_at`, `ready_at`, `accepted_at`, `checked` — is left alone, so the card number and anything staff tapped survive a later `order.updated`.

`orders_active_ticket_idx` is a **partial unique index** on `ticket` where `status in ('new','preparing','ready')`: one physical card, one active order. `'new'` rows have `ticket = null` and Postgres treats NULLs as distinct, so unaccepted orders never collide.

**Refresh — the two pages differ.** staff.html subscribes to `postgres_changes` on `public.orders` (`event: "*"`) and responds to any event by re-running `load()` — a full re-query and full re-render; the payload is ignored. A 30s `setInterval` backstops missed events and refreshes wait-time labels. It doesn't subscribe at all until the PIN is accepted (`start()`). board.html has no subscription: it polls `load()` every `POLL_MS` (3s), guarded by an `inFlight` flag so a slow query can't stack up. PostgREST can't hold a request open, so that is a fixed interval, not a server-held long poll. Adding a column the UI needs means updating the `.select()` list in the relevant file.

**The Incoming chime rides on that same `load()`.** `ringForNew()` diffs the `new` ids against the previous load's set and plays a WebAudio-synthesised two-note bell when any id is unseen — no audio file, and no `<audio>` element. The set starts as `null` so the backlog already on screen at sign-in doesn't ring, and it is *replaced* each load, so it stays bounded and a row aged out of the 6h window can't linger in it. Browsers block audio before a gesture, so the PIN tap calls `unlockAudio()` to build the `AudioContext`; `chime()` re-`resume()`s it because a backgrounded tab gets suspended. The header 🔔 toggle persists to `localStorage["staff-sound"]` and is the only mute — a muted device still shows the Incoming badge.

**The cancelled-order alert rides on `load()` too, but as a second query.** `load()` kicks off `loadCancels()` without awaiting it — those rows are `picked_up`, so `load()`'s own status filter can never see them. It selects `canceled_at is not null and cancel_ack_at is null` within 6h *of the cancellation*, and shows them one at a time, oldest first. `alarmForCancels()` diffs ids exactly like `ringForNew()` (same `null` start, same 🔔 mute) and plays a distinct lower repeating tone. `renderCancel()` returns early when the row on screen is already the one at the head of the queue, so a realtime event can't rebuild the sheet mid-read or wipe a failed-save message. The query fails soft: if PART C of the migration hasn't been run, the missing columns error out and no alert ever shows.

That full re-render is why `renderIncoming()` snapshots each card-number `<input>` (value *and* caret) before wiping the list and restores it afterward, and why conflict messages live in a module-level `conflicts` map instead of the DOM. Without both, an unrelated realtime event mid-typing would eat what the cashier was entering.

## Gotchas

- **Time-window filters.** `load()` only fetches rows newer than a cutoff — 3h on the board, 6h on staff. An order left un-picked-up past that window silently disappears from the screen while still sitting in the table — *and keeps holding its queue card*, since the unique index has no time bound. That combination is why an accept that hits a duplicate looks the offender up with `findHolder()`, which queries by `ticket` with **no time filter**, and offers "Release card" (a plain `status='picked_up'`). It is the only in-app way to reclaim a number stranded on an invisible row.
- **The unique index can reject writes staff.html otherwise treats as infallible.** `setStatus()` ignores its error, so undoing a pickup within the 10s window fails silently if that card was re-issued in the meantime — the row just doesn't come back on the next `load()`. `↩` back-to-making is safe (the row keeps its own number, and both statuses are inside the index predicate).
- **The cancel alert is undismissable by design, and that is load-bearing.** No close button, no backdrop tap, no Escape, and a failed `cancel_ack_at` write leaves the sheet up with an error rather than closing. The only escape hatches are the 6h window and SQL. Anything that adds a "later" button hands out a card number twice.
- **Normalize card numbers before writing.** `normCard()` validates 1–100 and returns `String(Number(s))`, so `"07"` and `"7"` can't become two live cards — the index compares text and would happily allow both.
- **`checked` alignment is fragile by construction.** `normChecked()` truncates/pads `checked` to `items.length`, so mismatched lengths degrade quietly rather than erroring. The live hazard: an `order.updated` fire rewrites `items` wholesale but leaves `checked` untouched, so editing an order in Square after staff have started ticking re-points existing checkmarks at the wrong items.
- **Item taps write through immediately.** `toggleItem()` updates the DOM optimistically, PATCHes the row, and reverts the class only if the write fails — so every device stays in sync, but a tap is a database round-trip.
- **Two write paths with different privileges.** The webhook uses the **service role** key (bypasses RLS entirely). staff.html updates `status`, `ticket`, `ready_at`, `accepted_at`, and `checked` with the **anon** key, so the `anon can update orders` policy in the init migration must keep working — anything that tightens RLS has to preserve that path or move those writes into a function. (The `anon can insert orders` policy alongside it is vestigial now that only the webhook inserts.)
- **Everything here is publicly served.** `SUPABASE_URL`, `SUPABASE_ANON`, and `STAFF_PIN` are constants at the top of each `<script>`; the PIN is a client-side speed bump, not access control (the code says so). Because Pages uploads the repo root, the webhook source ships publicly too — it reads every secret from `Deno.env`, and it must stay that way.
- **Signature verification is URL-bound.** The HMAC covers `SQUARE_NOTIFICATION_URL + rawBody`, so that secret must match the URL registered in Square *exactly* or every delivery 403s.

## Conventions

Vanilla DOM APIs only in the pages — no framework, no bundler, no npm. The one browser dependency is `@supabase/supabase-js@2` from a CDN `<script>` tag; the edge function imports the same library via `npm:`. Rendering builds elements with `createElement` and `textContent` (never `innerHTML` for data). Styles are one inline `<style>` block per file. UI copy is English; Thai appears in menu item names coming from Square.
