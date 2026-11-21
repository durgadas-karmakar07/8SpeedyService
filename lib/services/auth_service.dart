import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../models/customer_model.dart';

/// Handles Supabase phone OTP authentication and customer profile access.
class AuthService {
  AuthService({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  /// Returns the current active auth session, or `null` when signed out.
  Session? get currentSession => _client.auth.currentSession;

  /// Returns the currently signed-in user, or `null` when signed out.
  User? get currentUser => _client.auth.currentUser;

  /// Formats a 10-digit Indian phone number into E.164 (`+91XXXXXXXXXX`).
  static String normalizeIndianPhone(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      return '+$digits';
    }
    if (digits.length == 10) {
      return '+91$digits';
    }
    if (input.trim().startsWith('+')) {
      return input.trim();
    }
    return '+91$digits';
  }

  /// Validates that [input] is a valid 10-digit Indian mobile number.
  static bool isValidIndianMobile(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    final tenDigits = digits.length == 12 && digits.startsWith('91')
        ? digits.substring(2)
        : digits;
    return RegExp(r'^[6-9]\d{9}$').hasMatch(tenDigits);
  }

  /// Sends a 6-digit SMS OTP to [phoneNumber].
  Future<void> sendOtp(String phoneNumber) async {
    final formatted = normalizeIndianPhone(phoneNumber);
    await _client.auth.signInWithOtp(phone: formatted, shouldCreateUser: true);
  }

  /// Verifies the 6-digit SMS [otp] for [phoneNumber] and establishes a session.
  Future<AuthResponse> verifyOtp({
    required String phoneNumber,
    required String otp,
  }) async {
    final formatted = normalizeIndianPhone(phoneNumber);
    return _client.auth.verifyOTP(
      phone: formatted,
      token: otp.trim(),
      type: OtpType.sms,
    );
  }

  /// Fetches the signed-in customer's profile from the `customers` table.
  Future<CustomerModel?> fetchCustomerProfile() async {
    final user = currentUser;
    if (user == null) return null;

    final data = await _client
        .from('customers')
        .select()
        .eq('id', user.id)
        .maybeSingle();

    if (data != null) return CustomerModel.fromJson(data);

    // Safety net: profile row missing (e.g. account created before the
    // backend trigger was installed) -> create it on the server.
    final created = await _client.rpc<dynamic>('ensure_customer_profile');
    if (created is Map && created['id'] != null) {
      return CustomerModel.fromJson(Map<String, dynamic>.from(created));
    }
    return null;
  }

  /// Updates the signed-in customer's display name in `customers`.
  Future<void> updateCustomerName(String fullName) async {
    final user = currentUser;
    if (user == null) {
      throw StateError('No signed-in user available to update profile.');
    }

    await _client
        .from('customers')
        .update(<String, dynamic>{'full_name': fullName.trim()})
        .eq('id', user.id);
  }

  /// Marks onboarding as viewed in local storage.
  Future<void> markOnboardingSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOnboardingSeen, true);
  }

  /// Permanently deletes the account (Google Play requirement). The server
  /// anonymises personal data and ends all sessions.
  Future<void> deleteAccount() async {
    final response = await _client.functions.invoke(
      'delete-account',
      body: <String, dynamic>{'confirm': 'DELETE'},
    );
    final data = response.data;
    if (data is Map && data['deleted'] == true) {
      try {
        await _client.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
      return;
    }
    throw StateError(
      data is Map && data['error'] is String
          ? data['error'] as String
          : 'Could not delete the account. Please try again.',
    );
  }

  /// Signs out the current customer from Supabase Auth.
  Future<void> signOut() async {
    await _client.auth.signOut();
  }
}
