// Shared helpers for the Razorpay / maintenance Edge Functions.
// Secrets are read from Supabase Edge Function secrets (never shipped in the app):
//   RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, RAZORPAY_WEBHOOK_SECRET, CRON_SECRET
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically by Supabase.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.119.0";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing server secret: ${name}`);
  return value;
}

/** Service-role client: bypasses RLS. Use ONLY after verifying the caller. */
export function adminClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Returns the signed-in user's id from the request's JWT, or null. */
export async function getCallerId(req: Request): Promise<string | null> {
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user.id;
}

function razorpayAuthHeader(): string {
  return "Basic " + btoa(`${env("RAZORPAY_KEY_ID")}:${env("RAZORPAY_KEY_SECRET")}`);
}

export class RazorpayError extends Error {
  constructor(readonly status: number, readonly description: string) {
    super(`Razorpay API error (${status}): ${description}`);
  }
}

export async function razorpayRequest(
  path: string,
  init: { method?: string; body?: unknown } = {},
): Promise<Record<string, unknown>> {
  const res = await fetch(`https://api.razorpay.com/v1${path}`, {
    method: init.method ?? "GET",
    headers: {
      Authorization: razorpayAuthHeader(),
      "Content-Type": "application/json",
    },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    signal: AbortSignal.timeout(15_000),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const desc = (data as { error?: { description?: string } })?.error?.description;
    throw new RazorpayError(res.status, desc ?? "unknown");
  }
  return data as Record<string, unknown>;
}

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Constant-time string comparison (prevents timing attacks on signatures). */
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const ORDER_RE = /^order_[A-Za-z0-9]{6,40}$/;
export const PAYMENT_RE = /^pay_[A-Za-z0-9]{6,40}$/;

export interface KnownOrder {
  order_id: string;
  booking_id: string;
  amount_paise: number;
}

/**
 * Finds the booking an order belongs to. Every order we ever created is kept in
 * `payment_orders`, so a payment for an older order (customer retried checkout)
 * is never lost.
 */
export async function findOrder(db: SupabaseClient, orderId: string): Promise<KnownOrder | null> {
  const { data } = await db
    .from("payment_orders")
    .select("order_id, booking_id, amount_paise")
    .eq("order_id", orderId)
    .maybeSingle();
  if (data) return data as KnownOrder;
  const { data: booking } = await db
    .from("bookings")
    .select("id, platform_fee")
    .eq("razorpay_order_id", orderId)
    .maybeSingle();
  if (!booking) return null;
  return { order_id: orderId, booking_id: booking.id, amount_paise: Number(booking.platform_fee) * 100 };
}

/** Captures an `authorized` payment so it is not auto-refunded by Razorpay. */
export async function ensureCaptured(payment: Record<string, unknown>): Promise<boolean> {
  if (payment.status === "captured") return true;
  if (payment.status !== "authorized") return false;
  try {
    const captured = await razorpayRequest(`/payments/${payment.id}/capture`, {
      method: "POST",
      body: { amount: payment.amount, currency: payment.currency ?? "INR" },
    });
    return captured.status === "captured";
  } catch (e) {
    // Already captured by Razorpay's automatic capture in the meantime.
    if (e instanceof RazorpayError && /already been captured/i.test(e.description)) return true;
    throw e;
  }
}
