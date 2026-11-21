// POST /functions/v1/razorpay-create-order
// Body: { "booking_id": "<uuid>" }
// Creates (or re-uses) a Razorpay Order for the booking's platform fee.
// The AMOUNT IS READ FROM THE DATABASE — the app can never choose the price.
//
// Audit #2 fix: if the previous order of this booking was already PAID at
// Razorpay (the app lost network before verifying and the webhook was late),
// the payment is reconciled instead of creating a second order — the customer
// is never charged twice and the first payment is never lost. Every order is
// kept in `payment_orders`, so a late webhook for any order still finds the
// booking.

import {
  adminClient,
  corsHeaders,
  ensureCaptured,
  env,
  getCallerId,
  json,
  razorpayRequest,
  UUID_RE,
} from "../_shared/razorpay.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const userId = await getCallerId(req);
    if (!userId) return json({ error: "Please login again." }, 401);

    const { booking_id } = await req.json().catch(() => ({}));
    if (typeof booking_id !== "string" || !UUID_RE.test(booking_id)) {
      return json({ error: "Invalid booking." }, 400);
    }

    const db = adminClient();
    const { data: booking, error } = await db
      .from("bookings")
      .select("id, customer_id, status, payment_status, platform_fee, razorpay_order_id, vehicle_type")
      .eq("id", booking_id)
      .maybeSingle();

    if (error) throw error;
    if (!booking || booking.customer_id !== userId) {
      return json({ error: "Booking not found." }, 404);
    }
    if (booking.payment_status === "PAID") {
      return json({ error: "This booking is already paid.", already_paid: true }, 409);
    }
    if (booking.payment_status !== "PENDING" || booking.status !== "SEARCHING") {
      return json({ error: "This booking does not need payment. Please create a new booking." }, 409);
    }
    const amountPaise = Number(booking.platform_fee) * 100;
    if (!Number.isInteger(amountPaise) || amountPaise < 100) {
      return json({ error: "Invalid platform fee amount." }, 409);
    }

    // Abuse guard: at most 15 checkout attempts per customer per hour.
    const { count } = await db
      .from("payment_orders")
      .select("order_id", { count: "exact", head: true })
      .eq("customer_id", userId)
      .gte("created_at", new Date(Date.now() - 3600_000).toISOString());
    if ((count ?? 0) >= 15) {
      return json({ error: "Too many payment attempts. Please try again later." }, 429);
    }

    const keyId = env("RAZORPAY_KEY_ID");

    if (booking.razorpay_order_id) {
      try {
        const existing = await razorpayRequest(`/orders/${booking.razorpay_order_id}`);
        if (existing.status === "paid") {
          // Money already received for the previous order -> reconcile.
          const list = await razorpayRequest(`/orders/${booking.razorpay_order_id}/payments`);
          const items = (list.items as Record<string, unknown>[] | undefined) ?? [];
          const paid = items.find((p) =>
            (p.status === "captured" || p.status === "authorized") && Number(p.amount) === amountPaise
          );
          if (paid && await ensureCaptured(paid)) {
            const { error: rpcErr } = await db.rpc("mark_booking_paid", {
              p_booking_id: booking.id,
              p_order_id: booking.razorpay_order_id,
              p_payment_id: String(paid.id),
            });
            if (rpcErr) throw rpcErr;
            return json({ error: "This booking is already paid.", already_paid: true }, 409);
          }
        } else if (Number(existing.amount) === amountPaise) {
          return json({ order_id: booking.razorpay_order_id, amount: amountPaise, currency: "INR", key_id: keyId });
        }
      } catch (e) {
        console.warn("could not re-use previous order", booking.razorpay_order_id, String(e));
      }
    }

    const order = await razorpayRequest("/orders", {
      method: "POST",
      body: {
        amount: amountPaise,
        currency: "INR",
        receipt: booking.id.replace(/-/g, "").slice(0, 32),
        notes: {
          booking_id: booking.id,
          customer_id: userId,
          vehicle_type: booking.vehicle_type,
          purpose: "8SpeedyService platform fee",
        },
      },
    });

    const orderId = String(order.id);
    const { error: insErr } = await db.from("payment_orders").insert({
      order_id: orderId,
      booking_id: booking.id,
      customer_id: userId,
      amount_paise: amountPaise,
    });
    if (insErr) throw insErr;
    const { error: updErr } = await db
      .from("bookings")
      .update({ razorpay_order_id: orderId })
      .eq("id", booking.id)
      .eq("payment_status", "PENDING");
    if (updErr) throw updErr;

    return json({ order_id: orderId, amount: amountPaise, currency: "INR", key_id: keyId });
  } catch (e) {
    console.error("razorpay-create-order failed:", e);
    return json({ error: "Could not start payment right now. Please retry." }, 500);
  }
});
