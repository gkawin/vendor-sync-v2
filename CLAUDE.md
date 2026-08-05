# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

No build step, linter, or test suite. `package.json` exists only to pin the Supabase CLI as a devDependency — the pages have no npm dependencies and ship exactly as they are on disk.

```bash
python3 -m http.server 8000   # preview locally: /board.html, /staff.html, /card.html
npm run dev                   # supabase functions serve — the edge functions, locally
```

**Deploying the pages:** push to `main`. [.github/workflows/static.yml](.github/workflows/static.yml) uploads the **entire repo root** to GitHub Pages, so every file committed here is publicly served — this file, `package.json`, and `supabase/` included. `workflow_dispatch` allows a manual redeploy.

**Deploying the edge functions** (not covered by CI — this is a manual step). There are three, and **they do not all take the same flags**:

```bash
supabase functions deploy square-webhook --no-verify-jwt   # Square sends no Supabase JWT
supabase functions deploy order-contact  --no-verify-jwt   # anonymous customers, no JWT either
supabase functions deploy order-ready-sms                  # called by the DB — leave JWT on

supabase secrets set SQUARE_SIGNATURE_KEY=... SQUARE_NOTIFICATION_URL=... SQUARE_ACCESS_TOKEN=...
supabase secrets set READY_HOOK_SECRET=...                 # any random string; also a webhook header
supabase secrets set TWILIO_ACCOUNT_SID=... TWILIO_AUTH_TOKEN=... TWILIO_FROM=+1604...
```

⚠️ **`npm run deploy` is not that command.** It is a bare `supabase functions deploy` — no function name, and **no `--no-verify-jwt`** — and there is no `verify_jwt = false` for either public function in `supabase/config.toml` to compensate. Use the explicit commands above, or Square's deliveries and every customer's phone entry start failing auth.

`order-ready-sms` is the deliberate exception: its only caller is a Supabase **Database Webhook**, which can send a real key, so JWT verification stays on. That is not the whole guard, though — the anon key is *also* a valid JWT and it is printed in every page served, so the function additionally requires an `x-ready-hook-secret` header matching `READY_HOOK_SECRET`, and it re-reads the order from the database rather than trusting the `record` in the payload. Configure the hook in Studio → Database → Webhooks: table `public.orders`, event **UPDATE**, type *Supabase Edge Functions*, plus that header. There is no per-event filter in that UI, so it fires on **every** update to `orders` — including each item checkbox tap — and the function's own status check is what makes that harmless.

