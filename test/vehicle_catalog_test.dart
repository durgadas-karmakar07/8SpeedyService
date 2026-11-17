import 'package:flutter_test/flutter_test.dart';

import 'package:eight_speedy_service/core/constants/vehicle_catalog.dart';
import 'package:eight_speedy_service/models/booking_model.dart';
import 'package:eight_speedy_service/models/customer_vehicle.dart';

void main() {
  // Must match public.vehicle_category_for_body() in the SQL migration.
  const serverMap = <String, String>{
    'cycle': 'cycle_toto',
    'e_rickshaw': 'cycle_toto',
    'scooter': 'two_wheeler',
    'motorcycle': 'two_wheeler',
    'auto_rickshaw': 'four_wheeler',
    'hatchback': 'four_wheeler',
    'sedan': 'four_wheeler',
    'suv': 'four_wheeler',
    'pickup': 'heavy_vehicle',
    'truck': 'heavy_vehicle',
  };

  test('every body type maps to the same category as the server', () {
    expect(VehicleCatalog.bodyTypes.length, serverMap.length);
    for (final b in VehicleCatalog.bodyTypes) {
      expect(serverMap[b.key], b.category, reason: b.key);
      expect(b.brands, isNotEmpty, reason: b.key);
      expect(b.asset, 'assets/vehicles/${b.key}.png');
    }
  });

  test('number plate formatting', () {
    expect(VehicleCatalog.formatReg('WB38AB1234'), 'WB 38 AB 1234');
    expect(VehicleCatalog.formatReg('22BH1234AA'), '22BH1234AA');
    expect(VehicleCatalog.formatReg(null), '');
  });

  test('CustomerVehicle parses server row', () {
    final v = CustomerVehicle.fromJson(<String, dynamic>{
      'id': 'v1',
      'category': 'two_wheeler',
      'body_type': 'scooter',
      'brand': 'Honda',
      'model': 'Activa 6G',
      'reg_number': 'WB38AB1234',
    });
    expect(v.name, 'Honda Activa 6G');
    expect(v.subtitle, 'WB 38 AB 1234');
    expect(v.asset, 'assets/vehicles/scooter.png');
  });

  test('booking shows saved vehicle name, falls back for old bookings', () {
    final withVehicle = BookingModel.fromJson(<String, dynamic>{
      'id': 'b1',
      'vehicle_type': 'two_wheeler',
      'vehicle_label': 'Honda Activa 6G • WB38AB1234',
      'vehicle_body_type': 'scooter',
    });
    expect(withVehicle.vehicleDisplayName, 'Honda Activa 6G');
    expect(withVehicle.vehicleAsset, 'assets/vehicles/scooter.png');

    final old = BookingModel.fromJson(<String, dynamic>{'id': 'b2', 'vehicle_type': 'four_wheeler'});
    expect(old.vehicleDisplayName, 'Car / SUV');
    expect(old.vehicleAsset, 'assets/vehicles/hatchback.png');
  });
}
