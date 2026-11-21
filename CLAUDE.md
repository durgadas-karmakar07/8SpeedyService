# 8SpeedyService — project memory for Claude Code

Read this first. It is the hand-over from the claude.ai sessions (17–21 Nov 2026):
what exists, how it is built, the rules, and what is still open.

## Talking to the owner
- Owner: Durgadas (college student, Durgapur). This is his startup — he wants both apps on the
  Play Store quickly so it can start earning.
- He writes **Hinglish (Hindi in Roman letters)**. Reply in simple Hinglish, short and clear.
- He has asked Claude to do the git work: commit and push to `main` in both repos ("tumi hi sab kardo").
- After a push he syncs his PC with `git fetch origin` + `git reset --hard origin/main`
  → **anything not committed on the PC is lost by that command.** Always commit + push your work.

## What the product is
On-demand roadside mechanic service for Durgapur (West Bengal). Customer books → nearby verified
mechanic accepts → live tracking → start OTP → job done → rating. 5 free bookings on signup,
after that a small platform fee via Razorpay.

| | Customer app (this repo) | Partner / mechanic app |
|---|---|---|
| Folder on PC | `D:\8SpeedyService` | `D:\8SpeedyService.Partner` |
| GitHub | `durgadas-karmakar07/8SpeedyService` (public) | `durgadas-karmakar07/8SpeedyService.Partner` (public) |
| Dart package | `eight_speedy_service` | `speedy_partner` |
| applicationId | `com.speedyservice.customer` | `com.speedyservice.partner` |
| Kotlin package | `com.speedyservice.eight_speedy_service` | `com.speedyservice.partner` |
| Constants | `lib/core/constants/app_constants.dart` | `lib/core/constants.dart` |

The backend (Supabase migrations + Edge Functions) and the legal website live in **this** repo.

## Tech stack & conventions
- Flutter ≥ 3.47 / Dart ^3.14, AGP 9.3, Kotlin 2.4, Gradle 9.5, JDK 17+ (CI uses 21).
- **Import Material with `package:material_ui/material_ui.dart`**, not `package:flutter/material.dart`
  (Material lives in the `material_ui` package in this Flutter version). Follow existing files.
- Font Poppins, UI text in **English**. Colours: primary orange `#FF5722`, navy `#1E293B`.
- Backend config: `env/prod.json` (gitignored) → `{"SUPABASE_URL": ..., "SUPABASE_ANON_KEY": ...}`;
  always run/build with `--dart-define-from-file=env/prod.json`.
- Maps: flutter_map + OpenStreetMap tiles (`osmTileUrl`) — fine for launch, switch to MapTiler/Stadia
  when traffic grows (OSM forbids heavy commercial use).
- Vehicle pictures are our own illustrations in `assets/vehicles/` — never brand logos or photos.

Commands (both repos):
```bash
flutter pub get
flutter analyze
flutter test
flutter test test_preview --update-goldens   # renders screens to PNG (test_preview/goldens/, gitignored)
flutter run --dart-define-from-file=env/prod.json
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols --dart-define-from-file=env/prod.json
```

## Backend — Supabase
- Project **8SpeedyService**, ref `mzxcbhiemdkhalslxwid`, region Mumbai (ap-south-1), Postgres 17,
  PostGIS 3.3 (installed in `public`, owned by `supabase_admin`).
