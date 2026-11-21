import '../core/constants/vehicle_catalog.dart';

/// A vehicle saved by the customer (`public.customer_vehicles`).
class CustomerVehicle {
  const CustomerVehicle({
    required this.id,
    required this.category,
    required this.bodyType,
    required this.brand,
    required this.model,
    this.regNumber,
    this.fuelType,
  });

  factory CustomerVehicle.fromJson(Map<String, dynamic> json) {
    String? opt(dynamic v) {
      final s = v?.toString().trim() ?? '';
      return s.isEmpty ? null : s;
    }

    return CustomerVehicle(
      id: json['id'].toString(),
      category: json['category']?.toString() ?? 'two_wheeler',
      bodyType: json['body_type']?.toString() ?? 'scooter',
      brand: json['brand']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      regNumber: opt(json['reg_number']),
      fuelType: opt(json['fuel_type']),
    );
  }

  final String id;
  final String category;
  final String bodyType;
  final String brand;
  final String model;
  final String? regNumber;
  final String? fuelType;

  /// "Honda Activa 6G"
  String get name => '$brand $model'.trim();

  /// "WB 38 AB 1234" or the body type title when no number was given.
  String get subtitle {
    final reg = VehicleCatalog.formatReg(regNumber);
    if (reg.isNotEmpty) return reg;
    return VehicleCatalog.bodyFor(bodyType)?.title ?? '';
  }

  String get asset =>
      VehicleCatalog.assetFor(bodyType: bodyType, category: category);
}
