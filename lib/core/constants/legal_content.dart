/// In-app legal documents (shown even without internet hosting).
/// Keep in sync with legal-site/*.html.
library;

import 'app_constants.dart';

class LegalSection {
  const LegalSection(this.heading, this.body);
  final String heading;
  final String body;
}

class LegalDoc {
  const LegalDoc({
    required this.title,
    required this.updated,
    required this.url,
    required this.sections,
  });
  final String title;

  /// Same document on the public website (GitHub Pages).
  final String url;
  final String updated;
  final List<LegalSection> sections;
}

class LegalContent {
  LegalContent._();

  static const String contact =
      '8SpeedyService, Durgapur, West Bengal, India\n'
      'WhatsApp / Phone: +91 96352 97320';

  static const LegalDoc privacy = LegalDoc(
    title: 'Privacy Policy',
    updated: 'Last updated: 18 November 2026',
    url: AppConstants.privacyPolicyUrl,
    sections: <LegalSection>[
      LegalSection(
        'Who we are',
        '8SpeedyService ("we", "us") runs the 8SpeedyService customer app and the 8Speedy Partner mechanic app in Durgapur, India. We follow the Information Technology Act, 2000 and the Digital Personal Data Protection Act, 2023.',
      ),
      LegalSection(
        'Data we collect',
        '• Mobile number — to log you in with an SMS OTP and to connect you with your mechanic.\n'
            '• Name (optional) — shown to your mechanic during a job.\n'
            '• Precise location — your pickup point, only when you book or tap "Locate me".\n'
            '• Vehicle details — type, brand, model, and optional number plate and fuel. The number plate is shown to the mechanic only after they accept.\n'
            '• Booking details — issue, address, status, rating and review.\n'
            '• Voice note (optional) — a short recording describing the problem, only if you tap the microphone. Only mechanics who can see your request, and the one who accepts it, can play it.\n'
            '• Payment status — Razorpay order and payment IDs. Card, UPI and bank details are handled by Razorpay; we never see or store them.\n'
            'Partners: name, phone, shop details, vehicle types repaired, and live location while Online or on a job (also in the background, with a visible notification).',
      ),
      LegalSection(
        'How we share data',
        '• With your assigned mechanic during an active job: name, phone, pickup address and vehicle. You see the mechanic\'s first name, phone and live location.\n'
            '• With service providers: Supabase (database and login, servers in Mumbai), the SMS provider for OTPs, Razorpay (payments), and OpenStreetMap (map images).\n'
            '• When required by Indian law.\n'
            'We do not sell your data and we do not show ads.',
      ),
      LegalSection(
        'How long we keep data',
        'Account data is kept while your account is active. When you delete your account, your name, phone number, saved vehicles, voice notes and location are deleted or anonymised immediately. Booking and payment records are kept without your identity for up to 8 years for tax and accounting.',
      ),
      LegalSection(
        'Your rights',
        'You can edit your name in the app and delete your account at any time from Menu → Account & Privacy → Delete my account. You can also contact us to access, correct or erase your data, or to withdraw consent.',
      ),
      LegalSection(
        'Security',
        'All data is encrypted in transit (HTTPS). Database rules let each user see only their own data, payments are verified only on our servers, and the start OTP is never shown to mechanics.',
      ),
      LegalSection('Children', 'The apps are meant for people aged 18 and above.'),
      LegalSection(
        'Contact & grievance officer',
        'Grievance Officer: 8SpeedyService Support Team\n$contact\nWe reply within 7 days and resolve complaints within 30 days.',
      ),
    ],
  );

  static const LegalDoc terms = LegalDoc(
    title: 'Terms of Service',
    updated: 'Last updated: 18 November 2026',
    url: AppConstants.termsUrl,
    sections: <LegalSection>[
      LegalSection(
        'What we do',
        '8SpeedyService is a platform that connects vehicle owners in Durgapur with independent, verified roadside mechanics ("Partners"). Partners are not our employees, and we do not carry out repairs ourselves.',
      ),
      LegalSection(
        'Fees',
        '• The platform fee is shown before you book and pays for dispatch and live tracking. Launch-offer credits can make it ₹0.\n'
            '• Repair labour, spare parts and the minimum visit charge are paid directly to the mechanic. Agree on the price with the mechanic before work starts.',
      ),
      LegalSection(
        'Start OTP',
        'Share your 4-digit Start OTP only when the mechanic is with your vehicle and you agree to start the work.',
      ),
      LegalSection(
        'Cancellations & refunds',
        '• You can cancel for free while we are searching; a used free credit is returned.\n'
            '• If no mechanic accepts within 30 minutes, the booking is cancelled automatically, a used free credit is returned, and a paid platform fee is refunded to the original payment method within 5–7 working days.\n'
            '• Once a mechanic is assigned, the platform fee is non-refundable unless the mechanic does not arrive.',
      ),
      LegalSection(
        'Your responsibilities',
        'Give a correct location and vehicle details, stay reachable by phone, and treat partners with respect. We may suspend accounts that misuse the service.',
      ),
      LegalSection(
        'Liability',
        'The independent mechanic is responsible for the repair. To the extent the law allows, our liability is limited to the platform fee paid for that booking. Report any problem within 48 hours and we will help resolve it.',
      ),
      LegalSection(
        'Governing law',
        'These terms are governed by the laws of India. Courts at Durgapur, West Bengal have jurisdiction.',
      ),
      LegalSection('Contact', contact),
    ],
  );
}