- Migrations in `supabase/migrations/` — **all 11 are live** (000001–000003 on 18 Nov, 000004–000011 on 21 Nov):
  1. `..000001_init` — schema, RLS, booking/payment RPCs, pg_cron `expire-stale-bookings` (every 5 min)
  2. `..000002_mechanic_partner_app` — partner RPCs (register, link account, accept, release, start, complete…)
  3. `..000003_vehicles_and_account_deletion` — My Vehicles, `*_v2` RPCs, `delete_account_data`
  4. `..000004_voice_notes` — `voice-notes` private bucket, storage policies, `customer_attach_voice_note`,
     `mechanic_get_open_requests_v3`, voice keys in `mechanic_get_active_job`
  5. `..000005_security_hardening` — see "Security audit" below
  (Also live: `ALTER FUNCTION private.block_api_writes() SET search_path = ''`, already in file 000005.)
  6. `..000006_security_scale_features` — audit #2 fixes + 1.1.0 backend: text cleaning (`private.clean_text`,
     `clean_person_name`, `clean_message`), `private.hit_rate_limit` (UNLOGGED `private.rate_limits`),
     `private.security_events` / `private.booking_events` logs, `issue_catalog`, `create_booking_v2` (cooldown after
     3 pre-accept cancels / 2 h, 15 bookings/day), `cancel_booking_v2`, `customer_refresh_start_otp`,
     `submit_booking_review_v2`, `customer_get_mechanic_card`, `mechanic_get_active_job_v2` (no phone),
     `mechanic_get_customer_contact` (logged, 30/day), `mechanic_complete_job_v2` (repair bill), `mechanic_get_stats_v2`,
     `mechanic_get_open_requests_v4`, blurred `get_nearby_mechanics`, chat (`booking_messages`, `send_booking_message`,
     `get_booking_messages`), `customer_places`, `ai_requests`, `payment_orders` + refund columns, anonymising
     `delete_account_data`, private Realtime topics, `private.maintenance()` cron (every 10 min).
  7. `..000007_api_guard` — PostgREST `db_pre_request = api_guard.check_request`: anon/authenticated may only reach
     functions and tables **owned by `postgres`** (everything our migrations create); PostGIS helpers → 404 (`PT404`).
     Off switch: `ALTER ROLE authenticator RESET pgrst.db_pre_request; NOTIFY pgrst, 'reload config';`
  8. `..000008_maintenance_cron` — pg_net + pg_cron call the `maintenance` Edge Function every 10 min with a one-time
     nonce (`private.cron_nonces`, `maintenance_consume_nonce`, service_role only); daily `net._http_response` trim.
  9. `..000009_partner_history_v3` — `mechanic_get_job_history_v3` (repair bill, review tags).
  10. `..000010_ai_feedback_retention` — `ai_submit_feedback` (Helpful / Report, Google Play AI policy), retention:
     chat + AI requests 180 days (batched in `private.maintenance()`), partial indexes for the cron.
  11. `..000011_fk_indexes` — covering indexes for `booking_messages.mechanic_id` and `ai_requests.booking_id`.
  Leftover: `private.sql_staging` (empty) was a temporary loader used to apply 000006 via pg_net — safe to drop.
- Tables: `customers`, `mechanics`, `bookings`, `customer_vehicles`, `app_config` (single row id=1:
  fees per vehicle type, free credits, `min_android_version`, `min_partner_version`, `ai_enabled`,
  `ai_daily_limit_customer/mechanic`, `max_releases_per_day`, `release_suspension_hours`, `auto_refunds_enabled`,
  `service_message`), `issue_catalog` (public read), `customer_places` + `ai_requests` (own rows read-only),
  `booking_messages` + `payment_orders` (no client grants — only via RPCs / Edge Functions).
  Private: `rate_limits`, `security_events`, `booking_events`, `cron_nonces`.
- Booking status: `SEARCHING → ACCEPTED → ARRIVED → IN_PROGRESS → COMPLETED`, or `CANCELLED`
  (customer, mechanic release goes back to SEARCHING, cron expiry, account deletion).
- Edge Functions: `razorpay-create-order` (reconciles a paid order instead of re-ordering), `razorpay-verify-payment`
  (verify_jwt, capture if `authorized`), `razorpay-webhook` (no JWT, HMAC signature; payment + refund events),
  `delete-account` (v2 — also deletes the user's voice notes), `ai-assistant` (verify_jwt; Claude API via
  `npm:@anthropic-ai/sdk`, model `AI_MODEL` default `claude-opus-5-5`, effort `AI_EFFORT` default `low`, JSON-schema
  output, server-side fallback; expert-system fallback in `rules.ts` when `ANTHROPIC_API_KEY` is missing or the call
  fails), `maintenance` (no JWT, nonce auth; auto refunds, duplicate-payment refunds, voice-note cleanup).
  Shared code in `supabase/functions/_shared/`. Secrets live only in Supabase secrets.
  **Deployed on 21 Nov as stubs** that import this public repo's code at commit `d17f8f4` from
  raw.githubusercontent.com (the MCP connector could not upload the folder). Redeploy with the CLI
  (`supabase functions deploy <name>`) after changing a function — and before ever making the repo private.
