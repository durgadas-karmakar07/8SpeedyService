# 8SpeedyService — Production Setup Guide

Yeh guide step-by-step batati hai ki app ko Play Store par live kaise karna hai.
Order mein follow karein.

---

## Kya-kya fix / add hua hai

| Area | Pehle | Ab |
|---|---|---|
| **Database** | Koi SQL file nahi thi — backend bana hi nahi tha | `supabase/migrations/…sql` — poora schema, triggers, RPCs (local Postgres par test kiya gaya) |
| **Security (RLS)** | Koi policy nahi — koi bhi user kisi ki bhi booking/phone dekh ya badal sakta tha | Har user sirf apna data dekh sakta hai; saare writes server functions se hote hain |
| **Payment** | App khud `payment_status = PAID` set karta tha → koi bhi bina pay kiye booking kar sakta tha | Server Razorpay order banata hai (price DB se), signature + Razorpay API se verify karta hai, webhook backup |
| **Free credits** | — | Signup par auto 5 credits, double-tap se double credit nahi katega, searching mein cancel karne par credit wapas |
| **Mechanic pins** | RPC ke `mechanic_id/lat/lng` model mein read nahi hote the → pins galat jagah | Fix |
| **Unpaid booking** | Payment adhoora chhodne par app restart pe radar screen khul jaati thi | Sirf FREE/PAID bookings active maani jaati hain |
| **Mechanic privacy** | Mechanic ka phone sabko dikh sakta tha | Sirf assigned customer ko; radar par sirf first name + ~100m blurred location |
| **Start OTP** | — | Mechanic ko OTP kabhi server se nahi milta; 5 galat try ke baad lock |
| **Referral** | Code dikhta tha par apply karne ka koi tarika nahi tha | Refer & Earn mein "Friend ka code" box; friend ki pehli job complete hone par referrer ko +1 free booking |
| **Force update** | Missing | Splash par `min_android_version` check |
| **Stale bookings** | — | 30 min mein mechanic na mile to auto-cancel + credit refund (pg_cron) |
| **Android** | Package `com.speedyservice.eight_speedy_service`, debug signing | `com.speedyservice.customer`, release signing, R8 + Razorpay ProGuard rules, UPI apps query |
| **Mechanic app backend** | — | `mechanic_*` RPCs ready (accept, arrived, OTP se start, complete, location) |
| **Mechanic Partner app** | — | `mechanic_app/` — login, self-registration + admin verify, Online/Offline, nearby requests, job flow (navigate → arrived → OTP → complete), job release, history & rating |

---

## Step 1 — Supabase project (free)

1. https://supabase.com → **New project** → region **Mumbai (ap-south-1)**.
2. **SQL Editor** → `supabase/migrations/20261117000001_init_8speedyservice.sql` ka poora content paste → **Run**.
3. **Database → Extensions** → `pg_cron` enable karein, phir SQL file ka "AUTO-EXPIRE" wala `DO $$ … $$;` block dobara run karein.
4. **Project Settings → API** se copy karein: `Project URL` aur `anon / publishable key`.

### Phone OTP (zaroori — yeh free nahi hai)
**Authentication → Sign In / Providers → Phone** enable karein aur ek SMS provider jodein
(Twilio / MessageBird / Vonage / Textlocal). India mein DLT registration bhi chahiye.
> Testing ke liye: Phone provider mein **Test OTP** (jaise `919999999999=123456`) daal sakte hain — bina SMS kharch ke.

## Step 2 — Razorpay

1. Razorpay dashboard → KYC complete → **Settings → API Keys** → Live keys generate.
2. **Settings → Payment Capture** → **Automatic capture** ON.
3. Supabase CLI install karke (Windows: `scoop install supabase` ya `npx supabase`):

```bash
cd D:\8SpeedyService
supabase login
supabase link --project-ref YOUR-PROJECT-REF

supabase secrets set RAZORPAY_KEY_ID=rzp_live_xxx RAZORPAY_KEY_SECRET=xxx RAZORPAY_WEBHOOK_SECRET=apna_random_secret

supabase functions deploy razorpay-create-order
supabase functions deploy razorpay-verify-payment
supabase functions deploy razorpay-webhook --no-verify-jwt
```

