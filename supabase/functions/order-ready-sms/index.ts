// supabase/functions/order-ready-sms/index.ts
// ---------------------------------------------------------------------------
// Coconut Corner — texts a customer once, when their order goes ready.
//
// Fired by a Supabase Database Webhook on UPDATE of public.orders, NOT by
// staff.html. That is deliberate: the till's page can be closed, backgrounded
// or offline at the moment someone taps "Ready ✓", and a notification that
// only fires when a browser tab happens to be alive is not a notification.
//
// Deploy — note this one does NOT take --no-verify-jwt, unlike square-webhook
// and order-contact. Its only caller is the database, which can send a real
// key, so leave JWT verification on:
//
//   supabase functions deploy order-ready-sms
//   supabase secrets set TWILIO_ACCOUNT_SID=... TWILIO_AUTH_TOKEN=... \
//                        TWILIO_FROM=+1604... READY_HOOK_SECRET=...
//
// Then in Studio → Database → Webhooks:
//   table public.orders, event UPDATE, type "Supabase Edge Functions",
//   function order-ready-sms, and add the header
//     x-ready-hook-secret: <the same READY_HOOK_SECRET>
//
// Until TWILIO_ACCOUNT_SID is set this runs as a DRY RUN: it does every step
// including claiming the row, but records what it would have sent instead of
// calling Twilio. Switching to live sending is `supabase secrets set` alone —
// no code change.
// ---------------------------------------------------------------------------

import { createClient } from "npm:@supabase/supabase-js@2";

// Injected by Supabase automatically — don't set them yourself.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const TWILIO_SID = Deno.env.get("TWILIO_ACCOUNT_SID") ?? "";
const TWILIO_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
const TWILIO_FROM = Deno.env.get("TWILIO_FROM") ?? ""; // e.g. +16045550123
const TWILIO_MSG_SID = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID") ?? "";
const HOOK_SECRET = Deno.env.get("READY_HOOK_SECRET") ?? "";

const LIVE = Boolean(TWILIO_SID && TWILIO_TOKEN && (TWILIO_FROM || TWILIO_MSG_SID));

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

// One GSM-7 segment (160 chars) so a slow card can't turn into two billed
// messages — and so nothing gets truncated by a carrier.
const smsBody = (card: string) =>
  `Coconut Corner: order #${card} is ready! Please come to the counter. Thanks for waiting :)`;

// Never put a whole number in a log line or an error column.
const mask = (p: string) => (p.length > 4 ? "…" + p.slice(-4) : "…");

async function sendSms(to: string, body: string): Promise<string | null> {
  const form = new URLSearchParams({ To: to, Body: body });
  if (TWILIO_MSG_SID) form.set("MessagingServiceSid", TWILIO_MSG_SID);
  else form.set("From", TWILIO_FROM);

  const res = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_SID}/Messages.json`,
    {
      method: "POST",
      headers: {
        Authorization: "Basic " + btoa(`${TWILIO_SID}:${TWILIO_TOKEN}`),
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form,
    },
  );

  const out = await res.json().catch(() => ({} as any));
  if (!res.ok) return `twilio ${res.status}: ${out?.message ?? "unknown"}`;

  // NB: a 201 here means Twilio ACCEPTED the message, not that it arrived. A
  // Canadian carrier can still filter it silently, and nothing in this response
  // will say so. The only way to know is a real handset on a real SIM.
  console.log("queued", out?.sid, "->", mask(to), "status", out?.status);
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  // Defence in depth. JWT verification is on for this function, but the anon
  // key is a valid JWT *and* it is printed in every page we serve — so "has a
  // token" is not by itself evidence the database sent this.
  if (HOOK_SECRET && req.headers.get("x-ready-hook-secret") !== HOOK_SECRET) {
    return new Response("no", { status: 401 });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response("bad json", { status: 400 });
  }

  const orderId = String(payload?.record?.id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(orderId)) return new Response("ok", { status: 200 });

  // The payload is a claim, not a fact — whoever POSTed this chose every field
  // in `record`. Re-read the row and believe the database instead.
  const { data: order, error: orderErr } = await sb
    .from("orders")
    .select("id,ticket,status")
    .eq("id", orderId)
    .maybeSingle();

  if (orderErr) {
    console.error("order read failed", orderErr);
    return new Response("retry", { status: 500 });
  }
  if (!order || order.status !== "ready" || !order.ticket) {
    return new Response("ok", { status: 200 }); // not our moment
  }

  // ── The one thing that must not go wrong ───────────────────────────────
  // 'ready' is not a one-time event. ↩ back-to-making clears ready_at and a
  // second "Ready ✓" fires this again; the 10s undo bar flips picked_up back
  // to ready and fires it again too. So the guard cannot be "is it ready" — it
  // has to be "has this row been claimed".
  //
  // Claiming by writing notified_at in the same statement that filters on it
  // makes that atomic: two concurrent fires race, Postgres serialises them,
  // and exactly one comes back with a row.
  const { data: claimed, error: claimErr } = await sb
    .from("order_contacts")
    .update({ notified_at: new Date().toISOString() })
    .eq("order_id", order.id)
    .is("notified_at", null)
    .select("order_id,phone");

  if (claimErr) {
    console.error("claim failed", claimErr);
    return new Response("retry", { status: 500 });
  }
  if (!claimed?.length) {
    // Either nobody signed up for a text, or it has already gone out.
    return new Response("ok", { status: 200 });
  }

  const { phone } = claimed[0];
  const body = smsBody(String(order.ticket));

  if (!LIVE) {
    await sb.from("order_contacts")
      .update({ notify_error: `DRY RUN → ${mask(phone)}: ${body}` })
      .eq("order_id", order.id);
    console.log("DRY RUN (no Twilio secrets set) ->", mask(phone));
    return new Response("ok (dry run)", { status: 200 });
  }

  let failure: string | null = null;
  try {
    failure = await sendSms(phone, body);
  } catch (e) {
    failure = `send threw: ${e instanceof Error ? e.message : String(e)}`;
  }

  if (failure) {
    console.error("sms failed", failure, mask(phone));
    // Recorded, but notified_at is deliberately NOT cleared. A retry would
    // risk a second text on the ambiguous failures (timeouts, where Twilio may
    // well have sent it), and the customer is not stranded either way —
    // card.html is still open in their hand, updating on its own. A missed
    // text degrades to the status page; a duplicate text is just noise the
    // customer can't explain.
    await sb.from("order_contacts")
      .update({ notify_error: failure })
      .eq("order_id", order.id);
  }

  return new Response("ok", { status: 200 });
});
