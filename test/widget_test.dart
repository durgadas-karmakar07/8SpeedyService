import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:eight_speedy_service/core/constants/app_constants.dart';
import 'package:eight_speedy_service/models/app_config_model.dart';
import 'package:eight_speedy_service/models/booking_model.dart';
import 'package:eight_speedy_service/models/mechanic_model.dart';
import 'package:eight_speedy_service/screens/2_onboarding_screen.dart';
import 'package:eight_speedy_service/screens/8_job_completed_screen.dart';
import 'package:eight_speedy_service/services/auth_service.dart';

void main() {
  group('Models and Auth Helpers', () {
    test('AppConfigModel parses fees_by_vehicle and launch offer', () {
      final config = AppConfigModel.fromJson(<String, dynamic>{
        'id': 1,
        'launch_offer_active': true,
        'default_free_credits': 5,
        'min_visit_charge': 49,
        'min_android_version': '1.0.0',
        'fees_by_vehicle': <String, dynamic>{
          'cycle_toto': 10,
          'two_wheeler': 15,
          'four_wheeler': 25,
          'heavy_vehicle': 40,
        },
      });

      expect(config.launchOfferActive, isTrue);
      expect(config.minVisitCharge, equals(49));
      expect(config.feeForVehicle('cycle_toto'), equals(10));
      expect(config.feeForVehicle('two_wheeler'), equals(15));
      expect(config.feeForVehicle('four_wheeler'), equals(25));
      expect(config.feeForVehicle('heavy_vehicle'), equals(40));
    });

    test('BookingModel and CreateBookingResult parse RPC & row JSON', () {
      final rpcResult = CreateBookingResult.fromJson(<String, dynamic>{
        'booking_id': 'bk-123',
        'payment_required': false,
        'otp': '4829',
        'amount': 0,
      });

      expect(rpcResult.bookingId, equals('bk-123'));
      expect(rpcResult.paymentRequired, isFalse);
      expect(rpcResult.otp, equals('4829'));
      expect(rpcResult.amount, equals(0));

      final booking = BookingModel.fromJson(<String, dynamic>{
        'id': 'bk-123',
        'customer_id': 'cust-1',
        'mechanic_id': 'mech-9',
        'vehicle_type': 'two_wheeler',
        'issue_tags': <String>['Puncture / Tyre Flat'],
        'issue_note': 'Near Benachity',
        'pickup_address': 'Benachity, Durgapur',
        'pickup_lat': 23.55,
        'pickup_lng': 87.29,
        'status': 'ACCEPTED',
        'start_otp': '4829',
        'platform_fee': 0,
        'is_free_offer_used': true,
        'payment_status': 'FREE_OFFER',
      });

      expect(booking.isAccepted, isTrue);
      expect(booking.isActive, isTrue);
      expect(booking.isFreeOfferUsed, isTrue);
    });

    test('MechanicModel parses coordinates and verification state', () {
      final mechanic = MechanicModel.fromJson(<String, dynamic>{
        'id': 'mech-9',
        'full_name': 'Raju Das',
        'phone': '+919876543210',
        'shop_name': 'City Centre Auto Works',
        'is_verified': true,
        'is_online': true,
        'current_lat': 23.5411,
        'current_lng': 87.2915,
        'rating': 4.8,
      });

      expect(mechanic.isVerified, isTrue);
      expect(mechanic.hasValidCoordinates, isTrue);
      expect(mechanic.rating, equals(4.8));
    });

    test('MechanicModel parses get_nearby_mechanics RPC rows', () {
      final mechanic = MechanicModel.fromJson(<String, dynamic>{
        'mechanic_id': 'mech-7',
        'full_name': 'Raju',
        'distance_meters': 459.8,
        'lat': 23.545,
        'lng': 87.29,
      });

      expect(mechanic.id, equals('mech-7'));
      expect(mechanic.currentLat, equals(23.545));
      expect(mechanic.currentLng, equals(87.29));
      expect(mechanic.hasValidCoordinates, isTrue);
      expect(mechanic.distanceMeters, equals(459.8));
    });

    test('AuthService normalizes and validates Indian mobile numbers', () {
      expect(
        AuthService.normalizeIndianPhone('9876543210'),
        equals('+919876543210'),
      );
      expect(AuthService.isValidIndianMobile('9876543210'), isTrue);
      expect(AuthService.isValidIndianMobile('1234567890'), isFalse);
      expect(AuthService.isValidIndianMobile('98765'), isFalse);
    });
  });

  group('UI Widget Smoke Tests', () {
    testWidgets('OnboardingScreen highlights launch offer and slides', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: OnboardingScreen()),
      );

      expect(
        find.text('LAUNCH OFFER: First 5 Bookings Platform Fee ₹0'),
        findsOneWidget,
      );
      expect(find.text('15-Minute On-Spot Arrival'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Cycle, Toto, Bike, Car & Heavy'), findsOneWidget);
    });

    testWidgets('JobCompletedScreen renders rating stars and summary', (
      WidgetTester tester,
    ) async {
      const booking = BookingModel(
        id: 'bk-999',
        customerId: 'cust-1',
        mechanicId: 'mech-1',
        vehicleType: 'four_wheeler',
        issueTags: <String>['Battery Dead'],
        issueNote: '',
        pickupAddress: AppConstants.defaultPickupAddress,
        pickupLat: AppConstants.defaultLat,
        pickupLng: AppConstants.defaultLng,
        status: AppConstants.statusCompleted,
        startOtp: '1234',
        platformFee: 0,
        isFreeOfferUsed: true,
        paymentStatus: AppConstants.paymentFreeOffer,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: JobCompletedScreen(booking: booking),
        ),
      );

      expect(find.text('Service Completed!'), findsOneWidget);
      expect(find.text('₹0 (Launch Offer)'), findsOneWidget);
      expect(find.text('Excellent!'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.star_rounded).at(2));
      await tester.pump();
      expect(find.text('Good'), findsOneWidget);
    });
  });
}
