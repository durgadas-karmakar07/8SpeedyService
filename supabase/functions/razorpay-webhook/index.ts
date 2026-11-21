// POST /functions/v1/razorpay-webhook   (deploy with --no-verify-jwt)
// Razorpay Dashboard -> Settings -> Webhooks -> add this URL, events:
//   payment.captured, order.paid, refund.processed, refund.failed
// Safety net: marks the booking PAID even if the customer's phone lost network
// right after paying, and records refunds made by the maintenance job.

import {
  adminClient,
  env,
  findOrder,
  hmacSha256Hex,
  json,
  safeEqual,
} from "../_shared/razorpay.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const rawBody = await req.text();
    if (rawBody.length > 200_000) return json({ error: "Too large" }, 413);
    const signature = req.headers.get("x-razorpay-signature") ?? "";
    const expected = await hmacSha256Hex(env("RAZORPAY_WEBHOOK_SECRET"), rawBody);
    if (!signature || !safeEqual(expected, signature)) {
      return json({ error: "Invalid signature" }, 401);
    }

    const event = JSON.parse(rawBody);
    const type: string = event?.event ?? "";
    const db = adminClient();

    if (type === "refund.processed" || type === "refund.failed") {
      const refund = event?.payload?.refund?.entity ?? {};
      const paymentId: string = refund.payment_id ?? "";
      if (!paymentId) return json({ ignored: "missing payment id" });
      const { error } = await db
        .from("bookings")
        .update(type === "refund.processed"
          ? { refund_status: "REFUNDED", refund_id: refund.id ?? null, refunded_at: new Date().toISOString() }
          : { refund_status: "FAILED", refund_id: refund.id ?? null })
        .eq("razorpay_payment_id", paymentId);
      if (error) throw error;
      return json({ ok: true });
    }

    if (type !== "payment.captured" && type !== "order.paid") {
      return json({ ignored: type });
    }

    const payment = event?.payload?.payment?.entity ?? {};
    const orderId: string = payment.order_id ?? event?.payload?.order?.entity?.id ?? "";
    const paymentId: string = payment.id ?? "";
    if (!orderId || !paymentId) return json({ ignored: "missing ids" });

    const order = await findOrder(db, orderId);
    if (!order) return json({ ignored: "unknown order" });

    if (Number(payment.amount) !== Number(order.amount_paise)) {
      console.warn("Webhook amount mismatch", { orderId, amount: payment.amount });
      return json({ ignored: "amount mismatch" });
    }

    const { error: rpcErr } = await db.rpc("mark_booking_paid", {
      p_booking_id: order.booking_id,
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