- Realtime: app 1.1.0 uses **private Broadcast topics** — `booking:{id}` (event `booking`, status changes) and
  `booking:{id}:m:{mechanicId}` (`location`, `chat`), sent by DB triggers via `realtime.send`, authorised by
  `private.can_listen_topic` (RLS on `realtime.messages`). Payloads never contain OTP or phone. The table
  publication (`bookings`, `mechanics`) stays for 1.0.x installs.

### Security rules — do not break these
1. RLS on every table. Clients may only **SELECT their own rows**; customers may UPDATE only `full_name`.
2. **Every write goes through a `SECURITY DEFINER` RPC** that checks `auth.uid()` and sets
   `search_path`. Prices / fees / credits are decided on the server, never sent by the app.
3. `bookings.start_otp` is **never** returned to mechanics (no RPC, no realtime).
4. New table → `ENABLE ROW LEVEL SECURITY` + `REVOKE ALL ... FROM anon, authenticated` (Supabase default
   privileges grant ALL) + only the grants you need. New RPC → `REVOKE EXECUTE ... FROM PUBLIC, anon`,
   `GRANT EXECUTE ... TO authenticated`.
5. Functions used inside RLS policies go in schema `private` (not exposed by the REST API).
6. **Never drop an RPC that installed apps still call.** Make `_v2/_v3` and keep the old one
   (e.g. `mechanic_get_open_requests_v2` stays for older Partner installs; the app falls back to v2
   when v3 returns PGRST202).
7. Only the **publishable/anon** key goes in apps or CI (public by design). Never put
   `sb_secret_…`, `service_role`, Razorpay key secret or webhook secret in an app, in git or in CI.
8. Migrations must be re-runnable (`IF NOT EXISTS`, `CREATE OR REPLACE`, no DROP of data).
   Add a new numbered file in `supabase/migrations/` for every DB change and apply it to the live DB.
9. Objects reachable through the REST API must be **owned by `postgres`** (API guard, migration 000007).
   Apply migrations through the SQL editor / Supabase MCP (they run as postgres) — otherwise new RPCs 404.
10. Free text that another user sees goes through `private.clean_message` / `clean_person_name` (links, UPI IDs,
   invisible characters blocked). Endpoints that can be farmed use `private.hit_rate_limit`.
11. From 1.1.0 the customer's phone reaches a mechanic only through `mechanic_get_customer_contact` (logged +
   limited); the v1 `mechanic_get_active_job` still returns it for old installs until the force update.
   AI requests never contain phone numbers or exact coordinates; the Anthropic key lives only in Supabase secrets.

## Features built (state on 21 Nov 2026)
- Phone OTP login, onboarding, 5 free credits, referral codes, force-update via `app_config`.
- My Vehicles: type → brand → model → number plate; fee by vehicle category.
- Booking → radar search → live tracking → OTP → complete → rating. Cancel with credit refund.
- Razorpay payments (server order, signature + API verification, webhook backup, `payment_orders` history,
  automatic refunds by the `maintenance` function).
- In-app account deletion in both apps + web page (Google Play requirement).
- Logo, launcher icons, native splash, Poppins, English UI, in-app Privacy/Terms.
- **Voice note (customer, 20 Nov):** `lib/widgets/voice_note_recorder.dart` on the issue summary screen,
  max 60 s AAC/M4A. Uploaded after the booking is created to
  `voice-notes/<uid>/<bookingId>_<unixMs>.m4a`, then linked with `customer_attach_voice_note`.
  Upload failure never blocks the booking. Recording/playback is **native Kotlin** (MethodChannel
  `com.speedyservice.customer/voice`: `MainActivity.kt`, `VoiceRecorder.kt`, `VoicePlayer.kt`),
  Dart side `lib/services/voice_service.dart`. Mic is released when the app goes to background.
  Who can listen is decided by `private.can_read_voice_note` (customer; verified online mechanics who can
  see the request within 15 km; the assigned mechanic while the job is active).
