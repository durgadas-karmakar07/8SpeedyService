/// Customer profile stored in the Supabase `customers` table.
class CustomerModel {
  const CustomerModel({
    required this.id,
    required this.phone,
    required this.fullName,
    required this.freeBookingsLeft,
    required this.referralCode,
    required this.isBlocked,
    this.referredBy,
  });

  /// Parses a `customers` JSON row from Supabase.
  factory CustomerModel.fromJson(Map<String, dynamic> json) {
    return CustomerModel(
      id: json['id']?.toString() ?? '',
      phone: json['phone'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '8Speedy User',
      freeBookingsLeft: (json['free_bookings_left'] as num?)?.toInt() ?? 0,
      referralCode: json['referral_code'] as String? ?? '',
      isBlocked: json['is_blocked'] as bool? ?? false,
      referredBy: json['referred_by'] as String?,
    );
  }

  final String id;
  final String phone;
  final String fullName;
  final int freeBookingsLeft;
  final String referralCode;
  final bool isBlocked;

  /// Friend's referral code applied by this customer (null if none).
  final String? referredBy;

  CustomerModel copyWith({
    String? id,
    String? phone,
    String? fullName,
    int? freeBookingsLeft,
    String? referralCode,
    bool? isBlocked,
    String? referredBy,
  }) {
    return CustomerModel(
      id: id ?? this.id,
      phone: phone ?? this.phone,
      fullName: fullName ?? this.fullName,
      freeBookingsLeft: freeBookingsLeft ?? this.freeBookingsLeft,
      referralCode: referralCode ?? this.referralCode,
      isBlocked: isBlocked ?? this.isBlocked,
      referredBy: referredBy ?? this.referredBy,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'phone': phone,
      'full_name': fullName,
      'free_bookings_left': freeBookingsLeft,
      'referral_code': referralCode,
      'is_blocked': isBlocked,
      'referred_by': referredBy,
    };
  }
}
