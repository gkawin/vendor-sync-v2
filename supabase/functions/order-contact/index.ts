// supabase/functions/order-contact/index.ts
// ---------------------------------------------------------------------------
// Coconut Corner — takes the phone number a customer typed into card.html.
//
// The customer scans the QR sticker on their queue card, lands on card.html,
// and types their own number on their own phone, away from the counter. That
// is the whole point of the design: the cashier's workload does not change at
// all, and nobody stands at the till while a number is entered.
//
// This function exists because the number must NOT go into `orders`: the
// baseline's `public can read orders` policy has no `to` clause and the anon
// key is a constant in every page we serve. So the row is written here, with
// the SERVICE ROLE key, into `order_contacts` — a table with RLS on and no
// policies at all, which nothing but the service role can read.
//
// Callers are anonymous customers with no Supabase JWT, so:
//   supabase functions deploy order-contact --no-verify-jwt
// (Same trap as square-webhook: `npm run deploy` is NOT this command.)
// ---------------------------------------------------------------------------

import { createClient } from "npm:@supabase/supabase-js@2";

// Injected by Supabase automatically — don't set them yourself.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

// card.html is served from GitHub Pages, this runs on supabase.co, so every
// call is cross-origin. No cookies or Authorization header are involved — the
// request carries nothing a browser would attach on its own — so "*" gives
// away no authority here, and it keeps localhost previews working during the
// three days before the event.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Every Canadian area code in the NANP. card.html checks this too, for a fast
// error message; this is the copy that counts, since a public page's checks
// can simply be skipped.
const CA_NPA = new Set([
  "204", "226", "236", "249", "250", "263", "289", "306", "343", "354", "365",
  "367", "368", "382", "387", "403", "416", "418", "428", "431", "437", "438",
  "450", "468", "474", "506", "514", "519", "548", "579", "581", "584", "587",
  "604", "613", "639", "647", "672", "683", "705", "709", "742", "753", "778",
  "780", "782", "807", "819", "825", "867", "873", "879", "902", "905",
]);

function normPhone(raw: unknown): string | null {
  let d = String(raw ?? "").replace(/\D/g, "");
  if (d.length === 11 && d[0] === "1") d = d.slice(1);
  if (d.length !== 10) return null;
  if (!CA_NPA.has(d.slice(0, 3))) return null;
  return "+1" + d;
}

// Same rule as normCard() in staff.html and card.html: "07" and "7" are the
// same card, and only 1–100 exist.
function normCard(raw: unknown): string | null {
  const s = String(raw ?? "").trim();
  if (!/^\d{1,3}$/.test(s)) return null;
  const n = Number(s);
  return n >= 1 && n <= 100 ? String(n) : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Bad request" }, 400);
  }

  const phone = normPhone(body?.phone);
  if (!phone) {
    return json({ error: "We can only text Canadian mobile numbers." }, 400);
  }

  const card = normCard(body?.card);
  const orderId = String(body?.order_id ?? "");
  if (!card || !/^[0-9a-f-]{36}$/i.test(orderId)) {
    return json({ error: "Bad request" }, 400);
  }

  // The order id comes from a public page, so it is a claim, not a fact. Three
  // things have to hold, and together they are also the whole abuse story:
  //
  //   status = 'preparing'  — rule 1, the cashier has accepted this card, and
  //                           rule 2's cutoff: once it is 'ready' the message
  //                           has already gone, so there is nothing to change.
  //                           A 'picked_up' row is finished, which is what
  //                           frees the card for its next holder.
  //   ticket  = the scanned card — ties the id to the number on the sticker in
  //                           the customer's hand.
  //
  // Someone enumerating card numbers can therefore only ever attach a number
  // to an order that is genuinely in the pan right now, one number at a time,
  // and the real customer overwrites it by scanning their own card. For a
  // one-stall event that is a proportionate amount of defence.
  const { data: order, error: lookupErr } = await sb
    .from("orders")
    .select("id,ticket,status")
    .eq("id", orderId)
    .eq("ticket", card)
    .eq("status", "preparing")
    .maybeSingle();

  if (lookupErr) {
    console.error("order lookup failed", lookupErr);
    return json({ error: "Something went wrong. Keep the page open." }, 500);
  }
  if (!order) {
    return json(
      { error: "That order isn't in the pan any more — keep this page open instead." },
      409,
    );
  }

  // Upsert, so a customer who mistyped can simply send it again. `notified_at`
  // is left alone on the way in and is only ever written by the sender, which
  // refuses to send when it is already set.
  const { error: writeErr } = await sb
    .from("order_contacts")
    .upsert(
      { order_id: order.id, phone },
      { onConflict: "order_id" },
    )
    .select("order_id");

  if (writeErr) {
    console.error("contact upsert failed", writeErr);
    return json({ error: "Couldn't save that. Keep the page open." }, 500);
  }

  // Deliberately returns nothing about the number — not even a masked echo.
  // Nothing anonymous should be able to read a phone number back out.
  return json({ ok: true });
});
