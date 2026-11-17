import '../core/constants/app_constants.dart';

/// Vehicle repair booking stored in the Supabase `bookings` table.
class BookingModel {
  const BookingModel({
    required this.id,
    required this.customerId,
    required this.mechanicId,
    required this.vehicleType,
    required this.issueTags,
    required this.issueNote,
    required this.pickupAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.status,
    required this.startOtp,
    required this.platformFee,
    required this.isFreeOfferUsed,
    required this.paymentStatus,
    this.rating,
    this.reviewText,
    this.createdAt,
  });

  /// Parses a `bookings` JSON row from Supabase.
  factory BookingModel.fromJson(Map<String, dynamic> json) {
    final rawTags = json['issue_tags'];
    final parsedTags = <String>[];
    if (rawTags is List) {
      for (final tag in rawTags) {
        if (tag != null) {
          parsedTags.add(tag.toString());
        }
      }
    }

    DateTime? parsedCreatedAt;
    final rawCreatedAt = json['created_at'];
    if (rawCreatedAt is String) {
      parsedCreatedAt = DateTime.tryParse(rawCreatedAt);
    }

    return BookingModel(
      id: json['id']?.toString() ?? '',
      customerId: json['customer_id']?.toString() ?? '',
      mechanicId: json['mechanic_id']?.toString(),
      vehicleType: json['vehicle_type'] as String? ?? 'two_wheeler',
      issueTags: parsedTags,
      issueNote: json['issue_note'] as String? ?? '',
      pickupAddress: json['pickup_address'] as String? ?? '',
      pickupLat: (json['pickup_lat'] as num?)?.toDouble() ?? 0.0,
      pickupLng: (json['pickup_lng'] as num?)?.toDouble() ?? 0.0,
      status: json['status'] as String? ?? AppConstants.statusSearching,
      startOtp: json['start_otp']?.toString() ?? '',
      platformFee: (json['platform_fee'] as num?)?.toInt() ?? 0,
      isFreeOfferUsed: json['is_free_offer_used'] as bool? ?? false,
      paymentStatus:
          json['payment_status'] as String? ?? AppConstants.paymentPending,
      rating: (json['rating'] as num?)?.toInt(),
      reviewText: json['review_text'] as String?,
      createdAt: parsedCreatedAt,
    );
  }

  final String id;
  final String customerId;
  final String? mechanicId;
  final String vehicleType;
  final List<String> issueTags;
  final String issueNote;
  final String pickupAddress;
  final double pickupLat;
  final double pickupLng;
  final String status;
  final String startOtp;
  final int platformFee;
  final bool isFreeOfferUsed;
  final String paymentStatus;
  final int? rating;
  final String? reviewText;
  final DateTime? createdAt;

  bool get isSearching => status == AppConstants.statusSearching;
  bool get isAccepted => status == AppConstants.statusAccepted;
  bool get isArrived => status == AppConstants.statusArrived;
  bool get isInProgress => status == AppConstants.statusInProgress;
  bool get isCompleted => status == AppConstants.statusCompleted;
  bool get isCancelled => status == AppConstants.statusCancelled;
  bool get isActive => AppConstants.activeBookingStatuses.contains(status);

  BookingModel copyWith({
    String? id,
    String? customerId,
    String? mechanicId,
    String? vehicleType,
    List<String>? issueTags,
    String? issueNote,
    String? pickupAddress,
    double? pickupLat,
    double? pickupLng,
    String? status,
    String? startOtp,
    int? platformFee,
    bool? isFreeOfferUsed,
    String? paymentStatus,
    int? rating,
    String? reviewText,
    DateTime? createdAt,
  }) {
    return BookingModel(
      id: id ?? this.id,
      customerId: customerId ?? this.customerId,
      mechanicId: mechanicId ?? this.mechanicId,
      vehicleType: vehicleType ?? this.vehicleType,
      issueTags: issueTags ?? this.issueTags,
      issueNote: issueNote ?? this.issueNote,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      pickupLat: pickupLat ?? this.pickupLat,
      pickupLng: pickupLng ?? this.pickupLng,
      status: status ?? this.status,
      startOtp: startOtp ?? this.startOtp,
      platformFee: platformFee ?? this.platformFee,
      isFreeOfferUsed: isFreeOfferUsed ?? this.isFreeOfferUsed,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      rating: rating ?? this.rating,
      reviewText: reviewText ?? this.reviewText,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'customer_id': customerId,
      'mechanic_id': mechanicId,
      'vehicle_type': vehicleType,
      'issue_tags': issueTags,
      'issue_note': issueNote,
      'pickup_address': pickupAddress,
      'pickup_lat': pickupLat,
      'pickup_lng': pickupLng,
      'status': status,
      'start_otp': startOtp,
      'platform_fee': platformFee,
      'is_free_offer_used': isFreeOfferUsed,
      'payment_status': paymentStatus,
      'rating': rating,
      'review_text': reviewText,
    };
  }
}

/// Response returned by the `create_booking_secure` Supabase RPC.
class CreateBookingResult {
  const CreateBookingResult({
    required this.bookingId,
    required this.paymentRequired,
    required this.otp,
    required this.amount,
  });

  factory CreateBookingResult.fromJson(Map<String, dynamic> json) {
    return CreateBookingResult(
      bookingId: json['booking_id']?.toString() ?? '',
      paymentRequired: json['payment_required'] as bool? ?? false,
      otp: json['otp']?.toString() ?? '',
      amount: (json['amount'] as num?)?.toInt() ?? 0,
    );
  }

  final String bookingId;
  final bool paymentRequired;
  final String otp;
  final int amount;
}
