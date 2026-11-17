import 'package:material_ui/material_ui.dart';

/// Application-wide constants, theme colors, Supabase placeholders,
/// Durgapur defaults, vehicle metadata, and booking status keys.
class AppConstants {
  AppConstants._();

  // ---------------------------------------------------------------------------
  // Backend & Payment Configuration
  // ---------------------------------------------------------------------------

  /// Supabase project URL. Override via `--dart-define=SUPABASE_URL=...`
  /// or replace the default placeholder before building for production.
  // ignore: constant_identifier_names
  static const String SUPABASE_URL = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://your-project-id.supabase.co',
  );

  /// Supabase anonymous/publishable key. Override via
  /// `--dart-define=SUPABASE_ANON_KEY=...` or replace the placeholder below.
  // ignore: constant_identifier_names
  static const String SUPABASE_ANON_KEY = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'your-supabase-anon-key',
  );

  /// Razorpay public Key ID for UPI / Checkout payments.
  // ignore: constant_identifier_names
  static const String RAZORPAY_KEY_ID = String.fromEnvironment(
    'RAZORPAY_KEY_ID',
    defaultValue: 'rzp_test_placeholder_key',
  );

  /// True when the real backend keys were supplied at build time.
  static bool get isBackendConfigured =>
      !SUPABASE_URL.contains('your-project-id') &&
      !SUPABASE_ANON_KEY.contains('your-supabase-anon-key');

  // ---------------------------------------------------------------------------
  // Brand & Theme
  // ---------------------------------------------------------------------------

  static const String appName = '8SpeedyService';

  /// Must match `version:` in pubspec.yaml (without the +build part).
  /// Compared against `app_config.min_android_version` for force updates.
  static const String appVersion = '1.0.0';
  static const String playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.speedyservice.customer';

  /// Returns true when [current] is older than [minimum] (e.g. 1.0.0 < 1.2.0).
  static bool isVersionOlder(String current, String minimum) {
    List<int> parse(String v) => v
        .split('+')
        .first
        .split('.')
        .map((part) => int.tryParse(part.trim()) ?? 0)
        .toList();
    final a = parse(current);
    final b = parse(minimum);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }
  static const String cityName = 'Durgapur';
  static const Color primaryColor = Color(0xFFFF5722);
  static const Color primaryDarkColor = Color(0xFFE64A19);
  static const Color secondaryDarkColor = Color(0xFF1E293B);
  static const Color backgroundColor = Color(0xFFF8FAFC);
  static const Color successColor = Color(0xFF16A34A);
  static const Color warningColor = Color(0xFFD97706);

  // ---------------------------------------------------------------------------
  // Map & Location Defaults (Durgapur City Centre)
  // ---------------------------------------------------------------------------

  static const double defaultLat = 23.5411;
  static const double defaultLng = 87.2915;
  static const String defaultPickupAddress =
      'City Centre, Durgapur, West Bengal';
  static const double defaultMapZoom = 15.0;
  static const String osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String osmUserAgentPackageName = 'com.speedyservice.customer';

  // ---------------------------------------------------------------------------
  // Booking Statuses & Payment Statuses
  // ---------------------------------------------------------------------------

  static const String statusSearching = 'SEARCHING';
  static const String statusAccepted = 'ACCEPTED';
  static const String statusArrived = 'ARRIVED';
  static const String statusInProgress = 'IN_PROGRESS';
  static const String statusCompleted = 'COMPLETED';
  static const String statusCancelled = 'CANCELLED';

  static const List<String> activeBookingStatuses = <String>[
    statusSearching,
    statusAccepted,
    statusArrived,
    statusInProgress,
  ];

  static const String paymentFreeOffer = 'FREE_OFFER';
  static const String paymentPending = 'PENDING';
  static const String paymentPaid = 'PAID';

  // ---------------------------------------------------------------------------
  // Search Radar Configuration
  // ---------------------------------------------------------------------------

  static const List<int> searchRadiiMeters = <int>[3000, 6000, 10000];
  static const Duration radarExpansionInterval = Duration(seconds: 45);

  // ---------------------------------------------------------------------------
  // Support & Legal Links
  // ---------------------------------------------------------------------------

  static const String supportPhoneNumber = '919800000000';
  static const String whatsappSupportUrl =
      'https://wa.me/919800000000?text=Hi%208SpeedyService%20Support%2C%20I%20need%20assistance%20in%20Durgapur.';
  static const String termsAndPrivacyUrl =
      'https://8speedyservice.in/terms-privacy';

  // ---------------------------------------------------------------------------
  // SharedPreferences Keys
  // ---------------------------------------------------------------------------

  static const String prefOnboardingSeen = 'onboarding_seen';
  static const String prefLastPickupLat = 'last_pickup_lat';
  static const String prefLastPickupLng = 'last_pickup_lng';
  static const String prefLastPickupAddress = 'last_pickup_address';

  // ---------------------------------------------------------------------------
  // Vehicle Types & Issue Tags
  // ---------------------------------------------------------------------------

  static const List<VehicleOption> vehicleOptions = <VehicleOption>[
    VehicleOption(
      key: 'cycle_toto',
      title: 'Cycle / Toto',
      subtitle: 'Bicycle, E-Rickshaw',
      defaultFee: 10,
      icon: Icons.pedal_bike_rounded,
    ),
    VehicleOption(
      key: 'two_wheeler',
      title: 'Bike / Scooty',
      subtitle: 'Motorcycle, Scooter',
      defaultFee: 15,
      icon: Icons.two_wheeler_rounded,
    ),
    VehicleOption(
      key: 'four_wheeler',
      title: 'Car / SUV',
      subtitle: 'Hatchback, Sedan, SUV',
      defaultFee: 25,
      icon: Icons.directions_car_rounded,
    ),
    VehicleOption(
      key: 'heavy_vehicle',
      title: 'Heavy / Van',
      subtitle: 'Pickup, Tempo, Truck',
      defaultFee: 40,
      icon: Icons.local_shipping_rounded,
    ),
  ];

  static const List<String> issueTags = <String>[
    'Puncture / Tyre Flat',
    'Start Nahi Ho Raha',
    'Battery Dead',
    'Chain / Brake',
    'Accident / Towing',
    'Other',
  ];

  /// Returns display metadata for [vehicleKey], falling back to two-wheeler.
  static VehicleOption vehicleOptionForKey(String vehicleKey) {
    for (final option in vehicleOptions) {
      if (option.key == vehicleKey) {
        return option;
      }
    }
    return vehicleOptions[1];
  }
}

/// Metadata describing a selectable vehicle category.
class VehicleOption {
  const VehicleOption({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.defaultFee,
    required this.icon,
  });

  final String key;
  final String title;
  final String subtitle;
  final int defaultFee;
  final IconData icon;
}
