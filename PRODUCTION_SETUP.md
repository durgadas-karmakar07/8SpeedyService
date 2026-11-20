# 8SpeedyService — Production Setup Guide

Yeh guide dono apps — **8SpeedyService** (customer, yeh repo) aur **8Speedy Partner**
(mechanic, repo `8SpeedyService.Partner`) — ko Play Store par live karne ke steps batati hai.
Order mein follow karein.

---

## Kya-kya bana hai

| Area | Status |
|---|---|
| **Database** | `supabase/migrations/` — 3 migrations: schema, RLS, RPCs, mechanic app, vehicles, account deletion (local Postgres par test kiye gaye) |
| **Security (RLS)** | Har user sirf apna data dekhta hai; saare writes server functions se; mechanic ko start OTP kabhi nahi milta |
| **Payment** | Server Razorpay order banata hai (price DB se), signature + Razorpay API se verify, webhook backup |
| **Free credits / referral** | Signup par 5 credits, double-tap safe, cancel par credit wapas; friend ki pehli job par referrer ko +1 |
| **My Vehicles** | Customer type → brand → model → number plate se gaadi save karta hai; price server par gaadi ke type se tay hota hai |
| **Account deletion** | Dono apps mein in-app "Delete my account" + web page (Google Play ki zaroorat) |
| **Logo & icons** | Dono apps ke launcher icons (adaptive + themed), native splash, Play Store icon 512 + feature graphic (`store/`) |
| **Design** | Poppins font, naya splash/login, vehicle illustrations (`assets/vehicles/`, original — koi brand logo/photo nahi) |
| **Legal** | `legal-site/` — Privacy Policy, Terms, Partner Terms, Delete-account page |
| **Mechanic Partner app** | Alag repo: login, self-registration + admin verify, Online/Offline, nearby requests, job flow, history, account deletion |
| **Call-style job alerts** (20 Nov) | Partner app: naya request aate hi phone-call jaisa full screen + original "8Speedy" ringtone (lock screen par bhi) |
| **Voice note** (20 Nov) | Customer apni awaaz mein problem bol sakta hai (60 sec); paas ke mechanics sun sakte hain — private bucket + RLS |
| **Test APK (CI)** (20 Nov) | Har push par GitHub Actions: analyze + test + obfuscated APK + security scan + emulator run → `test-build` release |

---

## Step 1 — Supabase database

1. https://supabase.com → project (region **Mumbai**) → **SQL Editor**.
2. In teeno files ka content **ek-ek karke** paste → **Run** (order zaroori):
   1. `supabase/migrations/20261117000001_init_8speedyservice.sql`
   2. `supabase/migrations/20261117000002_mechanic_partner_app.sql`
   3. `supabase/migrations/20261118000003_vehicles_and_account_deletion.sql`
      ✅ **18 Nov 2026 ko aapke live project par Claude ne Supabase connector se laga diya hai** — dobara chalane ki zaroorat nahi
      (chalaoge to bhi safe hai, file mein koi DROP/DELETE nahi hai).
   4. `supabase/migrations/20261120000004_voice_notes.sql` — voice notes (bucket, policies, RPCs)
   5. `supabase/migrations/20261120000005_security_hardening.sql` — security audit fixes (20 Nov)
      ⚠️ 4 aur 5 abhi live DB par **nahi** lage hain — Claude ko permission dein ya SQL Editor mein khud chalayein.
      Jab tak nahi lagte: Partner app purane RPC par chalta hai (voice note nahi dikhega) aur customer ka voice
      note upload "could not be sent" dikhayega — booking phir bhi ho jaayegi.
3. **Database → Extensions** → `pg_cron` enable, phir pehli file ka "AUTO-EXPIRE" wala `DO $$ … $$;` block dobara run.
4. **Project Settings → API** se `Project URL` aur `anon / publishable key` → `env/prod.json` (dono repos mein).

> File copy karne ka aasaan tareeka (PowerShell):
> `Get-Content D:\8SpeedyService\supabase\migrations\20261118000003_vehicles_and_account_deletion.sql -Raw | Set-Clipboard`

