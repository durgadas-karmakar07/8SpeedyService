// POST /functions/v1/razorpay-create-order
// Body: { "booking_id": "<uuid>" }
// Creates (or re-uses) a Razorpay Order for the booking's platform fee.
// The AMOUNT IS READ FROM THE DATABASE — the app can never choose the price.

import {
  adminClient,
  corsHeaders,
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

    const keyId = env("RAZORPAY_KEY_ID");

    // Re-use an existing order if it is still payable (user retried checkout).
    if (booking.razorpay_order_id) {
      try {
        const existing = await razorpayRequest(`/orders/${booking.razorpay_order_id}`);
        if (existing.status !== "paid" && Number(existing.amount) === amountPaise) {
          return json({
            order_id: booking.razorpay_order_id,
            amount: amountPaise,
            currency: "INR",
            key_id: keyId,
          });
        }
      } catch (_) {
        // fall through and create a fresh order
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
