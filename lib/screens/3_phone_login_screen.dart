// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../services/auth_service.dart';
import '../services/booking_service.dart';
import '4_home_map_screen.dart';
import '6_searching_radar_screen.dart';
import '7_live_tracking_screen.dart';
import '../widgets/speedy_loader.dart';

/// +91 Indian mobile number and 6-digit SMS OTP authentication screen.
class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({super.key, this.blockedNotice});

  final String? blockedNotice;

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final GlobalKey<FormState> _phoneFormKey = GlobalKey<FormState>();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final AuthService _authService = AuthService();
  final BookingService _bookingService = BookingService();

  bool _otpSent = false;
  bool _isLoading = false;
  int _resendSeconds = 0;
  Timer? _resendTimer;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _errorText = widget.blockedNotice;
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = 30);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        timer.cancel();
        setState(() => _resendSeconds = 0);
      } else {
        setState(() => _resendSeconds -= 1);
      }
    });
  }

  Future<void> _sendOtp() async {
    FocusScope.of(context).unfocus();
    if (!_otpSent && !(_phoneFormKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await _authService.sendOtp(_phoneController.text.trim());
      if (!mounted) return;
      setState(() {
        _otpSent = true;
        _isLoading = false;
      });
      _startResendCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '6-digit OTP sent to +91 ${_phoneController.text.trim()}',
          ),
        ),
      );
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = 'Could not send OTP. Please check your connection.';
      });
    }
  }

  Future<void> _verifyOtp() async {
    FocusScope.of(context).unfocus();
    final otp = _otpController.text.trim();
    if (otp.length != 6 || !RegExp(r'^\d{6}$').hasMatch(otp)) {
      setState(() {
        _errorText = 'Please enter the valid 6-digit OTP sent via SMS.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final response = await _authService.verifyOtp(
        phoneNumber: _phoneController.text.trim(),
        otp: otp,
      );
      if (!mounted) return;

      if (response.session == null) {
        setState(() {
          _isLoading = false;
          _errorText = 'Verification did not return a session. Please retry.';
        });
        return;
      }

      final customer = await _authService.fetchCustomerProfile();
      if (!mounted) return;
      if (customer != null && customer.isBlocked) {
        await _authService.signOut();
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _otpSent = false;
          _otpController.clear();
          _errorText =
              'Your account has been restricted. Please contact support.';
        });
        return;
      }

      Widget destination = const HomeMapScreen();
      try {
        final activeBooking = await _bookingService.fetchActiveBooking();
        if (activeBooking != null) {
          destination = activeBooking.isSearching
              ? SearchingRadarScreen(initialBooking: activeBooking)
              : LiveTrackingScreen(
                  bookingId: activeBooking.id,
                  initialBooking: activeBooking,
                );
        }
      } catch (_) {
        // Proceed to HomeMapScreen if active booking check cannot complete now.
      }

      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => destination),
        (_) => false,
      );
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = 'OTP verification failed. Please double-check and retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: 64,
                      height: 64,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _otpSent
                        ? 'Enter 6-Digit OTP'
                        : 'Sign in with Mobile Number',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppConstants.secondaryDarkColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _otpSent
                        ? 'We sent an SMS verification code to +91 ${_phoneController.text.trim()}.'
                        : 'Fast roadside mechanic dispatch in ${AppConstants.cityName}. Enter your +91 mobile number to continue.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.blueGrey.shade700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_errorText != null) ...<Widget>[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.error_outline_rounded,
                            color: Colors.red.shade700,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _errorText!,
                              style: TextStyle(
                                color: Colors.red.shade900,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (!_otpSent)
                    Form(
                      key: _phoneFormKey,
                      child: TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        maxLength: 10,
                        enabled: !_isLoading,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Mobile Number',
                          hintText: '9876543210',
                          counterText: '',
                          prefixIcon: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 15,
                            ),
                            child: Text(
                              '+91',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                                color: AppConstants.secondaryDarkColor,
                              ),
                            ),
                          ),
                          prefixIconConstraints: const BoxConstraints(),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        validator: (value) {
                          if (value == null ||
                              !AuthService.isValidIndianMobile(value)) {
                            return 'Enter a valid 10-digit Indian mobile number.';
                          }
                          return null;
                        },
                      ),
                    )
                  else ...<Widget>[
                    TextField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      enabled: !_isLoading,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 10,
                      ),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: InputDecoration(
                        labelText: '6-Digit OTP',
                        hintText: '••••••',
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        TextButton.icon(
                          onPressed: _isLoading
                              ? null
                              : () {
                                  _resendTimer?.cancel();
                                  setState(() {
                                    _otpSent = false;
                                    _otpController.clear();
                                    _errorText = null;
                                  });
                                },
                          icon: const Icon(Icons.edit_rounded, size: 18),
                          label: const Text('Change Number'),
                        ),
                        TextButton(
                          onPressed: (_isLoading || _resendSeconds > 0)
                              ? null
                              : _sendOtp,
                          child: Text(
                            _resendSeconds > 0
                                ? 'Resend in ${_resendSeconds}s'
                                : 'Resend OTP',
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton(
                      onPressed: _isLoading
                          ? null
                          : (_otpSent ? _verifyOtp : _sendOtp),
                      child: _isLoading
                          ? const DotsLoader()
                          : Text(
                              _otpSent ? 'Verify & Continue' : 'Send OTP',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: const Row(
                      children: <Widget>[
                        Icon(
                          Icons.celebration_rounded,
                          color: AppConstants.primaryColor,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'New Durgapur customers get launch-offer ₹0 platform fee credits automatically!',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppConstants.secondaryDarkColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
