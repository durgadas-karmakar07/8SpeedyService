/// Verified mechanic partner stored in the Supabase `mechanics` table.
class MechanicModel {
  const MechanicModel({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.shopName,
    required this.avatarUrl,
    required this.isVerified,
    required this.isOnline,
    required this.currentLat,
    required this.currentLng,
    required this.rating,
    this.distanceMeters,
  });

  /// Parses a `mechanics` row or `get_nearby_mechanics` RPC record.
  ///
  /// The RPC returns `mechanic_id`, `lat`, `lng` while the table row uses
  /// `id`, `current_lat`, `current_lng` — both shapes are supported.
  factory MechanicModel.fromJson(Map<String, dynamic> json) {
    return MechanicModel(
      id: (json['id'] ?? json['mechanic_id'])?.toString() ?? '',
      fullName: json['full_name'] as String? ?? 'Mechanic Partner',
      phone: json['phone'] as String? ?? '',
      shopName: json['shop_name'] as String? ?? '8Speedy Authorized Garage',
      avatarUrl: json['avatar_url'] as String?,
      isVerified:
          json['is_verified'] as bool? ?? json.containsKey('mechanic_id'),
      isOnline: json['is_online'] as bool? ?? json.containsKey('mechanic_id'),
      currentLat:
          ((json['current_lat'] ?? json['lat']) as num?)?.toDouble() ?? 0.0,
      currentLng:
          ((json['current_lng'] ?? json['lng']) as num?)?.toDouble() ?? 0.0,
      rating: (json['rating'] as num?)?.toDouble() ?? 5.0,
      distanceMeters: (json['distance_meters'] as num?)?.toDouble(),
    );
  }

  final String id;
  final String fullName;
  final String phone;
  final String shopName;
  final String? avatarUrl;
  final bool isVerified;
  final bool isOnline;
  final double currentLat;
  final double currentLng;
  final double rating;
  final double? distanceMeters;

  bool get hasValidCoordinates => currentLat != 0.0 || currentLng != 0.0;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'full_name': fullName,
      'phone': phone,
      'shop_name': shopName,
      'avatar_url': avatarUrl,
      'is_verified': isVerified,
      'is_online': isOnline,
      'current_lat': currentLat,
      'current_lng': currentLng,
      'rating': rating,
      if (distanceMeters != null) 'distance_meters': distanceMeters,
    };
  }
}
