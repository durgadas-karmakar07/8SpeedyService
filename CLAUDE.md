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
- Migrations in `supabase/migrations/` — **all 5 are live** (000001–000003 on 18 Nov, 000004–000005 on 21 Nov):
  1. `..000001_init` — schema, RLS, booking/payment RPCs, pg_cron `expire-stale-bookings` (every 5 min)
  2. `..000002_mechanic_partner_app` — partner RPCs (register, link account, accept, release, start, complete…)
  3. `..000003_vehicles_and_account_deletion` — My Vehicles, `*_v2` RPCs, `delete_account_data`
  4. `..000004_voice_notes` — `voice-notes` private bucket, storage policies, `customer_attach_voice_note`,
     `mechanic_get_open_requests_v3`, voice keys in `mechanic_get_active_job`
  5. `..000005_security_hardening` — see "Security audit" below
  (Also live: `ALTER FUNCTION private.block_api_writes() SET search_path = ''`, already in file 000005.)
- Tables: `customers`, `mechanics`, `bookings`, `customer_vehicles`, `app_config` (single row id=1:
  fees per vehicle type, free credits, `min_android_version`, `min_partner_version`).
- Booking status: `SEARCHING → ACCEPTED → ARRIVED → IN_PROGRESS → COMPLETED`, or `CANCELLED`
  (customer, mechanic release goes back to SEARCHING, cron expiry, account deletion).
- Edge Functions: `razorpay-create-order`, `razorpay-verify-payment` (verify_jwt), `razorpay-webhook`
  (no JWT, HMAC signature), `delete-account` (v2 — also deletes the user's voice notes).
  Shared code in `supabase/functions/_shared/`. Secrets live only in Supabase secrets.
- Realtime publication: `bookings`, `mechanics` (RLS applies to subscribers).

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

## Features built (state on 21 Nov 2026)
- Phone OTP login, onboarding, 5 free credits, referral codes, force-update via `app_config`.
- My Vehicles: type → brand → model → number plate; fee by vehicle category.
- Booking → radar search → live tracking → OTP → complete → rating. Cancel with credit refund.
- Razorpay payments (server order, signature + API verification, webhook backup, manual refunds).
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
1. **Real-phone test** of call alerts + voice notes + new loader (emulator cannot do OTP login).
   Checklist: `PRODUCTION_SETUP.md` → Step 8. Owner earlier saw the *old* loading screen on his phone —
   confirm after reinstalling the new APK (`flutter clean` if building locally).
2. **Push notifications (FCM) not built yet.** Partner alerts only work while the Partner app is Online
   and its process is alive (foreground service); if the app is swiped away there is no alert. Customer
   gets no push for booking updates. Needs a Firebase project + `google-services.json` from the owner,
   then DB webhook → Edge Function → FCM.
3. **Play Store launch:** Play Console account ($25), upload keystore + `key.properties`, `.aab` build,
   closed testing 12 testers × 14 days, Data safety (customer: Audio → voice recordings; check Razorpay
   SDK's own data-safety guidance), Partner: Foreground service + **Full-screen intent** declarations,
   App access instructions with a Supabase test phone number + fixed OTP. Listing text:
   `store/PLAY_STORE_LISTING.md` in each repo.
4. **Backend before real users:** SMS provider for Supabase phone auth (+ DLT in India), auth rate limits
   (SMS 30/h to start), Razorpay live keys + webhook, have the legal pages reviewed, Grievance Officer name.
5. Supabase limits we can't fix ourselves: PostGIS in `public` → `st_estimatedextent` callable by anon
   (low risk) and the "RLS disabled on spatial_ref_sys" advisor error (mitigated by the triggers).
   Real fix = Supabase support / moving PostGIS to `extensions` (big migration). The advisor also lists
   our SECURITY DEFINER RPCs as "executable by authenticated" — that is by design.
6. Old RPC overloads (`create_booking_secure` 6-arg, `mechanic_get_open_requests` v1/v2,
   `mechanic_get_job_history` v1) — remove only after every installed app is updated.
7. CI: Partner emulator smoke run is flaky ("EMULATOR LOST" = runner problem, not the app);
   build warns about unobfuscated DWARF in the ELF — investigate; universal APK is ~53 MB
   (consider `--split-per-abi` for testers).
8. Refunds are manual (bookings with `refund_status = 'REQUESTED'` → refund in Razorpay → set `REFUNDED`).

Full step-by-step launch guide: `PRODUCTION_SETUP.md`.