### Phone OTP (zaroori — yeh free nahi hai)
**Authentication → Sign In / Providers → Phone** enable karein aur SMS provider jodein
(Twilio / MessageBird / Vonage / Textlocal). India mein DLT registration bhi chahiye.
Testing / Play reviewer ke liye: **Test OTP** (jaise `919999999999=123456`).

### Auth security settings (production)
**Authentication → Rate Limits**:
- *SMS OTPs sent per hour*: shuru mein **30** (SMS fraud se paisa bachata hai; zaroorat par badhayein)
- *Token verifications*: default theek hai
**Authentication → Providers → Phone**: OTP expiry **300 sec**, OTP length **6**.
**Authentication → Sign In**: Email provider band kar dein (sirf phone use hota hai).

## Step 2 — Edge Functions (Razorpay + account deletion)

1. Razorpay dashboard → KYC → **Settings → API Keys** → Live keys. **Payment Capture → Automatic** ON.
2. Supabase CLI (Windows: `scoop install supabase` ya `npx supabase`):

```bash
cd D:\8SpeedyService
supabase login
supabase link --project-ref YOUR-PROJECT-REF

supabase secrets set RAZORPAY_KEY_ID=rzp_live_xxx RAZORPAY_KEY_SECRET=xxx RAZORPAY_WEBHOOK_SECRET=apna_random_secret

supabase functions deploy razorpay-create-order
supabase functions deploy razorpay-verify-payment
supabase functions deploy razorpay-webhook --no-verify-jwt
supabase functions deploy delete-account     # 20 Nov: voice notes bhi delete karta hai — dobara deploy karein
```

3. Razorpay → **Settings → Webhooks → Add**:
   URL `https://YOUR-PROJECT-REF.supabase.co/functions/v1/razorpay-webhook`,
   Secret = `RAZORPAY_WEBHOOK_SECRET`, Events: `payment.captured`, `order.paid`.

> ⚠️ `RAZORPAY_KEY_SECRET` kabhi app ya git mein mat daalein.

### Refunds
Jab paid booking bina mechanic ke cancel hoti hai, `bookings.refund_status = 'REQUESTED'` ho jaata hai.
Roz ek baar **Table Editor → bookings** filter `refund_status = REQUESTED` → Razorpay dashboard se
us `razorpay_payment_id` ka refund karein → row mein `refund_status = 'REFUNDED'` likh dein.

## Step 3 — Mechanics (Partner app)

- **Khud register**: Partner app mein login → form → row `is_verified = false`.
- **Aap add karein**: Table Editor → mechanics → `full_name`, `phone` (`+91…`), `vehicle_specialties`.
  Mechanic us number se login karega to account apne aap link ho jaayega.
- **Verify**: `is_verified = true` (documents check karne ke baad). Tabhi mechanic Online ja sakta hai.
- Partner app force-update: `app_config.min_partner_version`. Customer app: `app_config.min_android_version`.

## Step 4 — Legal website ✅ LIVE

GitHub Pages par live hai (is repo ki `gh-pages` branch se):

| Page | Link (Play Console mein yahi daalein) |
|---|---|
| Home | https://durgadas-karmakar07.github.io/8SpeedyService/ |
| Privacy Policy | https://durgadas-karmakar07.github.io/8SpeedyService/privacy.html |
| Terms (customer) | https://durgadas-karmakar07.github.io/8SpeedyService/terms.html |
| Partner Terms | https://durgadas-karmakar07.github.io/8SpeedyService/partner-terms.html |
| Delete account | https://durgadas-karmakar07.github.io/8SpeedyService/delete-account.html |

- Pages badalne ho to `legal-site/` (main branch) aur `gh-pages` branch dono mein file update karein.
- Apps ke andar Privacy Policy / Terms **app mein hi** khulte hain (internet hosting par depend nahi).
- "Grievance Officer" mein apna asli naam aur pata likhna behtar hai (IT Rules, India).
> Yeh pages ek template hain — launch se pehle kisi CA / lawyer se ek baar padhwa lena achha hai.

