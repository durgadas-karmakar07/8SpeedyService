// POST /functions/v1/maintenance   (deploy with --no-verify-jwt)
// Called every 10 minutes by pg_cron (pg_net). The database sends a one-time
// nonce in the header x-cron-nonce that only it can create; the function
// consumes it (public.maintenance_consume_nonce) — no shared secret needed.
//
// 1. Automatic refunds: bookings with refund_status = 'REQUESTED' (paid booking
//    cancelled before a mechanic accepted, expired search, account deletion,
//    payment that landed after a cancel) and duplicate payments are refunded
//    through Razorpay. Can be switched off with app_config.auto_refunds_enabled.
// 2. Storage hygiene: voice notes that were uploaded but never linked to a
//    booking (older than 2 h) and voice notes of bookings that ended more than
//    30 days ago are deleted (data minimisation, DPDP Act).

import { adminClient, json, razorpayRequest, RazorpayError } from "../_shared/razorpay.ts";

type Db = ReturnType<typeof adminClient>;

async function refundBookings(db: Db) {
  const done: string[] = [];
  const failed: string[] = [];
  const { data: rows, error } = await db
    .from("bookings")
    .select("id, platform_fee, razorpay_payment_id, refund_id, refund_attempts")
    .eq("refund_status", "REQUESTED")
    .eq("payment_status", "PAID")
    .not("razorpay_payment_id", "is", null)
    .lt("refund_attempts", 5)
    .limit(20);
  if (error) throw error;

  for (const b of rows ?? []) {
    // Claim the row so two runs never refund the same booking.
    const { data: claimed } = await db
      .from("bookings")
      .update({ refund_status: "PROCESSING", refund_attempts: (b.refund_attempts ?? 0) + 1 })
      .eq("id", b.id)
      .eq("refund_status", "REQUESTED")
      .select("id")
      .maybeSingle();
    if (!claimed) continue;

    try {
      let refund: Record<string, unknown>;
      if (b.refund_id) {
        refund = await razorpayRequest(`/payments/${b.razorpay_payment_id}/refunds/${b.refund_id}`);
      } else {
        refund = await razorpayRequest(`/payments/${b.razorpay_payment_id}/refund`, {
          method: "POST",
          body: {
            amount: Number(b.platform_fee) * 100,
            speed: "normal",
            receipt: `rf_${String(b.id).replace(/-/g, "").slice(0, 30)}`,
            notes: { booking_id: b.id, reason: "8SpeedyService automatic refund" },
          },
        });
      }
      const status = String(refund.status ?? "");
      await db.from("bookings").update({
        refund_id: refund.id ?? b.refund_id,
        refund_status: status === "processed" ? "REFUNDED" : status === "failed" ? "FAILED" : "PROCESSING",
        refunded_at: status === "processed" ? new Date().toISOString() : null,
      }).eq("id", b.id);
      done.push(b.id);
    } catch (e) {
      const alreadyRefunded = e instanceof RazorpayError &&
        /fully refunded|greater than the refund|already been refunded/i.test(e.description);
      await db.from("bookings").update({ refund_status: alreadyRefunded ? "REFUNDED" : "REQUESTED" }).eq("id", b.id);
      if (!alreadyRefunded) {
        failed.push(b.id);
        console.error("refund failed", b.id, String(e));
      }
    }
  }
  return { done, failed };
}

/** A second payment for an already-paid booking is returned to the customer. */
async function refundDuplicatePayments(db: Db) {
  const refunded: string[] = [];
  const { data: orders, error } = await db
    .from("payment_orders")
    .select("order_id, booking_id, amount_paise, payment_id, bookings!inner(razorpay_payment_id)")
    .eq("status", "PAID")
    .not("payment_id", "is", null)
    .limit(50);
  if (error) throw error;
  for (const o of orders ?? []) {
    const bookingPayment = (o as unknown as { bookings: { razorpay_payment_id: string | null } }).bookings
      ?.razorpay_payment_id;
    if (!bookingPayment || bookingPayment === o.payment_id) continue;
    const { data: claimed } = await db.from("payment_orders")
      .update({ status: "REFUNDING", updated_at: new Date().toISOString() })
      .eq("order_id", o.order_id).eq("status", "PAID").select("order_id").maybeSingle();
    if (!claimed) continue;
    try {
      await razorpayRequest(`/payments/${o.payment_id}/refund`, {
        method: "POST",
        body: { amount: o.amount_paise, speed: "normal", notes: { booking_id: o.booking_id, reason: "duplicate payment" } },
      });
      await db.from("payment_orders").update({ status: "REFUNDED", updated_at: new Date().toISOString() })
        .eq("order_id", o.order_id);
      refunded.push(o.order_id);
    } catch (e) {
      const alreadyRefunded = e instanceof RazorpayError && /fully refunded|already been refunded/i.test(e.description);
      await db.from("payment_orders").update({ status: alreadyRefunded ? "REFUNDED" : "PAID" }).eq("order_id", o.order_id);
      console.error("duplicate refund failed", o.order_id, String(e));
    }
  }
  return refunded;
}

async function cleanVoiceNotes(db: Db) {
  const { data, error } = await db.rpc("maintenance_voice_notes_to_delete", { p_limit: 200 });
  if (error) throw error;
  const paths = ((data ?? []) as { name: string }[]).map((r) => r.name);
  if (paths.length === 0) return 0;
  const { error: rmErr } = await db.storage.from("voice-notes").remove(paths);
  if (rmErr) throw rmErr;
  return paths.length;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const nonce = req.headers.get("x-cron-nonce") ?? "";
  if (!/^[a-f0-9]{64}$/.test(nonce)) return json({ error: "Unauthorized" }, 401);

  const db = adminClient();
  const { data: valid, error: nonceErr } = await db.rpc("maintenance_consume_nonce", { p_nonce: nonce });
  if (nonceErr || valid !== true) return json({ error: "Unauthorized" }, 401);

  const report: Record<string, unknown> = {};
  try {
    const { data: cfg } = await db.from("app_config").select("auto_refunds_enabled").eq("id", 1).maybeSingle();
    const hasRazorpay = Boolean(Deno.env.get("RAZORPAY_KEY_ID") && Deno.env.get("RAZORPAY_KEY_SECRET"));
    if (cfg?.auto_refunds_enabled !== false && hasRazorpay) {
      report.refunds = await refundBookings(db);
      report.duplicate_refunds = await refundDuplicatePayments(db);
    }
  } catch (e) {
    console.error("refund step failed", e);
    report.refund_error = true;
  }
  try {
    report.voice_notes_deleted = await cleanVoiceNotes(db);
  } catch (e) {
    console.error("voice note cleanup failed", e);
    report.voice_error = true;
  }
  return json({ ok: true, ...report });
});
