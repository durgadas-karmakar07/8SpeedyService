# 8SpeedyService — Play Store listing (customer app)

Package: `com.speedyservice.customer` · Category: **Auto & Vehicles** · Free · Contains ads: **No**

Files in this folder:
- `play_store_icon_512.png` → App icon (512×512)
- `feature_graphic_1024x500.png` → Feature graphic
- Screenshots: phone par app chala kar 4–8 screenshots lein (Home map, 8Speedy Assist AI result, Issue summary, Live tracking + chat, Repair bill, My bookings). Min 2 zaroori.

## App name (max 30)
8SpeedyService: Roadside Repair

## Short description (max 80)
Vehicle broke down? Book a nearby verified mechanic and track them live.

## Full description
Stuck with a flat tyre, dead battery or a vehicle that won't start? 8SpeedyService sends the nearest verified mechanic in Durgapur straight to your location.

HOW IT WORKS
• Set your exact location on the map — or pick Home / Work from your saved places
• Choose your vehicle — scooter, bike, car, SUV, e-rickshaw (toto), auto, cycle, pickup or truck — with brand and model
• Tell us the problem — puncture, battery, starting trouble, chain/brakes, towing — or describe it in your own words in English, Hindi or Bengali
• 8Speedy Assist (AI) shows the likely causes, how urgent it is, a typical repair cost and what to do while you wait
• A nearby verified mechanic accepts your request
• Watch the mechanic arrive on a live map with ETA, chat in the app or call directly
• Share your 4-digit Start OTP only when the work begins — safe and transparent
• Get a digital repair bill and rate the service

WHY 8SPEEDYSERVICE
• Verified local mechanics with ratings
• AI diagnosis and an estimated repair cost before you book
• Live tracking, in-app chat and direct calling
• SOS: call 112 / 108 and share your trip with family in one tap
• My Vehicles and Saved Places: book in one tap next time
• Launch offer: ₹0 platform fee on your first bookings
• Clear pricing: the platform fee is shown upfront; repair charges are paid directly to the mechanic
• Secure UPI payments via Razorpay, with automatic refunds

Service area: Durgapur, West Bengal (City Centre, Benachity, Bidhannagar, A-Zone, B-Zone and nearby).

Support: WhatsApp +91 96352 97320 (also in the app: Menu → WhatsApp Support).
Privacy Policy: https://durgadas-karmakar07.github.io/8SpeedyService/privacy.html

---

## App content (Play Console → Policy → App content)

| Section | Answer |
|---|---|
| Privacy policy | `https://durgadas-karmakar07.github.io/8SpeedyService/privacy.html` |
| App access | Login required (phone OTP). Reviewer ke liye: Supabase → Auth → Phone → **Test OTP** add karein (jaise `919999999999=123456`) aur yahan number + OTP likhein |
| Ads | No ads |
| Content rating | Questionnaire → "Utility / Productivity / Other", koi violence/sexual content nahi → **Everyone / 3+** |
| Target audience | 18+ |
| News app | No |
| Government app | No |
| Financial features | None (payments via Razorpay only for platform fee) |
| Health | No |
| Account deletion | Yes, in-app (Menu → Account & Privacy → Delete my account). Web link: `https://durgadas-karmakar07.github.io/8SpeedyService/delete-account.html` |

## Data safety form

**Data collected & shared?** Yes. **Encrypted in transit?** Yes. **Users can request deletion?** Yes.

| Data type | Collected | Shared | Optional? | Purpose |
|---|---|---|---|---|
| Location → Precise location (pickup point, saved places) | Yes | Yes (pickup point with assigned mechanic) | Required | App functionality |
| Personal info → Name | Yes | Yes (with assigned mechanic) | Optional | App functionality |
| Personal info → Phone number | Yes | Yes (with assigned mechanic) | Required | Account management, App functionality |
| Financial info → Purchase history (platform fee, repair bill) | Yes | No | Required | App functionality |
| Messages → Other in-app messages (chat with the assigned mechanic) | Yes | Yes (the assigned mechanic) | Optional | App functionality |
| App activity → Other user-generated content (reviews, notes, AI assistant questions) | Yes | Yes (short AI summary with mechanics who see the request) | Optional | App functionality |
| App activity → Other actions (bookings, cancellations, security logs) | Yes | No | Required | App functionality, Fraud prevention, security & compliance |
| Audio → Voice or sound recordings (voice note about the problem) | Yes | Yes (with nearby / assigned mechanic) | Optional | App functionality |
| App info & performance | No | — | — | — |
| Device or other IDs | No | — | — | — |

"Shared" = mechanic dekhta hai sirf active job ke dauran (voice note aur AI summary request dekhne wale nearby mechanics bhi). Razorpay (payment) aur Anthropic (AI answers) ko data "service provider" ke taur par jaata hai — Google ke rules mein ise "sharing" nahi maana jaata. "Is data processed ephemerally?" → **No**.

**AI-generated content policy:** har AI answer ke neeche *Helpful / Not helpful / Report* button hai (app chhode bina report). Reports Supabase mein `ai_requests.feedback` mein aate hain — review query `PRODUCTION_SETUP.md` mein hai.

## Permissions used
- `ACCESS_FINE_LOCATION` / `COARSE` — pickup point (sirf app khula ho tab)
- `RECORD_AUDIO` — optional voice note (sirf mic button dabane par; background mein kabhi nahi)
- `INTERNET`
- Background location: **No**
