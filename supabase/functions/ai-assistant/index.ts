// POST /functions/v1/ai-assistant   (JWT required)
// "8Speedy Assist" — AI vehicle diagnosis for customers and a repair guide for
// mechanics.
//
// Body (customer):  { mode: "customer", vehicle_id?: uuid, vehicle?: {...},
//                     issue_tags: string[], description: string, language: "en"|"hi"|"bn" }
// Body (mechanic):  { mode: "mechanic", booking_id: uuid, language?: ... }
//   (the job's vehicle + issues are read from the database, never trusted from the app)
//
// Engine: Claude (Anthropic API) when the Edge Function secret ANTHROPIC_API_KEY
// is set and app_config.ai_enabled is true; otherwise — or if the call fails —
// the built-in expert system in rules.ts. Optional secrets: AI_MODEL (default
// claude-opus-5-5), AI_EFFORT (default low).
// Every answer is stored in public.ai_requests (the customer can link it to the
// booking so the mechanic sees the summary). Per-user daily limits come from
// app_config (ai_daily_limit_customer / ai_daily_limit_mechanic).

import Anthropic from "npm:@anthropic-ai/sdk@1.5.0";
import { adminClient, corsHeaders, getCallerId, json, UUID_RE } from "../_shared/razorpay.ts";
import { AssistResult, Category, diagnose, ISSUE_LABELS } from "./rules.ts";

const CATEGORIES = ["cycle_toto", "two_wheeler", "four_wheeler", "heavy_vehicle"];
const LANGUAGES: Record<string, string> = {
  en: "simple English",
  hi: "simple Hindi (Devanagari script)",
  bn: "simple Bengali (Bengali script)",
};

const SYSTEM_PROMPT = `You are "8Speedy Assist", the roadside-repair expert of 8SpeedyService, an on-demand mechanic service in Durgapur, West Bengal, India. Verified local mechanics come to the customer's location.

You receive JSON describing a stranded customer's vehicle (category, body type, brand, model, fuel), the issue chips they selected and their own words (often Hinglish or Bengali written in English letters).

Your answer must follow the JSON schema exactly:
- summary: 1–2 short sentences a stressed person understands immediately.
- urgency: low | medium | high | emergency. Use "emergency" for injuries, fire, smoke from wiring, fuel leaks or crashes on a highway, and then tell them to call 112 (or 108 for an ambulance) first in do_now.
- safe_to_ride: false whenever brakes, steering, tyres, overheating, leaks or crash damage are involved.
- likely_causes: 2–4 causes, most likely first; probability is an integer 1–100 and all add up to about 100; explanation in one sentence.
- suggested_issue_tags: chosen ONLY from the allowed list given in the input (exact spelling).
- estimated_cost: a realistic range in Indian rupees for labour + common parts at a roadside/local workshop in Durgapur in 2026 for this exact vehicle category; note says the mechanic confirms the final price before starting.
- do_now: up to 4 safe actions while waiting (hazard lights, move off the road, switch off engine...).
- avoid: up to 3 things that would make it worse or unsafe.
- questions_for_mechanic: up to 3 useful questions for the customer to ask.
- diagnostic_steps and tools_and_parts: only for mode "mechanic" — a step-by-step check list for the mechanic (up to 8 steps) and the tools/parts to bring (up to 8). For mode "customer" return empty arrays.

Rules:
- Safety first. Never suggest risky do-it-yourself work: no opening a hot radiator cap, no working under a vehicle without stands, no touching EV/e-rickshaw battery packs, no bypassing fuses.
- Do not invent facts about the specific vehicle you are not reasonably sure about; prefer common, well-known faults for that category in Indian conditions.
- Never ask for or mention payment IDs, UPI handles, phone numbers or links. The platform fee is already handled in the app; repair charges are paid to the mechanic only after the work.
- Write every human-readable string in the language requested in the input. Keep each string short (under 200 characters).`;

const RESULT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "summary", "urgency", "safe_to_ride", "likely_causes", "suggested_issue_tags", "estimated_cost",
    "do_now", "avoid", "questions_for_mechanic", "diagnostic_steps", "tools_and_parts",
  ],
  properties: {
    summary: { type: "string" },
    urgency: { type: "string", enum: ["low", "medium", "high", "emergency"] },
    safe_to_ride: { type: "boolean" },
    likely_causes: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["title", "probability", "explanation"],
        properties: {
          title: { type: "string" },
          probability: { type: "integer" },
          explanation: { type: "string" },
        },
      },
    },
    suggested_issue_tags: { type: "array", items: { type: "string", enum: [...ISSUE_LABELS] } },
    estimated_cost: {
      type: "object",
      additionalProperties: false,
      required: ["min_inr", "max_inr", "note"],
      properties: {
        min_inr: { type: "integer" },
        max_inr: { type: "integer" },
        note: { type: "string" },
      },
    },
    do_now: { type: "array", items: { type: "string" } },
    avoid: { type: "array", items: { type: "string" } },
    questions_for_mechanic: { type: "array", items: { type: "string" } },
    diagnostic_steps: { type: "array", items: { type: "string" } },
    tools_and_parts: { type: "array", items: { type: "string" } },
  },
};

