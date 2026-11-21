import '../core/constants/app_constants.dart';

/// Global remote configuration stored in the Supabase `app_config` table.
class AppConfigModel {
  const AppConfigModel({
    required this.id,
    required this.launchOfferActive,
    required this.defaultFreeCredits,
    required this.minVisitCharge,
    required this.minAndroidVersion,
    required this.feesByVehicle,
    this.serviceMessage,
  });

  /// Creates default configuration matching the database schema defaults.
  factory AppConfigModel.defaults() {
    return const AppConfigModel(
      id: 1,
      launchOfferActive: true,
      defaultFreeCredits: 5,
      minVisitCharge: 49,
      minAndroidVersion: '1.0.0',
      feesByVehicle: <String, int>{
        'cycle_toto': 10,
        'two_wheeler': 15,
        'four_wheeler': 25,
        'heavy_vehicle': 40,
      },
    );
  }

  /// Parses an `app_config` JSON row from Supabase.
  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    final defaults = AppConfigModel.defaults();
    final rawFees = json['fees_by_vehicle'];
    final parsedFees = Map<String, int>.from(defaults.feesByVehicle);

    if (rawFees is Map) {
      for (final entry in rawFees.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is num) {
          parsedFees[key] = value.toInt();
        } else if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) {
            parsedFees[key] = parsed;
          }
        }
      }
    }

    return AppConfigModel(
      id: (json['id'] as num?)?.toInt() ?? defaults.id,
      launchOfferActive:
          json['launch_offer_active'] as bool? ?? defaults.launchOfferActive,
      defaultFreeCredits:
          (json['default_free_credits'] as num?)?.toInt() ??
          defaults.defaultFreeCredits,
      minVisitCharge:
          (json['min_visit_charge'] as num?)?.toInt() ??
          defaults.minVisitCharge,
      minAndroidVersion:
          json['min_android_version'] as String? ?? defaults.minAndroidVersion,
      feesByVehicle: parsedFees,
      serviceMessage:
          (json['service_message'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['service_message'] as String).trim(),
    );
  }

  final int id;
  final bool launchOfferActive;
  final int defaultFreeCredits;
  final int minVisitCharge;
  final String minAndroidVersion;
  final Map<String, int> feesByVehicle;

  /// Optional announcement shown on the home screen (e.g. heavy rain delays).
  final String? serviceMessage;

  /// Returns the platform fee in INR for the given [vehicleType].
  int feeForVehicle(String vehicleType) {
    return feesByVehicle[vehicleType] ??
        AppConstants.vehicleOptionForKey(vehicleType).defaultFee;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'launch_offer_active': launchOfferActive,
      'default_free_credits': defaultFreeCredits,
      'min_visit_charge': minVisitCharge,
      'min_android_version': minAndroidVersion,
      'fees_by_vehicle': feesByVehicle,
    };
  }
}