## Step 5 — App details & placeholders (dono apps)

Customer: `lib/core/constants/app_constants.dart` · Partner: `lib/core/constants.dart`
- `supportPhoneNumber`, `whatsappSupportUrl` → ✅ +91 96352 97320 set hai
- `legalBaseUrl` → ✅ `https://durgadas-karmakar07.github.io/8SpeedyService`
- Har release par `pubspec.yaml` ka `version:` aur `appVersion` saath badlein (`1.0.1+2` …).

## Step 6 — Build (aapke PC par)

```bash
flutter clean
flutter pub get
flutter analyze
flutter test
flutter run --dart-define-from-file=env/prod.json          # phone par test
```

Release keystore (sirf ek baar; file aur password safe rakhein — kho gaye to app update nahi kar paayenge):

```bash
keytool -genkey -v -keystore C:\Users\<you>\upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Dono repos mein `android/key.properties` (git mein nahi jaata):

```
storePassword=xxxx
keyPassword=xxxx
keyAlias=upload
storeFile=C:/Users/<you>/upload-keystore.jks
```

Play Store bundle (code obfuscated — reverse-engineering mushkil):

```bash
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols --dart-define-from-file=env/prod.json
```
Output: `build/app/outputs/bundle/release/app-release.aab`. `build/symbols` folder sambhal kar rakhein (crash samajhne ke liye).

## Step 6b — Test APK dosto ko bhejna (bina PC ke)

GitHub Actions har push par dono apps ka **test APK** banata hai (file: `.github/workflows/build-apk.yml`):

| App | Download link (phone par kholo → Install) |
|---|---|
| Customer | https://github.com/durgadas-karmakar07/8SpeedyService/releases/download/test-build/8SpeedyService-test.apk |
| Partner | https://github.com/durgadas-karmakar07/8SpeedyService.Partner/releases/download/test-build/8Speedy-Partner-test.apk |

- Pehli baar phone poochega "Install unknown apps" — browser/WhatsApp ko allow karein.
- Test APK ek CI test key se sign hota hai, isliye naya build purane ke upar install ho jaata hai.
  (Agar 7 din tak koi build na ho to key badal sakti hai — tab purana app uninstall karke naya daalein.)
- Play Store ke liye `.aab` hamesha **apne PC** par apni upload key se banayein (Step 6). CI wala APK Play Store par mat daalein.
- Har build ke logs, security report aur emulator screenshots: release `ci-logs-test-build`.
- Optional: repo **Settings → Secrets and variables → Actions** mein `SUPABASE_URL` aur `SUPABASE_ANON_KEY` daal dein;
  na ho to workflow project ki *publishable* key use karta hai (yeh public hi hoti hai — har APK ke andar hoti hai, data RLS se surakshit).

## Step 7 — Play Console

1. https://play.google.com/console → Developer account ($25, ek baar). Personal account ke liye
   naye developers ko **12 testers × 14 din closed testing** karna padta hai production se pehle —
   isliye jaldi shuru karein.
2. **Do apps** banayein: `8SpeedyService` aur `8Speedy Partner`.
3. Listing text, icon, feature graphic, Data safety aur App content ke jawab:
   - Customer: `store/PLAY_STORE_LISTING.md` (is repo mein)
   - Partner: `store/PLAY_STORE_LISTING.md` (Partner repo mein) — **Foreground service declaration** aur
     **Full-screen intent declaration** (call-style alerts; jawab "No, calling/alarm app nahi") zaroor bharein
   - Customer Data safety mein naya: **Audio → Voice or sound recordings** (optional voice note)
4. Testing → Closed testing → `.aab` upload → testers ke Gmail add karein.

## Step 8 — Launch se pehle test checklist

- [ ] Naye number se login → `customers` row + 5 credits
- [ ] Add vehicle: Scooty → Honda → Activa 6G → number → Home par card dikhe
- [ ] Partner: register → `is_verified = true` → Online → request mein "Honda Activa 6G" dikhe (number plate nahi)
- [ ] Accept → customer app mein live tracking; partner job screen par number plate dikhe
- [ ] Arrived → customer ka OTP → Complete → customer rating
- [ ] Partner "job chhodein" → customer app wapas radar par
- [ ] Customer accepted booking cancel kare → Partner mein "Job closed" popup
- [ ] Credits 0 → paid booking (Razorpay test keys) → `payment_status = PAID`
- [ ] Customer: Account & Privacy → naam save → mechanic ko naam dikhe
- [ ] Delete account (test number se) → login screen; DB mein phone `deleted-…`; usi number se naya signup chale
- [ ] Partner delete account → mechanics row "Deleted Partner"
- [ ] App icon, splash (orange / navy) aur Android 12+ splash sahi dikhe
- [ ] `min_android_version = 9.0.0` → force-update dialog; phir wapas `1.0.0`
- [ ] Partner Online → doosre phone se booking → Partner phone **ring kare** (app khula ho, background mein ho, aur screen lock ho — teeno)
- [ ] Ringing screen: Accept → job screen; Decline → request list mein rehti hai; 40 sec baad "missed"
- [ ] Android 14+: "Allow full-screen alerts" banner → setting on → lock screen par full screen dikhe
- [ ] Customer: mic → 10 sec bolo → play karke suno → booking → Partner mein request par ▶ voice note bajey
- [ ] Customer voice note ke saath delete account → Storage → voice-notes bucket mein uska folder khali

## Security audit — 20 Nov 2026 (10 "hack" attempts)

| # | Attack (public APK key ke saath) | Result |
|---|---|---|
| 1 | Bina login sab tables padhna (customers, bookings, mechanics) | ✅ Blocked — anon ko SELECT nahi |
| 2 | Login karke doosre users ka data padhna | ✅ Blocked — RLS: random user ko 5 mein se 0 bookings dikhi |
| 3 | Direct write: khud ko PAID / 999 free credits dena | ✅ Blocked — sirf apna naam edit ho sakta hai, baaki sab server RPC se |
| 4 | Mechanic ka customer ka Start OTP padhna | ✅ Blocked — kisi mechanic RPC/realtime mein OTP nahi |
| 5 | Fake payment (signature / amount / doosri booking ka payment) | ✅ Blocked — HMAC + Razorpay API + amount + order check |
| 6 | Doosre ka account delete / unverified mechanic se job lena | ✅ Blocked |
| 7 | **PostGIS `spatial_ref_sys` table ko public key se wipe karna (poora app band)** | ❌ **Possible tha** → fix: write-guard trigger (migration 005) |
| 8 | OTP guess: 4 galat try → job release → doosra mechanic same OTP par 5 aur try | ⚠️ Kamzori → fix: release par naya OTP |
| 9 | Mechanic ka fake / galat GPS location bhejna | ⚠️ Kamzori → fix: India ke bahar / adhure coordinates reject |
| 10 | APK kholkar secret keys dhoondhna | ✅ Koi secret nahi (CI har build scan karta hai); code obfuscated; not debuggable; backup off; http block; 16 KB aligned; targetSdk 36 |

Extra fixes: purana customer job ke 24 ghante baad tak mechanic ki live location dekh sakta tha → ab 2 ghante;
Partner app ka exported activity spoof (lock-screen) → one-time token; voice-note bucket private + 3 upload limit.

Abhi bhi bacha (Supabase ki taraf se, hamare control mein nahi): PostGIS ke `st_estimatedextent` functions public hain
(sirf approx. map extent batate hain — low risk). Supabase support se PostGIS ko `extensions` schema mein shift karwa sakte hain.

## Note — OpenStreetMap tiles
`tile.openstreetmap.org` launch / kam traffic ke liye theek hai, lekin heavy commercial use allow nahi.
Users badhne par MapTiler / Stadia Maps (free tier) ka URL `osmTileUrl` mein laga dein (dono apps).
