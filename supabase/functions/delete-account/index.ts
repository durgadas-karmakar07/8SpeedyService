// POST /functions/v1/delete-account   body: { "confirm": "DELETE" }
// In-app account deletion (required by Google Play) for BOTH apps
// (customer + mechanic partner share the same Supabase Auth).
//   1. Verifies the caller's JWT
//   2. delete_account_data(uid): removes / anonymises personal data
//      (booking rows stay without identity for payment & tax records)
//   3. Soft-deletes the auth user: sessions end, phone number is freed.
// Self-contained (no shared imports) so it can be deployed on its own.

import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing server secret: ${name}`);
  return value;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "Please login again." }, 401);

    const anon = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await anon.auth.getUser(token);
    if (userError || !userData?.user) return json({ error: "Please login again." }, 401);
    const userId = userData.user.id;

    const body = await req.json().catch(() => ({}));
    if (body?.confirm !== "DELETE") {
      return json({ error: "Deletion not confirmed." }, 400);
    }

    const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { error: dataError } = await admin.rpc("delete_account_data", { p_uid: userId });
    if (dataError) {
      // Business-rule messages (active job / booking) are safe to show.
      return json({ error: dataError.message }, 409);
    }

    const { error: authError } = await admin.auth.admin.deleteUser(userId, true);
    if (authError) {
      console.error("deleteUser failed", userId, authError.message);
      return json({ error: "Account data removed, but logout failed. Please contact support." }, 500);
    }

    return json({ deleted: true });
  } catch (e) {
    console.error("delete-account error", e);
    return json({ error: "Could not delete account right now. Please try again." }, 500);
  }
});