4. Razorpay → **Settings → Webhooks → Add**:
   URL `https://YOUR-PROJECT-REF.supabase.co/functions/v1/razorpay-webhook`,
   Secret = upar wala `RAZORPAY_WEBHOOK_SECRET`, Events: `payment.captured`, `order.paid`.

> ⚠️ `RAZORPAY_KEY_SECRET` kabhi app ya git mein mat daalein. App mein sirf Key ID jaati hai.

## Step 3 — Mechanic Partner app (`mechanic_app/`)

1. **SQL Editor** → `supabase/migrations/20261117000002_mechanic_partner_app.sql` ka poora content paste → **Run**
   (pehli migration ke baad; dobara chalana safe hai).
2. Mechanics do tarike se judte hain:
   - **Khud register**: mechanic Partner app mein phone OTP se login → form bhare → row `is_verified = false` banti hai.
   - **Aap pehle se add karein**: Table Editor → mechanics → `full_name`, `phone` (`+91…`), `vehicle_specialties`.
     Mechanic jab us number se login karega, account apne aap link ho jaayega.
3. Verify karna: Table Editor → mechanics → `is_verified = true`. Tabhi mechanic Online jaa sakta hai.
4. App ka code alag repo mein hai: `github.com/durgadas-karmakar07/8SpeedyService.Partner` (PC par `D:\8SpeedyService.Partner`). Chalana / build: wahan ka `README.md`.
5. Partner app force-update: `app_config.min_partner_version`.

## Step 4 — App keys & placeholders

1. `env/example.json` copy karke `env/prod.json` banayein, apni values bharein (yeh file git mein nahi jaati).
2. `lib/core/constants/app_constants.dart` mein badlein:
   - `supportPhoneNumber` aur `whatsappSupportUrl` → apna WhatsApp number
   - `termsAndPrivacyUrl` → apni asli Privacy Policy URL (Play Store ke liye zaroori)
3. Har release par `pubspec.yaml` ka `version:` aur `AppConstants.appVersion` saath badlein.

## Step 5 — Check & Build (aapke PC par)

```bash
flutter clean
flutter pub get
flutter analyze
flutter test
flutter run --dart-define-from-file=env/prod.json          # phone par test
```

Release keystore (sirf ek baar, file safe rakhein — kho gayi to app update nahi kar paayenge):

```bash
keytool -genkey -v -keystore C:\Users\<you>\upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

`android/key.properties` banayein:

```
storePassword=xxxx
keyPassword=xxxx
keyAlias=upload
storeFile=C:/Users/<you>/upload-keystore.jks
```

Play Store bundle:

```bash
flutter build appbundle --release --dart-define-from-file=env/prod.json
```
Output: `build/app/outputs/bundle/release/app-release.aab`

## Step 6 — Launch se pehle test checklist

- [ ] Naya number se login → `customers` table mein row + 5 credits
- [ ] Partner app: naye number se register → Dashboard se `is_verified = true` → Online
- [ ] Free booking → Partner app mein request dikhe → Accept → customer app mein live tracking khule
- [ ] Partner: Arrived → customer ka OTP → Complete → customer app mein rating screen
- [ ] Partner: Accept ke baad "job chhodein" → customer app wapas radar par
- [ ] Customer accepted booking cancel kare → Partner app mein "Job closed" popup
- [ ] Credits 0 karke paid booking → Razorpay test mode (`rzp_test_…`) se UPI pay → `payment_status = PAID`
- [ ] Payment beech mein cancel → booking active nahi dikhti
- [ ] Searching mein cancel → credit wapas
- [ ] `COMPLETED` → rating submit → mechanic ka rating update
- [ ] `app_config.min_android_version` ko `9.0.0` karke force-update dialog check, phir wapas `1.0.0`

## Note — OpenStreetMap tiles
`tile.openstreetmap.org` launch/low traffic ke liye theek hai, lekin unki policy heavy
commercial use allow nahi karti. Users badhne par MapTiler / Stadia Maps (free tier) jaisa
provider `AppConstants.osmTileUrl` mein laga dein.
