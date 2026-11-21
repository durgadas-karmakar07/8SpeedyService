# 8SpeedyService — Security audit #2 (21 Nov 2026)

Self pen-test of both apps and the Supabase backend with **only what a real attacker has**:
the public APK key (`sb_publishable_…`) and ordinary accounts. Five temporary test accounts
(+91 55500000 01–05, not real numbers) were used on the live project and deleted afterwards.
All findings are fixed and **live** (migrations `000006`–`000009`, Edge Functions redeployed).

Previous audit (20 Nov, 10 attacks): see `PRODUCTION_SETUP.md` → *Security audit — 20 Nov 2026*.

## Results — 14 attack families

| # | Attack | Before | After |
|---|---|---|---|
| 1 | Anonymous reads/writes of every table + private Storage bucket | ✅ Blocked | ✅ Blocked |
| 2 | PostGIS helper RPCs as anon (`postgis_full_version`, `addauth`, `populate_geometry_columns`, `_postgis_index_extent`) + `geometry_columns` | ❌ Callable (version leak, catalog scans) | ✅ 404 — API guard (`000007`): only functions/tables created by our migrations are reachable |
| 3 | Logged-in user reads other users' bookings / profile / vehicles / mechanic rows (IDOR, embedding, count leaks) | ✅ Blocked (RLS) | ✅ Blocked |
| 4 | Direct writes: free credits, `PAID`, phone, referral code, `is_verified`, fees, delete booking | ✅ Blocked | ✅ Blocked |
| 4b | Stored content shown to mechanics: phishing text, RTL-override, zero-width chars, HTML in `full_name` | ❌ Accepted | ✅ Cleaned / rejected by trigger (`private.clean_person_name`) |
| 5a | 6 parallel bookings at once (double-spend of a free credit) | ✅ 1 booking, 1 credit | ✅ |
| 5b | "Ring bombing": book → cancel → book (credit refunded each time) rings every nearby mechanic for free | ❌ 6 rings/15 min/account, 0 cost | ✅ 3 pre-accept cancels in 2 h → 30 min cooldown, max 15 bookings/day (verified live) |
| 5c | Arbitrary issue tags / note ("CALL 9xxxx FOR PAYMENT", "pay advance to x@ybl") | ❌ Shown to mechanics | ✅ Tags must exist in `issue_catalog`; links and UPI IDs rejected in notes and chat |
| 6 | Payment fraud: forged signature, forged webhook, other's booking, client-chosen amount, `mark_booking_paid` direct | ✅ Blocked | ✅ Blocked |
| 6b | Code review: a paid order replaced by a new order → webhook ignores the first payment (double charge); payment landing after a cancel not refunded; `authorized` not captured | ❌ Real money bug | ✅ `payment_orders` keeps every order, reconcile instead of re-order, capture, auto refunds (`maintenance`) |
| 7 | Customer / unverified account calling `mechanic_*` RPCs, self-registration to get jobs | ✅ Blocked | ✅ Blocked |
| 8 | Start-OTP leak (REST, realtime, RPC payloads) + brute force | ✅ No leak, 5 tries | ✅ Tries are cumulative across releases; customer can issue a new OTP |
| 9 | Mechanic harvests customer phone numbers: accept → read phone → release, repeat | ❌ Unlimited | ✅ v2 job payload has no phone; phone via logged, rate-limited RPC; 3 releases/24 h → 12 h pause |
| 10 | Stalking mechanics: trilaterate exact GPS from `distance_meters` of `get_nearby_mechanics` (+ stable ids) | ❌ Recovered position to ≈1 m | ✅ 330 m grid + per-mechanic offset (changes every 15 min), distance from blurred point rounded to 100 m, random ids — closest leak now ≥150 m |
| 11 | Storage: upload into other folders, traversal, wrong MIME, 2 MB, >3 uploads, read/sign/delete others' notes | ✅ Blocked | ✅ + tiny/fake files rejected when linking; orphan uploads auto-deleted after 2 h |
| 12 | Realtime eavesdropping on other users' rows / private topics | ✅ Blocked | ✅ New private broadcast topics verified (attacker `Unauthorized`, payloads without OTP/phone) |
| 12b | Public broadcast/presence channels usable with the APK key (free relay) | ❌ Open | ⚠️ Owner action: Realtime → Settings → disable public access (after all users run app 1.1.0) |
| 13 | Request floods: location scraping, referral oracle, anonymous config reads | ❌ No limits | ✅ Per-user limits in sensitive RPCs (`private.hit_rate_limit`, 40 nearby calls / 10 min, chat 20/min, contact 30/day, AI 15/day) |
| 14 | Auth: forged JWT (role / sub / exp), `alg=none`, delete someone else's account, phone takeover | ✅ Blocked | ✅ Blocked |
| 14b | E-mail sign-up is enabled although the apps use phone OTP (cheap accounts) | ❌ Open | ✅ Bare e-mail accounts get no data (RPCs require a phone-verified profile) · ⚠️ Owner action: turn the Email provider off |
| 14c | APK reverse engineering (secrets, debuggable, backup, cleartext, exported components) | ✅ Clean | ✅ Clean (CI checks every build) |

## What changed (where)

- `supabase/migrations/20261121000006_security_scale_features.sql` — all DB fixes above, scale indexes,
  private Realtime topics, chat, saved places, AI storage, refund-safe payments, anonymised deletion.
- `supabase/migrations/20261121000007_api_guard.sql` — PostgREST `db_pre_request` guard.
  Emergency off switch: `ALTER ROLE authenticator RESET pgrst.db_pre_request; NOTIFY pgrst, 'reload config';`
- `supabase/migrations/20261121000008_maintenance_cron.sql` — pg_cron → `maintenance` Edge Function
  (auto refunds, voice-note cleanup) authenticated by a DB-issued one-time nonce.
- `supabase/functions/*` — lost-payment fix, capture, refund webhooks, `ai-assistant`, `maintenance`.
- Apps 1.1.0 — use the v2 RPCs, private Realtime topics, no phone in the Partner job payload.

## Open (outside our control or needs the owner)

1. Supabase dashboard: **Auth → Providers → Email: off**; **Auth → Attack protection: CAPTCHA** (protects the
   project-wide SMS quota from OTP floods); **Realtime → Settings → "Allow public access": off** once every
   installed app is 1.1.0+.
2. PostGIS lives in `public` (Supabase default) → `spatial_ref_sys` advisor error and `st_estimatedextent`
   warning stay; mitigated by write-guard triggers (000005) and the API guard (000007). Real fix: Supabase support.
3. The advisor lists our `SECURITY DEFINER` RPCs as "executable by authenticated" — that is the design
   (every write goes through them and checks `auth.uid()`).
4. Customer phone numbers still reach the mechanic when they tap "Call" (logged + limited). Full number masking
   needs a telephony provider (e.g. Exotel) — recommended before city-wide launch.