// deno-lint-ignore no-control-regex
const CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u00AD\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/g;

function clean(value: unknown, max: number): string {
  return String(value ?? "").replace(CONTROL, " ").replace(/\s+/g, " ").trim().slice(0, max);
}

function cleanList(value: unknown, maxItems: number, maxLen = 200): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((v) => clean(v, maxLen)).filter((v) => v.length > 0).slice(0, maxItems);
}

/** Validates and bounds a model answer so the apps can always render it. */
function sanitize(raw: Record<string, unknown>, mode: string): AssistResult {
  const urgency = ["low", "medium", "high", "emergency"].includes(String(raw.urgency))
    ? raw.urgency as AssistResult["urgency"]
    : "medium";
  const causes = Array.isArray(raw.likely_causes) ? raw.likely_causes : [];
  const cost = (raw.estimated_cost ?? {}) as Record<string, unknown>;
  const minInr = Math.max(0, Math.min(500000, Math.round(Number(cost.min_inr) || 0)));
  const maxInr = Math.max(minInr, Math.min(500000, Math.round(Number(cost.max_inr) || minInr)));
  return {
    summary: clean(raw.summary, 400),
    urgency,
    safe_to_ride: raw.safe_to_ride === true,
    likely_causes: causes.slice(0, 4).map((c) => {
      const o = (c ?? {}) as Record<string, unknown>;
      return {
        title: clean(o.title, 100),
        probability: Math.max(1, Math.min(100, Math.round(Number(o.probability) || 1))),
        explanation: clean(o.explanation, 240),
      };
    }).filter((c) => c.title.length > 0),
    suggested_issue_tags: cleanList(raw.suggested_issue_tags, 4, 40)
      .filter((t) => (ISSUE_LABELS as readonly string[]).includes(t)),
    estimated_cost: { min_inr: minInr, max_inr: maxInr, note: clean(cost.note, 200) },
    do_now: cleanList(raw.do_now, 5),
    avoid: cleanList(raw.avoid, 4),
    questions_for_mechanic: cleanList(raw.questions_for_mechanic, 4),
    diagnostic_steps: mode === "mechanic" ? cleanList(raw.diagnostic_steps, 8, 240) : [],
    tools_and_parts: mode === "mechanic" ? cleanList(raw.tools_and_parts, 8, 120) : [],
  };
}

