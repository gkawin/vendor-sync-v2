# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

There is no build system, package manager, linter, or test suite. The repo is two self-contained HTML files.

```bash
python3 -m http.server 8000   # preview locally: /board.html and /staff.html
```

Deploy: push to `main`. [.github/workflows/static.yml](.github/workflows/static.yml) uploads the **entire repo root** to GitHub Pages, so every file committed here is publicly served (this file included). `workflow_dispatch` allows a manual redeploy.

## Architecture

Order board for Coconut Corner, a small food stall. Supabase is the entire backend — there is no server-side code in this repo.

**Two independent clients, one table.** [board.html](board.html) is the customer-facing display (read-only); [staff.html](staff.html) is the staff console (read + write, behind a client-side PIN). They share no code: the CSS custom-property palette (`--iron`, `--cream`, `--gold`, `--pandan`, …), the Supabase client setup, and the load/render loop are **duplicated by design** in each file. A change to the palette or to the query shape must be made in both.

**Order lifecycle.** Rows are created by a Square webhook that lives **outside this repo** (not in git history) and writes directly to Supabase. Neither page ever inserts an order. From there:

```
webhook inserts (status='preparing')  →  staff taps "Ready ✓"      →  staff taps "Picked up"
                                          status='ready', ready_at    status='picked_up'
```

`picked_up` rows are filtered out of both UIs and never displayed again.

**`orders` table** (as deployed):

| column | notes |
|---|---|
| `id` | uuid, primary key |
| `square_order_id` | Square's order id; set by the webhook |
| `ticket` | text, shown as the big number/code on both screens |
| `status` | `preparing` \| `ready` \| `picked_up` |
| `created_at`, `ready_at` | timestamptz; `ready_at` written by staff.html |
| `items` | jsonb array of `{name, qty}` — Square line items |
| `checked` | jsonb array of booleans, **index-aligned with `items`** |

**Realtime.** Both pages subscribe to `postgres_changes` on `public.orders` (`event: "*"`) and respond to any event by re-running `load()`, a full re-query and full re-render — the payload is ignored. A 30s `setInterval` backstops missed events and refreshes wait-time labels. Adding a column that the UI needs means updating the `.select()` list in the relevant file.

## Gotchas

- **Time-window filters.** `load()` only fetches rows newer than a cutoff — 3h on the board, 6h on staff. An order left un-picked-up past that window silently disappears from the screen while still sitting in the table.
- **`checked` alignment.** `normChecked()` truncates/pads `checked` to `items.length`, so mismatched lengths degrade quietly rather than erroring. Reordering or rewriting `items` after insert will silently re-point existing checkmarks at the wrong items.
- **Item taps write through immediately.** `toggleItem()` updates the DOM optimistically, PATCHes the row, and reverts the class only if the write fails — so every device stays in sync, but a tap is a database round-trip.
- **Both files are publicly served.** `SUPABASE_URL`, `SUPABASE_ANON`, and `STAFF_PIN` are constants at the top of each `<script>`; the PIN is a client-side speed bump, not access control (the code says so). staff.html updates `status`, `ready_at`, and `checked` using the anon key, so RLS on `orders` must permit anonymous UPDATE — anything that tightens RLS has to keep that path working or move those writes elsewhere.

## Conventions

Vanilla DOM APIs only — no framework, no bundler, no npm. The one external dependency is `@supabase/supabase-js@2` from a CDN `<script>` tag. Rendering builds elements with `createElement` and `textContent` (never `innerHTML` for data). Styles are one inline `<style>` block per file. UI copy is English; Thai appears in menu item names coming from Square.
