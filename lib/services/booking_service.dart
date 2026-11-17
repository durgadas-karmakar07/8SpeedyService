import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../models/app_config_model.dart';
import '../models/booking_model.dart';
import '../models/mechanic_model.dart';

/// Encapsulates Supabase database queries, RPC calls, and realtime streams
/// for vehicle repair bookings and nearby mechanics.
class BookingService {
  BookingService({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  /// Fetches the singleton row (`id = 1`) from `app_config`.
  Future<AppConfigModel> fetchAppConfig() async {
    final data = await _client
        .from('app_config')
        .select()
        .eq('id', 1)
        .maybeSingle();

    if (data == null) {
      return AppConfigModel.defaults();
    }
    return AppConfigModel.fromJson(data);
  }

  /// Returns an active booking for the signed-in customer, if one exists.
  Future<BookingModel?> fetchActiveBooking() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final rows = await _client
        .from('bookings')
        .select()
        .eq('customer_id', user.id)
        .inFilter('status', AppConstants.activeBookingStatuses)
        .inFilter('payment_status', <String>[
          AppConstants.paymentFreeOffer,
          AppConstants.paymentPaid,
        ]);

    if (rows.isEmpty) return null;

    final bookings = rows
        .map((row) => BookingModel.fromJson(row))
        .toList();

    bookings.sort((a, b) {
      if (a.createdAt != null && b.createdAt != null) {
        return b.createdAt!.compareTo(a.createdAt!);
      }
      return 0;
    });

    return bookings.first;
  }

  /// Fetches all bookings belonging to the signed-in customer.
  Future<List<BookingModel>> fetchCustomerBookings() async {
    final user = _client.auth.currentUser;
    if (user == null) return const <BookingModel>[];

    final rows = await _client
        .from('bookings')
        .select()
        .eq('customer_id', user.id);

    final bookings = rows
        .map((row) => BookingModel.fromJson(row))
        .toList();

    bookings.sort((a, b) {
      if (a.createdAt != null && b.createdAt != null) {
        return b.createdAt!.compareTo(a.createdAt!);
      }
      return 0;
    });

    if (bookings.length > 1 &&
        bookings.every((booking) => booking.createdAt == null)) {
      return bookings.reversed.toList();
    }
    return bookings;
  }

  /// Fetches a single booking by [bookingId].
  Future<BookingModel?> fetchBookingById(String bookingId) async {
    final data = await _client
        .from('bookings')
        .select()
        .eq('id', bookingId)
        .maybeSingle();

    if (data == null) return null;
    return BookingModel.fromJson(data);
  }

  /// Invokes the `create_booking_secure` RPC to atomically validate pricing,
  /// apply launch free credits if eligible, and create a new booking.
  Future<CreateBookingResult> createBookingSecure({
    required String vehicleType,
    required List<String> issueTags,
    required String issueNote,
    required String pickupAddress,
    required double lat,
    required double lng,
    String? vehicleId,
  }) async {
    final dynamic response = await _client.rpc<dynamic>(
      'create_booking_secure',
      params: <String, dynamic>{
        'p_vehicle_type': vehicleType,
        'p_vehicle_id': vehicleId,
        'p_issue_tags': issueTags,
        'p_issue_note': issueNote.trim(),
        'p_pickup_address': pickupAddress.trim(),
        'p_lat': lat,
        'p_lng': lng,
      },
    );

    if (response is Map<String, dynamic>) {
      return CreateBookingResult.fromJson(response);
    }
    if (response is Map) {
      return CreateBookingResult.fromJson(
        Map<String, dynamic>.from(response),
      );
    }
    if (response is List && response.isNotEmpty && response.first is Map) {
      return CreateBookingResult.fromJson(
        Map<String, dynamic>.from(response.first as Map),
      );
    }

    throw StateError('Unexpected response format from create_booking_secure.');
  }

  /// Asks the server (Edge Function) to create a Razorpay Order for the
  /// booking. The amount is read from the database on the server, so the app
  /// can never change the price.
  Future<RazorpayOrderInfo> createRazorpayOrder(String bookingId) async {
    final response = await _client.functions.invoke(
      'razorpay-create-order',
      body: <String, dynamic>{'booking_id': bookingId},
    );
    final data = response.data;
    if (data is Map && data['order_id'] != null) {
      return RazorpayOrderInfo.fromJson(Map<String, dynamic>.from(data));
    }
    throw StateError(_serverMessage(data, 'Could not start payment.'));
  }

  /// Sends the Razorpay checkout result to the server, which verifies the
  /// signature with the secret key and marks the booking `PAID`.
  Future<void> verifyRazorpayPayment({
    required String bookingId,
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    final response = await _client.functions.invoke(
      'razorpay-verify-payment',
      body: <String, dynamic>{
        'booking_id': bookingId,
        'razorpay_order_id': orderId,
        'razorpay_payment_id': paymentId,
        'razorpay_signature': signature,
      },
    );
    final data = response.data;
    if (data is Map && data['verified'] == true) return;
    throw StateError(_serverMessage(data, 'Payment could not be verified.'));
  }

  /// Cancels a booking through the secure `cancel_booking` RPC. The server
  /// refunds the free credit if the booking was still searching.
  Future<void> cancelBooking(String bookingId) async {
    await _client.rpc<dynamic>(
      'cancel_booking',
      params: <String, dynamic>{'p_booking_id': bookingId},
    );
  }

  /// Applies a friend's referral code (allowed once, before first booking).
  Future<void> applyReferralCode(String code) async {
    await _client.rpc<dynamic>(
      'apply_referral_code',
      params: <String, dynamic>{'p_code': code.trim().toUpperCase()},
    );
  }

  static String _serverMessage(dynamic data, String fallback) {
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    return fallback;
  }

  /// Invokes `get_nearby_mechanics` RPC for [lat], [lng], [radiusMeters],
  /// and [vehicleType].
  Future<List<MechanicModel>> getNearbyMechanics({
    required double lat,
    required double lng,
    required int radiusMeters,
    required String vehicleType,
  }) async {
    final dynamic response = await _client.rpc<dynamic>(
      'get_nearby_mechanics',
      params: <String, dynamic>{
        'p_lat': lat,
        'p_lng': lng,
        'p_radius_meters': radiusMeters,
        'p_vehicle_type': vehicleType,
      },
    );

    if (response is List) {
      return response
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (item) => MechanicModel.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    }

    return const <MechanicModel>[];
  }

  /// Fetches a mechanic profile by [mechanicId].
  Future<MechanicModel?> fetchMechanicById(String mechanicId) async {
    final data = await _client
        .from('mechanics')
        .select()
        .eq('id', mechanicId)
        .maybeSingle();

    if (data == null) return null;
    return MechanicModel.fromJson(data);
  }

  /// Subscribes to realtime updates for a single booking row.
  Stream<BookingModel?> streamBooking(String bookingId) {
    return _client
        .from('bookings')
        .stream(primaryKey: <String>['id'])
        .eq('id', bookingId)
        .map(
          (rows) => rows.isEmpty ? null : BookingModel.fromJson(rows.first),
        );
  }

  /// Subscribes to realtime location and profile updates for a mechanic row.
  Stream<MechanicModel?> streamMechanic(String mechanicId) {
    return _client
        .from('mechanics')
        .stream(primaryKey: <String>['id'])
        .eq('id', mechanicId)
        .map(
          (rows) => rows.isEmpty ? null : MechanicModel.fromJson(rows.first),
        );
  }

  /// Saves customer star [rating] (1..5) and optional [reviewText] on a booking.
  Future<void> submitBookingReview({
    required String bookingId,
    required int rating,
    String? reviewText,
  }) async {
    await _client.rpc<dynamic>(
      'submit_booking_review',
      params: <String, dynamic>{
        'p_booking_id': bookingId,
        'p_rating': rating,
        'p_review_text': reviewText?.trim() ?? '',
      },
    );
  }
}

/// Razorpay order details returned by the `razorpay-create-order` function.
class RazorpayOrderInfo {
  const RazorpayOrderInfo({
    required this.orderId,
    required this.amountInPaise,
    required this.keyId,
  });

  factory RazorpayOrderInfo.fromJson(Map<String, dynamic> json) {
    return RazorpayOrderInfo(
      orderId: json['order_id'].toString(),
      amountInPaise: (json['amount'] as num?)?.toInt() ?? 0,
      keyId: json['key_id']?.toString() ?? '',
    );
  }

  final String orderId;
  final int amountInPaise;
  final String keyId;
}