- **Call-style job alerts (Partner, 20 Nov)** — see the Partner repo `CLAUDE.md`.
- **Version 1.1.0 (21 Nov) — customer:** `lib/screens/ai/ai_assist_screen.dart` (8Speedy Assist: EN / HI / BN,
  causes, urgency, cost, do-now / avoid, "Use these issues & book" links the answer to the booking),
  `lib/widgets/ai_feedback.dart` (Helpful / Report — same file in both apps), `lib/screens/chat/chat_screen.dart`,
  `lib/services/booking_live.dart` (private Realtime + polling fallback), live tracking 2.0 (ETA, mechanic card,
  SOS sheet `lib/widgets/sos_sheet.dart`, new OTP), saved places on the home map, repair bill + review tags on the
  completed screen and in My bookings, premium widgets in `lib/widgets/premium.dart`. Services:
  `assist_service.dart` (AI, chat, places), `booking_service.dart` (v2 RPCs with fallbacks to v1).
- **Version 1.1.0 — partner:** earnings dashboard, AI repair guide, chat, repair bill on completion, phone via the
  contact RPC, suspension banner, adaptive polling — see the Partner repo `CLAUDE.md`.
- **New loaders (both apps, identical file `lib/widgets/speedy_loader.dart`, only default asset differs):**
  `RoadLoader` = "turbo gauge" speedometer (name kept for compatibility), `WheelLoader` = gear + comet,
  `DotsLoader` = speed dashes for buttons.
- Legal site: `legal-site/` on `main` **and** the `gh-pages` branch (GitHub Pages serves gh-pages) —
  update both. Live at https://durgadas-karmakar07.github.io/8SpeedyService/ (privacy, terms,
  partner-terms, delete-account).

## CI — test APKs in the cloud (`.github/workflows/build-apk.yml`, same in both repos)
On every push to `main` or `claude/**`: pub get → analyze → test → preview PNGs → obfuscated release APK →
`.github/scripts/apk_checks.sh` (debuggable/backup/cleartext flags, 16 KB alignment, `secret_scan.py`,
obfuscation) → Android 14 emulator smoke run (`smoke.sh`, screenshots).
- `main` → GitHub release **`test-build`** (stable link for testers):
  - https://github.com/durgadas-karmakar07/8SpeedyService/releases/download/test-build/8SpeedyService-test.apk
  - https://github.com/durgadas-karmakar07/8SpeedyService.Partner/releases/download/test-build/8Speedy-Partner-test.apk
- `claude/**` branches → release `preview-build`. Logs, checks, previews, screenshots → `ci-logs-<release>`.
- Test APKs are signed with a CI test key stored in the Actions cache (`speedy-test-keystore-v1`);
  it expires after 7 days without builds → testers must then uninstall/reinstall once.
  **Play Store `.aab` is always built on the PC with the private upload key** (`android/key.properties`).
- Without repo secrets `SUPABASE_URL` / `SUPABASE_ANON_KEY` the workflow uses the publishable key.
- `paths-ignore: **.md` — docs-only pushes do not build.

## Security audit #2 — 21 Nov 2026 (14 attack families, all fixes live)
Full table: `SECURITY_AUDIT.md`. Fixed: PostGIS RPCs reachable as anon (API guard), phishing / RTL names,
"ring bombing" (book → cancel loop), fake issue tags + UPI notes, lost payments / no refunds, customer phone
harvesting by mechanics, trilateration of mechanics' exact GPS (now 330 m grid + per-mechanic offset + rounded
distances + random ids), location scraping (rate limits), e-mail accounts (no data without a phone profile).
Pen-test scripts are not in git (they used temporary accounts on the live project, deleted afterwards).

## Security audit — 20/21 Nov 2026 (all fixes live)
10 attacks with only the public APK key. Blocked: anonymous reads, cross-user reads (RLS verified by
impersonation: random user sees 0 rows), direct writes (credits / PAID), OTP leak to mechanics, fake
payments, deleting other accounts, unverified mechanics, secrets in APK.
Fixed in migration 000005:
- **HIGH:** `public.spatial_ref_sys` was writable/deletable by `anon` (grants by supabase_admin, no RLS)
  → whole app could be taken down. Now blocked by triggers `zz_block_api_writes` /
  `zz_block_api_truncate` (verified: anon DELETE is rejected, 8500 rows intact).
