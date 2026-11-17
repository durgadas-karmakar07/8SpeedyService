import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/customer_vehicle.dart';

/// Customer's saved vehicles. Reads are direct (RLS: own rows only);
/// writes go through server functions that validate the data.
class VehicleService {
  VehicleService({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  Future<List<CustomerVehicle>> fetchMyVehicles() async {
    final user = _client.auth.currentUser;
    if (user == null) return const <CustomerVehicle>[];
    final rows = await _client
        .from('customer_vehicles')
        .select()
        .eq('customer_id', user.id)
        .eq('is_deleted', false)
        .order('last_used_at', ascending: false, nullsFirst: false)
        .order('created_at', ascending: false);
    return rows.map(CustomerVehicle.fromJson).toList();
  }

  Future<CustomerVehicle> saveVehicle({
    required String bodyType,
    required String brand,
    required String model,
    String? regNumber,
    String? fuelType,
    String? vehicleId,
  }) async {
    final dynamic data = await _client.rpc<dynamic>(
      'customer_save_vehicle',
      params: <String, dynamic>{
        'p_body_type': bodyType,
        'p_brand': brand.trim(),
        'p_model': model.trim(),
        'p_reg_number': regNumber?.trim(),
        'p_fuel_type': fuelType,
        'p_vehicle_id': vehicleId,
      },
    );
    if (data is Map) {
      return CustomerVehicle.fromJson(Map<String, dynamic>.from(data));
    }
    throw StateError('Could not save the vehicle. Please try again.');
  }

  Future<void> deleteVehicle(String vehicleId) async {
    await _client.rpc<dynamic>(
      'customer_delete_vehicle',
      params: <String, dynamic>{'p_vehicle_id': vehicleId},
    );
  }
}
