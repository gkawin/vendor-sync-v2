// supabase/functions/square-webhook/index.ts
// ---------------------------------------------------------------------------
// Coconut Corner — Square → order board bridge
//
// Receives Square webhooks (order.created / order.updated), verifies the
// signature, looks up the ticket name the customer sees, and upserts the
// order into the `orders` table. Writes use the SERVICE ROLE key, so the
// public no longer needs insert rights — only Square can create orders.
//
// Deploy:  supabase functions deploy square-webhook --no-verify-jwt
// ---------------------------------------------------------------------------

import { createClient } from "npm:@supabase/supabase-js@2";

// --- Secrets (set with `supabase secrets set ...`) -------------------------
const SIGNATURE_KEY = Deno.env.get("SQUARE_SIGNATURE_KEY")!; // Webhooks → Signature Key
const NOTIFICATION_URL = Deno.env.get("SQUARE_NOTIFICATION_URL")!; // the EXACT URL you register in Square
const ACCESS_TOKEN = Deno.env.get("SQUARE_ACCESS_TOKEN")!; // your Production access token (secret!)
const SQUARE_ENV = Deno.env.get("SQUARE_ENV") ?? "production";
// These two are injected by Supabase automatically — don't set them yourself.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SQUARE_API =
  SQUARE_ENV === "sandbox"
    ? "https://connect.squareupsandbox.com"
    : "https://connect.squareup.com";

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);
const enc = new TextEncoder();

// --- Verify the request really came from Square ----------------------------
// HMAC-SHA256 over (notification URL + raw body), base64, constant-time compare.
async function validSignature(
  rawBody: string,
  headerSig: string | null,
): Promise<boolean> {
  if (!headerSig) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(SIGNATURE_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    enc.encode(NOTIFICATION_URL + rawBody),
  );
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return timingSafeEqual(expected, headerSig);
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// --- Read the order so we know what to show on the board -------------------
type Line = { qty: number; name: string };
async function fetchOrder(orderId: string): Promise<{
  ticket: string;
  state: string;
  items: Line[];
  isReturn: boolean;
} | null> {
  // order.created can land a split second before the order is readable — retry.
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(`${SQUARE_API}/v2/orders/${orderId}`, {
      headers: {
        Authorization: `Bearer ${ACCESS_TOKEN}`,
        "Content-Type": "application/json",
      },
    });
    if (res.ok) {
      const { order } = await res.json();
      const name = (order?.ticket_name ?? "").trim();
      // Use the ticket number you typed at checkout; fall back to a short id.
      const ticket = name || orderId.slice(-4).toUpperCase();

      // Square makes a NEW order for every refund/return/exchange, and it
      // carries a `returns` and/or `refunds` block. Those aren't food to cook,
      // so flag them and keep them off the board.
      const isReturn =
        (Array.isArray(order?.returns) && order.returns.length > 0) ||
        (Array.isArray(order?.refunds) && order.refunds.length > 0);

      // What the customer actually ordered — for the staff panel.
      const items: Line[] = (order?.line_items ?? []).map((li: any) => {
        let label = li.name ?? "Item";
        if (li.variation_name && li.variation_name !== li.name)
          label += ` (${li.variation_name})`;
        const mods = (li.modifiers ?? [])
          .map((m: any) => m.name)
          .filter(Boolean);
        if (mods.length) label += ` +${mods.join(", ")}`;
        if (li.note) label += ` — ${li.note}`;
        return { qty: Number(li.quantity ?? "1") || 1, name: label };
      });

      return { ticket, state: order?.state ?? "OPEN", items, isReturn };
    }
    if (res.status === 404) {
      await new Promise((r) => setTimeout(r, 700));
      continue;
    }
    console.error("RetrieveOrder failed", res.status, await res.text());
    return null;
  }
  return null;
}

Deno.serve(async (req) => {
  const rawBody = await req.text();

  if (
    !(await validSignature(
      rawBody,
      req.headers.get("x-square-hmacsha256-signature"),
    ))
  ) {
    return new Response("Invalid signature", { status: 403 });
  }

  let event: any;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }

  const type = event?.type as string | undefined;
  if (type !== "order.created" && type !== "order.updated") {
    return new Response("Ignored", { status: 200 }); // not an event we act on
  }

  const orderId =
    event?.data?.object?.order_created?.order_id ??
    event?.data?.object?.order_updated?.order_id ??
    event?.data?.id;
  if (!orderId) return new Response("No order id", { status: 200 });

  const info = await fetchOrder(orderId);
  if (!info) return new Response("Could not read order", { status: 200 });

  // Don't put these on the board:
  //  - CANCELED: a voided sale.
  //  - isReturn: Square spawns a separate order for every refund/return/exchange.
  // Either way, hide any existing row for this order id; for a brand-new
  // refund/return order the update simply matches nothing, so no phantom ticket.
  if (info.state === "CANCELED" || info.isReturn) {
    await sb
      .from("orders")
      .update({ status: "picked_up" })
      .eq("square_order_id", orderId);
    return new Response(
      info.isReturn ? "Return/refund — skipped" : "Canceled",
      { status: 200 },
    );
  }

  // Upsert: inserts on first sight (status defaults to 'preparing'), and only
  // refreshes the ticket afterward. status / created_at / ready_at are left
  // alone, so anything staff tapped on the board sticks.
  // NB: "COMPLETED" in Square just means paid — the pancakes still have to cook,
  // so we deliberately do NOT auto-mark it ready here. Staff do that.
  const { error } = await sb
    .from("orders")
    .upsert(
      { square_order_id: orderId, ticket: info.ticket, items: info.items },
      { onConflict: "square_order_id" },
    );
  if (error) {
    console.error("upsert failed", error);
    return new Response("DB error", { status: 500 });
  }

  return new Response("ok", { status: 200 });
});