- New `start_otp` whenever a mechanic releases a job (stopped OTP guessing across mechanics).
- `mechanic_set_status` / `get_nearby_mechanics` reject coordinates outside India or half-filled.
- Customer sees the mechanic row (live location) only during the job + 2 h after completion (was 24 h).
- `current_mechanic_id()` no longer callable via the API.
Partner app: job-alert intents carry a one-time token (exported activity can't be spoofed).

## Open problems / next tasks (priority order)
1. **Real-phone test** of 1.1.0 (AI assist, chat, live tracking, SOS, bills, earnings) + call alerts + voice notes
   (emulator cannot do OTP login). Checklist: `PRODUCTION_SETUP.md` → Step 8.
2. **Owner dashboard actions** (not possible from code): `ANTHROPIC_API_KEY` in Edge Function secrets (until then the
   AI answers come from the expert system, labelled "Expert guide"); Auth → Email provider off; Razorpay webhook
   events `refund.processed` + `refund.failed`; Realtime "Allow public access" off once every install is 1.1.0+.
3. **Push notifications (FCM) not built yet.** Partner alerts only work while the Partner app is Online
   and its process is alive (foreground service); if the app is swiped away there is no alert. Customer
   gets no push for booking updates. Needs a Firebase project + `google-services.json` from the owner,
   then DB webhook → Edge Function → FCM.
4. **Play Store launch:** Play Console account ($25), upload keystore + `key.properties`, `.aab` build,
   closed testing 12 testers × 14 days, Data safety (rows for chat, AI questions, repair bill are ready in
   `store/PLAY_STORE_LISTING.md`; check Razorpay SDK's own data-safety guidance), Partner: Foreground service +
   **Full-screen intent** declarations, App access instructions with a Supabase test phone number + fixed OTP.
   AI-generated content policy: covered by the in-app Report button (`ai_feedback.dart`).
5. **Backend before real users:** SMS provider for Supabase phone auth (+ DLT in India), auth rate limits
   (SMS 30/h to start), CAPTCHA (needs `captchaToken` support in both login screens first), Razorpay live keys +
   webhook, have the legal pages reviewed, Grievance Officer name.
6. **Force-update to 1.1.0** after it is on the Play Store: `app_config.min_android_version = '1.1.0'`,
   `min_partner_version = '1.1.0'`. Old installs still use `mechanic_get_active_job` v1, which includes the customer
   phone (harvesting is still capped by the 3-releases → 12 h suspension). Then remove old RPC overloads
   (`create_booking_secure` 6/7-arg, `cancel_booking`, `submit_booking_review`, `mechanic_get_open_requests` v1–v3,
   `mechanic_get_active_job`, `mechanic_complete_job`, `mechanic_get_stats`, `mechanic_get_job_history` v1/v2),
   drop `mechanics` from the realtime publication and turn Realtime public access off.
7. **Phone-number masking** (Exotel / Knowlarity virtual numbers) — the mechanic still sees the customer's number
   when calling. Recommended before a city-wide launch.
8. Supabase limits we can't fix ourselves: PostGIS and pg_net in `public` (advisor "extension in public"),
   `spatial_ref_sys` RLS advisor error (mitigated by triggers), `st_estimatedextent` (blocked by the API guard).
   Real fix = Supabase support / moving PostGIS to `extensions` (big migration). The advisor also lists
   our SECURITY DEFINER RPCs as "executable by authenticated" — that is by design.
9. No crash reporting yet (Firebase Crashlytics or Sentry) — add together with FCM.
10. CI: Partner emulator smoke run is flaky ("EMULATOR LOST" = runner problem, not the app);
   build warns about unobfuscated DWARF in the ELF — investigate; universal APK is ~53 MB
   (consider `--split-per-abi` for testers).
11. Refunds are automatic; rows with `refund_status = 'FAILED'` need a manual refund in Razorpay → set `REFUNDED`.
   Review reported AI answers weekly (query in `PRODUCTION_SETUP.md`).

Full step-by-step launch guide: `PRODUCTION_SETUP.md`.
