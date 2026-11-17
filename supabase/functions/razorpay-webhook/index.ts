// POST /functions/v1/razorpay-webhook   (deploy with --no-verify-jwt)
// Razorpay Dashboard -> Settings -> Webhooks -> add this URL, events:
//   payment.captured, order.paid
// Safety net: marks the booking PAID even if the customer's phone lost network
// right after paying (before the app could call razorpay-verify-payment).

import { adminClient, env, hmacSha256Hex, json, safeEqual } from "../_shared/razorpay.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const rawBody = await req.text();
    const signature = req.headers.get("x-razorpay-signature") ?? "";
    const expected = await hmacSha256Hex(env("RAZORPAY_WEBHOOK_SECRET"), rawBody);
    if (!signature || !safeEqual(expected, signature)) {
      return json({ error: "Invalid signature" }, 401);
    }

    const event = JSON.parse(rawBody);
    const type: string = event?.event ?? "";
    if (type !== "payment.captured" && type !== "order.paid") {
      return json({ ignored: type });
    }

    const payment = event?.payload?.payment?.entity ?? {};
    const orderId: string = payment.order_id ?? event?.payload?.order?.entity?.id ?? "";
    const paymentId: string = payment.id ?? "";
    if (!orderId || !paymentId) return json({ ignored: "missing ids" });

    const db = adminClient();
    const { data: booking, error } = await db
      .from("bookings")
      .select("id, platform_fee, payment_status")
      .eq("razorpay_order_id", orderId)
      .maybeSingle();
    if (error) throw error;
    if (!booking) return json({ ignored: "unknown order" });
    if (booking.payment_status === "PAID") return json({ ok: true, already: true });

    if (Number(payment.amount) !== Number(booking.platform_fee) * 100) {
      console.warn("Webhook amount mismatch", { orderId, amount: payment.amount });
      return json({ ignored: "amount mismatch" });
    }

    const { error: rpcErr } = await db.rpc("mark_booking_paid", {
      p_booking_id: booking.id,
      p_order_id: orderId,
      p_payment_id: paymentId,
    });
    if (rpcErr) throw rpcErr;
    return json({ ok: true });
  } catch (e) {
    console.error("razorpay-webhook failed:", e);
    // 500 makes Razorpay retry later.
    return json({ error: "internal" }, 500);
  }
});