async function askClaude(apiKey: string, input: Record<string, unknown>, mode: string) {
  const client = new Anthropic({ apiKey, maxRetries: 2, timeout: 45_000 });
  const model = Deno.env.get("AI_MODEL") || "claude-opus-5-5";
  const effortEnv = Deno.env.get("AI_EFFORT") || "low";
  const effort = (["low", "medium", "high"].includes(effortEnv) ? effortEnv : "low") as "low" | "medium" | "high";

  const response = await client.beta.messages.create({
    model,
    max_tokens: 16000,
    betas: ["server-side-fallback-2026-07-01"],
    // On a safety-classifier decline, the API re-runs the request on
    // Anthropic's recommended fallback model instead of returning a refusal.
    fallbacks: "default",
    output_config: { effort, format: { type: "json_schema", schema: RESULT_SCHEMA } },
    system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: JSON.stringify(input) }],
  });

  if (response.stop_reason === "refusal" || response.stop_reason === "max_tokens") {
    throw new Error(`model stopped: ${response.stop_reason}`);
  }
  const text = response.content
    .map((b) => (b.type === "text" ? b.text : ""))
    .join("");
  const parsed = JSON.parse(text) as Record<string, unknown>;
  return {
    result: sanitize(parsed, mode),
    engine: `claude:${response.model}`,
    inputTokens: response.usage.input_tokens,
    outputTokens: response.usage.output_tokens,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const started = Date.now();
  try {
    const userId = await getCallerId(req);
    if (!userId) return json({ error: "Please login again." }, 401);

    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    const mode = body.mode === "mechanic" ? "mechanic" : "customer";
    const language = typeof body.language === "string" && LANGUAGES[body.language] ? body.language : "en";
    const db = adminClient();

    const { data: cfg } = await db
      .from("app_config")
      .select("ai_enabled, ai_daily_limit_customer, ai_daily_limit_mechanic")
      .eq("id", 1)
      .maybeSingle();

    let category: Category = "two_wheeler";
    let vehicle: Record<string, unknown> = {};
    let issueTags: string[] = [];
    let description = "";
    let bookingId: string | null = null;

    if (mode === "customer") {
      const { data: customer } = await db.from("customers").select("id, is_blocked").eq("id", userId).maybeSingle();
      if (!customer || customer.is_blocked) return json({ error: "Please login with your mobile number." }, 403);

      const vehicleId = typeof body.vehicle_id === "string" && UUID_RE.test(body.vehicle_id) ? body.vehicle_id : null;
      if (vehicleId) {
        const { data: v } = await db
          .from("customer_vehicles")
          .select("category, body_type, brand, model, fuel_type")
          .eq("id", vehicleId)
          .eq("customer_id", userId)
          .eq("is_deleted", false)
          .maybeSingle();
        if (v) vehicle = v;
      }
      if (!vehicle.category) {
        const raw = (body.vehicle ?? {}) as Record<string, unknown>;
        vehicle = {
          category: CATEGORIES.includes(String(raw.category)) ? raw.category : "two_wheeler",
          body_type: clean(raw.body_type, 30),
          brand: clean(raw.brand, 40),
          model: clean(raw.model, 60),
          fuel_type: clean(raw.fuel_type, 20),
        };
      }
      category = vehicle.category as Category;
      issueTags = cleanList(body.issue_tags, 8, 40).filter((t) => (ISSUE_LABELS as readonly string[]).includes(t));
      description = clean(body.description, 1000);
      if (issueTags.length === 0 && description.length < 3) {
        return json({ error: "Tell us a little about the problem first." }, 400);
      }
    } else {
      const { data: mech } = await db.from("mechanics").select("id, is_verified").eq("user_id", userId).maybeSingle();
      if (!mech?.is_verified) return json({ error: "Only verified partners can use the repair guide." }, 403);
      const id = typeof body.booking_id === "string" && UUID_RE.test(body.booking_id) ? body.booking_id : null;
      if (!id) return json({ error: "Open the job first." }, 400);
      const { data: b } = await db
        .from("bookings")
        .select("id, vehicle_type, vehicle_label, vehicle_body_type, issue_tags, issue_note, status, mechanic_id")
        .eq("id", id)
        .maybeSingle();
      if (!b || b.mechanic_id !== mech.id || !["ACCEPTED", "ARRIVED", "IN_PROGRESS"].includes(b.status)) {
        return json({ error: "The repair guide is available for your active job only." }, 403);
      }
      bookingId = b.id;
      category = (CATEGORIES.includes(b.vehicle_type) ? b.vehicle_type : "two_wheeler") as Category;
      vehicle = {
        category,
        body_type: b.vehicle_body_type ?? "",
        name: String(b.vehicle_label ?? "").split(" • ")[0],
      };
      issueTags = (b.issue_tags ?? []) as string[];
      description = clean(b.issue_note, 1000);
    }

    // Limits: daily per user + a short burst limit.
    const limit = mode === "customer" ? (cfg?.ai_daily_limit_customer ?? 15) : (cfg?.ai_daily_limit_mechanic ?? 40);
    const since = new Date(Date.now() - 86_400_000).toISOString();
    const { count: dayCount } = await db.from("ai_requests").select("id", { count: "exact", head: true })
      .eq("user_id", userId).gte("created_at", since);
    if ((dayCount ?? 0) >= limit) {
      return json({ error: "You have used today's AI help limit. A mechanic can still help you right away." }, 429);
    }
    const { count: burst } = await db.from("ai_requests").select("id", { count: "exact", head: true })
      .eq("user_id", userId).gte("created_at", new Date(Date.now() - 60_000).toISOString());
    if ((burst ?? 0) >= 4) {
      return json({ error: "Please wait a few seconds before asking again." }, 429);
    }

    const vehicleName = String(vehicle.name ?? `${vehicle.brand ?? ""} ${vehicle.model ?? ""}`).trim() || "vehicle";
    const modelInput = {
      mode,
      language: LANGUAGES[language],
      allowed_issue_tags: ISSUE_LABELS,
      vehicle,
      selected_issue_tags: issueTags,
      customer_words: description,
      city: "Durgapur, West Bengal",
    };

    let result: AssistResult;
    let engine = "rules";
    let inputTokens: number | null = null;
    let outputTokens: number | null = null;
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (apiKey && cfg?.ai_enabled !== false) {
      try {
        const ai = await askClaude(apiKey, modelInput, mode);
        result = ai.result;
        engine = ai.engine;
        inputTokens = ai.inputTokens;
        outputTokens = ai.outputTokens;
        if (!result.summary || result.likely_causes.length === 0) throw new Error("empty answer");
      } catch (e) {
        if (e instanceof Anthropic.RateLimitError) console.warn("claude rate limited");
        else if (e instanceof Anthropic.APIError) console.error("claude api error", e.status, e.message);
        else console.error("claude call failed", String(e));
        result = diagnose({ category, vehicleName, issueTags, description, mode });
        engine = "rules";
      }
    } else {
      result = diagnose({ category, vehicleName, issueTags, description, mode });
    }

    const { data: row, error: insErr } = await db.from("ai_requests").insert({
      user_id: userId,
      mode,
      booking_id: bookingId,
      input: { vehicle, issue_tags: issueTags, description, language },
      output: result,
      engine,
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      latency_ms: Date.now() - started,
    }).select("id").single();
    if (insErr) throw insErr;

    return json({ id: row.id, engine: engine.startsWith("claude") ? "ai" : "expert", result });
  } catch (e) {
    console.error("ai-assistant failed", e);
    return json({ error: "AI help is not available right now. Please book a mechanic directly." }, 500);
  }
});