`SQUARE_ENV` defaults to `production` (set `sandbox` to hit Square's sandbox API). `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by Supabase — don't set them. Leaving the `TWILIO_*` secrets unset is a supported mode, not a broken one: `order-ready-sms` then runs as a **dry run**, doing every step including claiming the row but writing what it *would* have sent into `notify_error` (`order-contact`'s confirmation text dry-runs the same way, claiming `confirm_sent_at` but only logging). That makes the whole chain testable before a Twilio number exists, and going live is `secrets set` alone. `config.toml`'s `project_id` names the *local* stack, not the remote project, so commands against production still need `supabase link` or `--project-ref`.

**Migrations: one hand-applied baseline, then `supabase db push`.** [20260804044114_init.sql](supabase/migrations/20260804044114_init.sql) predates the pipeline — every statement in it was pasted into Supabase Studio's SQL editor by hand, and the remote now has that version recorded as applied. **`db push` compares versions, not contents**, so editing that file changes nothing on production, forever. It only decides what a *fresh* database gets.

So **a new column means a new timestamped file**, never an edit to the baseline. [20260804051952_cancel_alert.sql](supabase/migrations/20260804051952_cancel_alert.sql) is the first of those.

[20260805083000_order_contacts.sql](supabase/migrations/20260805083000_order_contacts.sql) is the opposite of a cutover and can be pushed at any time: it only adds a table nothing existing reads or writes, and card.html degrades to a plain live status page while it is missing. [20260805120000_contact_confirm.sql](supabase/migrations/20260805120000_contact_confirm.sql) is the same kind — one nullable column; until it lands, order-contact still saves numbers and just skips the confirmation text.

⚠️ [20260804063000_staff_auth.sql](supabase/migrations/20260804063000_staff_auth.sql) drops the anon write policies, so **pushing it is a cutover, not a schema tweak**: create the staff user in the dashboard, deploy staff.html, sign in on every device, *then* `db push`. Push it early and every till stops writing mid-service. Its header carries the full order.

```bash
supabase db push                                             # apply pending files to the linked project
supabase migration list --linked                             # local vs remote, side by side
supabase migration repair --status applied 20260804044114    # only if push calls the baseline pending
```

That last one is the fix for the one failure mode here: if the remote's history is missing the baseline, `db push` tries to replay init.sql top-to-bottom against a live database — which fires PART B mid-service *and* dies on `alter publication ... add table orders` (already a member). Mark it applied instead; the schema is already there.

Two traps live in the baseline, and both are about reading it, not running it:

- **It is not a script to paste whole into a live database.** Its tail is the cashier-accept change, deliberately split into a PART A (additive, safe any time) and a one-line PART B that flips `status`'s DEFAULT. PART B and the webhook deploy are a single cutover — running the file top-to-bottom fires PART B immediately, and doing that mid-service puts blank tokens on the customer board. The header's "Run this once" is true of a *fresh* database only.
- **The `create table` at the top is no longer the truth.** It declares `ticket not null`, `status default 'preparing'`, and a CHECK without `'new'` — all three are undone further down the same file. Read the bottom before believing the top.

## Architecture

Order board for Coconut Corner, a small food stall. Independent pieces around one `orders` table; Supabase is the only backend.

**Three clients, no shared code.** [board.html](board.html) is the stall's own display (read-only, no session); [staff.html](staff.html) is the staff console (read + write, behind Supabase Auth); [card.html](card.html) is what a customer gets when they scan the QR sticker on their queue card (read-only, no session, plus one write that goes through an edge function). The CSS custom-property palette (`--iron`, `--cream`, `--gold`, `--pandan`, …), the Supabase client setup, `normCard()`, and the load/render loop are **duplicated by design** in each file. A change to the palette or the query shape must be made in all three.

**Staff auth is one shared Supabase Auth account.** `STAFF_EMAIL` is a constant in staff.html; the password is typed at the gate and never appears in the repo. `createClient` sets `persistSession` with `storageKey: "cc-staff-auth"`, so a till signs in once and stays signed in across refreshes and shifts. The gate is **hidden, not removed** — `writeFailed()` puts it back, and `onAuthStateChange` catches the refresh token finally failing. `enterApp()` guards on a `started` flag so re-authenticating doesn't stack a second realtime subscription and a second 30s interval. Sign-out passes `scope: "local"`: the default revokes the refresh token for the whole user, and the account is shared, so it would kick every other till off mid-service.

**A signed-out write does not error — it writes zero rows.** RLS filters the row out via `USING`, so `update(...).eq("id", …)` comes back `204`, no error, nothing changed. Detecting a dead session by inspecting `error` therefore does not work at all. Every write in staff.html instead ends in **`.select("id")`** and passes both halves to `writeFailed(error, data)`, which treats an empty result as "didn't land" and then checks `getSession()` to decide whether to raise the gate. Errors with a live session (the unique index rejecting an undo, a dropped connection) fall through to the handling that was always there. **A new write path that omits `.select("id")` silently reintroduces the invisible failure.**

Two consequences worth holding onto. The gate sits at **z-index 50, above the cancel alert's 40**: a session that dies while an alert is up can't write `cancel_ack_at` anyway, so the sign-in form has to be the thing on top — and signing back in re-raises the alert, since `cancel_ack_at` is still null. And `#gate[hidden]{display:none}` is load-bearing: `#gate`'s own `display:flex` outranks the `hidden` attribute, so without that rule the gate never disappears.

**Three edge functions, all Deno.** [square-webhook](supabase/functions/square-webhook/index.ts) verifies Square's HMAC signature, re-fetches the order from the Orders API to get `ticket_name` and line items, and upserts on `square_order_id` — no HTML page ever inserts an order. [order-contact](supabase/functions/order-contact/index.ts) takes the phone number a customer typed into card.html. [order-ready-sms](supabase/functions/order-ready-sms/index.ts) texts that customer once, when their order goes ready. All three write with the **service role** key.

```
Square order.created/.updated  →  webhook upsert (status takes DEFAULT 'new')
                               →  cashier types the card no. + "Accept"
                                        → ticket='12', status='preparing', accepted_at=now
                               →  staff taps "Ready ✓"    → status='ready', ready_at=now
                               →  staff taps "Picked up"  → status='picked_up'
                    ↩ back to making  ← status='preparing', ready_at=null
                    ↩ Undo (10s bar)  ← status='ready'

customer scans QR on card 12  →  card.html#12 resolves the row, pins its id
                              →  types a phone no. → order-contact → order_contacts
                                 + one confirmation text (claims confirm_sent_at)
        status → 'ready'      →  DB webhook → order-ready-sms → claims the row,
                                 then one text. notified_at is the only guard.

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

**Calling the customer: the card number is the binding key, and the customer does all the typing.** The stall is too loud to shout over, so each physical card carries a QR sticker pointing at `card.html#12`. The constraint that shaped everything else here is **counter throughput**: any design where staff type a phone number costs ~30s per order and blocks the queue, so the customer enters their own number on their own phone, after they have walked away. The cashier's work does not change at all — the two-digit card number they already type at Accept is what ties a scan to an order.

**card.html pins to the row id, not the card number.** Cards are reused all day, so `#12` means "whoever holds card 12 right now". The page resolves that once — by `ticket`, with no time filter, the same query shape as `findHolder()` — and then follows the resulting `id` forever. Without that, a page left open after pickup would roll onto the next customer's order and tell the wrong person their food is ready. It also means the page only works **after** Accept (a `new` row has `ticket = null`); scanning early shows a "not registered yet" state and keeps polling rather than erroring. No hash at all falls back to a card-number input, so one shared QR at the counter works if a sticker peels off.

**The phone number never goes in `orders`.** `public can read orders` has no `to` clause and `SUPABASE_ANON` is a constant in every page served, so a `phone` column would put the whole event's phone list one request away. It lives in `order_contacts`, a table with **RLS on and deliberately no policies at all** — service role only. Consequence: staff.html cannot see who signed up, by design. card.html therefore cannot write it directly either; it POSTs to `order-contact`, which re-validates the Canadian area code, requires the order to be `preparing` and its `ticket` to match the scanned card, and upserts. Those filters are also the whole abuse story: an enumerator can only ever attach a number to an order genuinely in the pan, one at a time, and the real customer overwrites it by scanning their own card. A successful save also texts a one-line **confirmation** to that number — and because the endpoint is public, that send is rate-limited by claiming `confirm_sent_at` exactly the way `notified_at` is claimed (written in the same statement that filters on it being null *or older than 60s*), so a POST loop cannot text strangers on the stall's Twilio bill. A skipped or failed confirmation still returns `ok: true` with `confirmed: false`; card.html then just shows the plain "we'll text you" line, and `notified_at` is untouched either way.

**`notified_at` is the only thing standing between one text and three.** `ready` is not a one-time event — ↩ back-to-making clears `ready_at` and a second "Ready ✓" fires the hook again, and the 10s undo bar flips `picked_up` back to `ready`. So `order-ready-sms` does not ask "is this ready"; it **claims** the row, writing `notified_at` in the same statement that filters on it being null, which makes concurrent fires serialise so exactly one comes back with a row. A failed send records `notify_error` but **never clears the claim**: a text that doesn't arrive degrades to card.html, still open in the customer's hand, whereas a duplicate text is noise the customer cannot explain. Note also that a Twilio `201` means *accepted*, not *delivered* — a Canadian carrier can filter silently, and only a real handset proves otherwise.

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

**`order_contacts` table** — [20260805083000_order_contacts.sql](supabase/migrations/20260805083000_order_contacts.sql). RLS on, **zero policies**, service role only:

| column | notes |
|---|---|
| `order_id` | uuid, **primary key**, FK to `orders` on delete cascade — one number per order, and the upsert target when a customer fixes a typo |
| `phone` | text, E.164 (`+1……`). Never returned to any client, not even masked |
| `created_at` | timestamptz |
| `notified_at` | timestamptz; **claimed before sending, never cleared** — the sole idempotency guard |
| `confirm_sent_at` | timestamptz ([20260805120000_contact_confirm.sql](supabase/migrations/20260805120000_contact_confirm.sql)); claimed by `order-contact` before the confirmation text. A **rate limit, not idempotency** — re-claimed after 60s, so a typo fix gets its own confirmation |
| `notify_error` | text; whatever Twilio refused with, or the `DRY RUN → …` line when the Twilio secrets are unset |

Delete the rows after the event — the header on the migration says so, and nothing does it automatically.

**Refresh — the three pages differ.** staff.html subscribes to `postgres_changes` on `public.orders` (`event: "*"`) and responds to any event by re-running `load()` — a full re-query and full re-render; the payload is ignored. A 30s `setInterval` backstops missed events and refreshes wait-time labels. It doesn't subscribe at all until sign-in succeeds (`start()`), so the channel carries the session JWT. board.html has no subscription: it polls `load()` every `POLL_MS` (5s), guarded by an `inFlight` flag so a slow query can't stack up. PostgREST can't hold a request open, so that is a fixed interval, not a server-held long poll. card.html polls the same way at the same 5s, on a customer's phone and battery — which is why it stops entirely `DONE_LINGER_MS` (2 min) after it sees the order go `picked_up`, long enough to survive the 10s undo bar. Adding a column the UI needs means updating the `.select()` list in the relevant file.

**The Incoming chime rides on that same `load()`.** `ringForNew()` diffs the `new` ids against the previous load's set and plays a WebAudio-synthesised two-note bell when any id is unseen — no audio file, and no `<audio>` element. The set starts as `null` so the backlog already on screen at sign-in doesn't ring, and it is *replaced* each load, so it stays bounded and a row aged out of the 6h window can't linger in it. Browsers block audio before a gesture, so the sign-in tap calls `unlockAudio()` to build the `AudioContext`; `chime()` re-`resume()`s it because a backgrounded tab gets suspended. A device with a stored session never taps that button, so `armAudioUnlock()` also grabs the first `pointerdown` anywhere on the page — until one lands, both sounds no-op on `!audio`. The header 🔔 toggle persists to `localStorage["staff-sound"]` and is the only mute — a muted device still shows the Incoming badge.

**The cancelled-order alert rides on `load()` too, but as a second query.** `load()` kicks off `loadCancels()` without awaiting it — those rows are `picked_up`, so `load()`'s own status filter can never see them. It selects `canceled_at is not null and cancel_ack_at is null` within 6h *of the cancellation*, and shows them one at a time, oldest first. `alarmForCancels()` diffs ids exactly like `ringForNew()` (same `null` start, same 🔔 mute) and plays a distinct lower repeating tone. `renderCancel()` returns early when the row on screen is already the one at the head of the queue, so a realtime event can't rebuild the sheet mid-read or wipe a failed-save message. The query fails soft: until `20260804051952_cancel_alert.sql` is pushed, the missing columns error out and no alert ever shows — the pages otherwise behave exactly as before, which is why this one goes wrong quietly.

That full re-render is why `renderIncoming()` snapshots each card-number `<input>` (value *and* caret) before wiping the list and restores it afterward, and why conflict messages live in a module-level `conflicts` map instead of the DOM. Without both, an unrelated realtime event mid-typing would eat what the cashier was entering.

## Gotchas

- **Time-window filters.** `load()` only fetches rows newer than a cutoff — 3h on the board, 6h on staff. An order left un-picked-up past that window silently disappears from the screen while still sitting in the table — *and keeps holding its queue card*, since the unique index has no time bound. That combination is why an accept that hits a duplicate looks the offender up with `findHolder()`, which queries by `ticket` with **no time filter**, and offers "Release card" (a plain `status='picked_up'`). It is the only in-app way to reclaim a number stranded on an invisible row.
- **Reads survive a dead session; writes don't.** `public can read orders` has no `to` clause, so `load()`, `loadCancels()` and `findHolder()` keep working with no JWT at all. A signed-out staff device therefore shows a fully populated, perfectly normal-looking screen where every tap is silently rejected. That is exactly the failure `writeFailed()` exists to make visible — any new write path must end in `.select("id")` and call it, or it inherits the invisible version.
- **The unique index can reject writes staff.html otherwise treats as infallible.** `setStatus()` ignores its error, so undoing a pickup within the 10s window fails silently if that card was re-issued in the meantime — the row just doesn't come back on the next `load()`. `↩` back-to-making is safe (the row keeps its own number, and both statuses are inside the index predicate).
- **The cancel alert is undismissable by design, and that is load-bearing.** No close button, no backdrop tap, no Escape, and a failed `cancel_ack_at` write leaves the sheet up with an error rather than closing. The only escape hatches are the 6h window and SQL. Anything that adds a "later" button hands out a card number twice.
- **Normalize card numbers before writing.** `normCard()` validates 1–100 and returns `String(Number(s))`, so `"07"` and `"7"` can't become two live cards — the index compares text and would happily allow both. It now exists in **three** copies — staff.html, card.html and order-contact — and `CARD_MIN`/`CARD_MAX` must agree across all of them, since printed QR stickers encode the range physically.
- **A card number is not an identity.** It is reused every few minutes, so anything keyed on `ticket` alone must resolve to a row `id` and then follow that id. card.html does this on first load; an "improvement" that re-queries by `ticket` on every poll would start showing one customer another customer's order — and, once SMS is live, telling the wrong person their food is ready.
- **Never trust an edge function's request payload.** `order-ready-sms` is deployed with JWT verification on, but the anon key is a valid JWT *and* is printed in every page served — so "carried a token" proves nothing. It takes only the id from the Database Webhook payload and re-reads `orders` itself; a version that believed `payload.record.status` could be made to send texts by anyone who viewed source.
- **The QR stickers are a deployed artifact.** They encode `https://gkawin.github.io/vendor-sync-v2/card.html#<n>` on 100 physical cards. Renaming or moving card.html, or changing the Pages path, silently breaks every card already printed.
- **`checked` alignment is fragile by construction.** `normChecked()` truncates/pads `checked` to `items.length`, so mismatched lengths degrade quietly rather than erroring. The live hazard: an `order.updated` fire rewrites `items` wholesale but leaves `checked` untouched, so editing an order in Square after staff have started ticking re-points existing checkmarks at the wrong items.
- **Item taps write through immediately.** `toggleItem()` updates the DOM optimistically, PATCHes the row, and reverts the class only if the write fails — so every device stays in sync, but a tap is a database round-trip.
- **Two write paths with different privileges.** All three edge functions use the **service role** key (bypasses RLS entirely). staff.html updates `status`, `ticket`, `ready_at`, `accepted_at`, `checked` and `cancel_ack_at` as a **signed-in user**, so the `staff can update orders` policy (`to authenticated`) in [20260804063000_staff_auth.sql](supabase/migrations/20260804063000_staff_auth.sql) must keep working. Postgres has no column-level RLS: that policy is row-level and permissive, so it buys "a signed-in human did this", not "only these columns". The anon write policies from the baseline are **dropped** — reads are the only thing anon can still do.
- **Everything here is publicly served.** `SUPABASE_URL`, `SUPABASE_ANON` and `STAFF_EMAIL` are constants at the top of each `<script>`. The staff **password is not** — it lives only in Supabase Auth, so a copy of staff.html without it is a read-only board. Because Pages uploads the repo root, all three edge functions' source ships publicly too — they read every secret (`SQUARE_*`, `TWILIO_*`, `READY_HOOK_SECRET`) from `Deno.env`, and it must stay that way. A Twilio auth token in a committed file would be a public credential with full account access.
- **Signature verification is URL-bound.** The HMAC covers `SQUARE_NOTIFICATION_URL + rawBody`, so that secret must match the URL registered in Square *exactly* or every delivery 403s.

## Conventions

Vanilla DOM APIs only in the pages — no framework, no bundler, no npm. The one browser dependency is `@supabase/supabase-js@2` from a CDN `<script>` tag; the edge function imports the same library via `npm:`. Rendering builds elements with `createElement` and `textContent` (never `innerHTML` for data). Styles are one inline `<style>` block per file. UI copy is English; Thai appears in menu item names coming from Square.
