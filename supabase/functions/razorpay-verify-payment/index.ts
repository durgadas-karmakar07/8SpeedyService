// POST /functions/v1/razorpay-verify-payment
// Body: { booking_id, razorpay_order_id, razorpay_payment_id, razorpay_signature }
// Verifies the checkout signature with the SECRET key (server only), double-checks
// the payment with Razorpay's API (right order, right amount), captures an
// `authorized` payment, then marks the booking PAID.

import {
  adminClient,
  corsHeaders,
  ensureCaptured,
  env,
  findOrder,
  getCallerId,
  hmacSha256Hex,
  json,
  ORDER_RE,
  PAYMENT_RE,
  razorpayRequest,
  safeEqual,
  UUID_RE,
} from "../_shared/razorpay.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const userId = await getCallerId(req);
    if (!userId) return json({ error: "Please login again." }, 401);

    const body = await req.json().catch(() => ({}));
    const bookingId = String(body.booking_id ?? "");
    const orderId = String(body.razorpay_order_id ?? "");
    const paymentId = String(body.razorpay_payment_id ?? "");
    const signature = String(body.razorpay_signature ?? "");

    if (!UUID_RE.test(bookingId) || !ORDER_RE.test(orderId) || !PAYMENT_RE.test(paymentId) ||
        !/^[a-f0-9]{64}$/.test(signature)) {
      return json({ error: "Incomplete payment details." }, 400);
    }

    const db = adminClient();
    const { data: booking, error } = await db
      .from("bookings")
      .select("id, customer_id, payment_status, razorpay_payment_id")
      .eq("id", bookingId)
      .maybeSingle();
    if (error) throw error;
    if (!booking || booking.customer_id !== userId) {
      return json({ error: "Booking not found." }, 404);
    }
    if (booking.payment_status === "PAID" && booking.razorpay_payment_id === paymentId) {
      return json({ verified: true, payment_status: "PAID" });
    }

    // Any order this booking ever had is acceptable (customer may have retried).
    const order = await findOrder(db, orderId);
    if (!order || order.booking_id !== bookingId) {
      return json({ error: "Payment does not match this booking." }, 400);
    }

    // 1) Signature: HMAC_SHA256(order_id + "|" + payment_id, key_secret)
    const expected = await hmacSha256Hex(env("RAZORPAY_KEY_SECRET"), `${orderId}|${paymentId}`);
    if (!safeEqual(expected, signature)) {
      console.warn("Invalid Razorpay signature for booking", bookingId);
      return json({ error: "Payment verification failed." }, 400);
    }

    // 2) Ask Razorpay directly: right order, right amount, money received.
    const payment = await razorpayRequest(`/payments/${paymentId}`);
    const amountOk = Number(payment.amount) === Number(order.amount_paise);
    if (payment.order_id !== orderId || !amountOk) {
      console.warn("Razorpay payment mismatch", { bookingId, orderId, status: payment.status });
      return json({ error: "Payment not confirmed by Razorpay yet. Please retry." }, 400);
    }
    if (!(await ensureCaptured(payment))) {
      return json({ error: "Payment not confirmed by Razorpay yet. Please retry." }, 400);
    }

    const { error: rpcErr } = await db.rpc("mark_booking_paid", {
      p_booking_id: bookingId,
      p_order_id: orderId,
      p_payment_id: paymentId,
    });
    if (rpcErr) throw rpcErr;

    return json({ verified: true, payment_status: "PAID" });
  } catch (e) {
    console.error("razorpay-verify-payment failed:", e);
    return json({ error: "Could not confirm payment right now. Please retry." }, 500);
  }
});
