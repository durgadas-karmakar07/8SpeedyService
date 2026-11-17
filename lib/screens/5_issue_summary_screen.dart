// ignore_for_file: file_names

import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/error_helper.dart';
import '../models/app_config_model.dart';
import '../models/booking_model.dart';
import '../models/customer_model.dart';
import '../services/auth_service.dart';
import '../services/booking_service.dart';
import '../services/payment_service.dart';
import '6_searching_radar_screen.dart';

/// Issue selection, dynamic launch-offer pricing summary, and booking
/// confirmation (with Razorpay UPI checkout when platform fee > ₹0).
class IssueSummaryScreen extends StatefulWidget {
  const IssueSummaryScreen({
    super.key,
    required this.vehicleType,
    required this.pickupLat,
    required this.pickupLng,
    required this.pickupAddress,
    this.initialFreeBookingsLeft = 0,
  });

  final String vehicleType;
  final double pickupLat;
  final double pickupLng;
  final String pickupAddress;
  final int initialFreeBookingsLeft;

  @override
  State<IssueSummaryScreen> createState() => _IssueSummaryScreenState();
}

class _IssueSummaryScreenState extends State<IssueSummaryScreen> {
  final BookingService _bookingService = BookingService();
  final AuthService _authService = AuthService();
  final PaymentService _paymentService = PaymentService();
  final TextEditingController _noteController = TextEditingController();

  final Set<String> _selectedIssues = <String>{};

  AppConfigModel? _appConfig;
  CustomerModel? _customer;
  int _freeBookingsLeft = 0;
  bool _isLoadingConfig = true;
  bool _isSubmitting = false;
  String? _loadError;
  CreateBookingResult? _pendingPaymentBooking;

  /// Razorpay success details kept until the server confirms them, so a
  /// network failure during verification can be retried without paying again.
  ({String orderId, String paymentId, String signature})? _unverifiedPayment;

  @override
  void initState() {
    super.initState();
    _freeBookingsLeft = widget.initialFreeBookingsLeft;
    _loadPricingData();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _paymentService.dispose();
    super.dispose();
  }

  Future<void> _loadPricingData() async {
    setState(() {
      _isLoadingConfig = true;
      _loadError = null;
    });

    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        _bookingService.fetchAppConfig(),
        _authService.fetchCustomerProfile(),
      ]);

      if (!mounted) return;
      final config = results[0] as AppConfigModel;
      final customer = results[1] as CustomerModel?;

      setState(() {
        _appConfig = config;
        _customer = customer;
        if (customer != null) {
          _freeBookingsLeft = customer.freeBookingsLeft;
        }
        _isLoadingConfig = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingConfig = false;
        _loadError = 'Unable to load latest pricing. Tap Retry to refresh.';
      });
    }
  }

  bool get _isLaunchOfferApplied {
    final config = _appConfig;
    if (config == null) return false;
    return config.launchOfferActive && _freeBookingsLeft > 0;
  }

  int get _vehicleBaseFee {
    final config = _appConfig ?? AppConfigModel.defaults();
    return config.feeForVehicle(widget.vehicleType);
  }

  Future<void> _confirmAndCreateBooking() async {
    if (_selectedIssues.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one vehicle issue.'),
        ),
      );
      return;
    }

    final pending = _pendingPaymentBooking;
    if (pending != null) {
      final unverified = _unverifiedPayment;
      if (unverified != null) {
        await _verifyPayment(pending, unverified);
      } else {
        await _launchRazorpayCheckout(pending);
      }
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final result = await _bookingService.createBookingSecure(
        vehicleType: widget.vehicleType,
        issueTags: _selectedIssues.toList(),
        issueNote: _noteController.text,
        pickupAddress: widget.pickupAddress,
        lat: widget.pickupLat,
        lng: widget.pickupLng,
      );

      if (!mounted) return;

      if (!result.paymentRequired) {
        _navigateToSearchingRadar(result, isFreeOffer: true);
        return;
      }

      setState(() {
        _pendingPaymentBooking = result;
      });
      await _launchRazorpayCheckout(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError(error, 'Booking create nahi ho payi. Please retry.');
    }
  }

  Future<void> _launchRazorpayCheckout(CreateBookingResult result) async {
    final phone =
        _customer?.phone ?? _authService.currentUser?.phone ?? '';
    final name = _customer?.fullName ?? '8SpeedyService Customer';
    final vehicleOption = AppConstants.vehicleOptionForKey(widget.vehicleType);

    setState(() => _isSubmitting = true);

    late final RazorpayOrderInfo order;
    try {
      order = await _bookingService.createRazorpayOrder(result.bookingId);
    } catch (error) {
      if (!mounted) return;
      final details = error is FunctionException ? error.details : null;
      if (details is Map && details['already_paid'] == true) {
        // Payment was already confirmed (e.g. by the Razorpay webhook).
        _navigateToSearchingRadar(result, isFreeOffer: false);
        return;
      }
      setState(() => _isSubmitting = false);
      _showError(error, 'Payment start nahi ho paya. Please retry.');
      return;
    }
    if (!mounted) return;

    _paymentService.openCheckout(
      orderId: order.orderId,
      keyId: order.keyId,
      amountInPaise: order.amountInPaise,
      bookingId: result.bookingId,
      customerPhone: phone,
      customerName: name,
      description: 'Platform Fee - ${vehicleOption.title}',
      onSuccess: (response) {
        _verifyPayment(result, (
          orderId: response.orderId ?? order.orderId,
          paymentId: response.paymentId ?? '',
          signature: response.signature ?? '',
        ));
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
    );
  }

  Future<void> _verifyPayment(
    CreateBookingResult result,
    ({String orderId, String paymentId, String signature}) payment,
  ) async {
    setState(() {
      _isSubmitting = true;
      _unverifiedPayment = payment;
    });
    try {
      await _bookingService.verifyRazorpayPayment(
        bookingId: result.bookingId,
        orderId: payment.orderId,
        paymentId: payment.paymentId,
        signature: payment.signature,
      );
      if (!mounted) return;
      _unverifiedPayment = null;
      _navigateToSearchingRadar(result, isFreeOffer: false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError(
        error,
        'Payment ho gaya, par confirm nahi hua. Confirm dabakar retry karein — paisa dobara nahi katega.',
      );
    }
  }

  void _showError(Object error, String fallback) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ErrorHelper.friendly(error, fallback: fallback)),
      ),
    );
  }

  Future<void> _discardPendingBooking() async {
    final pending = _pendingPaymentBooking;
    if (pending == null) return;

    setState(() => _isSubmitting = true);
    try {
      await _bookingService.cancelBooking(pending.bookingId);
      if (!mounted) return;
      setState(() {
        _pendingPaymentBooking = null;
        _unverifiedPayment = null;
        _isSubmitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
    }
  }

  void _navigateToSearchingRadar(
    CreateBookingResult result, {
    required bool isFreeOffer,
  }) {
    final booking = BookingModel(
      id: result.bookingId,
      customerId: _authService.currentUser?.id ?? '',
      mechanicId: null,
      vehicleType: widget.vehicleType,
      issueTags: _selectedIssues.toList(),
      issueNote: _noteController.text.trim(),
      pickupAddress: widget.pickupAddress,
      pickupLat: widget.pickupLat,
      pickupLng: widget.pickupLng,
      status: AppConstants.statusSearching,
      startOtp: result.otp,
      platformFee: result.amount,
      isFreeOfferUsed: isFreeOffer,
      paymentStatus: isFreeOffer
          ? AppConstants.paymentFreeOffer
          : AppConstants.paymentPaid,
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SearchingRadarScreen(initialBooking: booking),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vehicleOption = AppConstants.vehicleOptionForKey(widget.vehicleType);
    final minVisitCharge = _appConfig?.minVisitCharge ?? 49;

    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(
        title: const Text('Describe Vehicle Issue'),
      ),
      body: SafeArea(
        child: _isLoadingConfig
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.cloud_off_rounded,
                        size: 48,
                        color: AppConstants.primaryColor,
                      ),
                      const SizedBox(height: 12),
                      Text(_loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _loadPricingData,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: <Widget>[
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: Row(
                              children: <Widget>[
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppConstants.primaryColor.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    vehicleOption.icon,
                                    color: AppConstants.primaryColor,
                                    size: 26,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        vehicleOption.title,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              color: AppConstants
                                                  .secondaryDarkColor,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        widget.pickupAddress,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.blueGrey.shade700,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'What seems to be the problem?',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AppConstants.secondaryDarkColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: AppConstants.issueTags.map((tag) {
                              final isSelected = _selectedIssues.contains(tag);
                              return FilterChip(
                                label: Text(
                                  tag,
                                  style: TextStyle(
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isSelected
                                        ? AppConstants.primaryDarkColor
                                        : AppConstants.secondaryDarkColor,
                                  ),
                                ),
                                selected: isSelected,
                                selectedColor: AppConstants.primaryColor
                                    .withValues(alpha: 0.16),
                                checkmarkColor: AppConstants.primaryColor,
                                side: BorderSide(
                                  color: isSelected
                                      ? AppConstants.primaryColor
                                      : Colors.grey.shade300,
                                ),
                                onSelected: _isSubmitting
                                    ? null
                                    : (selected) {
                                        setState(() {
                                          if (selected) {
                                            _selectedIssues.add(tag);
                                          } else {
                                            _selectedIssues.remove(tag);
                                          }
                                        });
                                      },
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _noteController,
                            enabled: !_isSubmitting,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 200,
                            decoration: InputDecoration(
                              labelText: 'Additional Note (Optional)',
                              hintText:
                                  'E.g., Near Junction Mall gate, Honda Activa 6G...',
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _isLaunchOfferApplied
                                    ? AppConstants.successColor
                                    : Colors.grey.shade200,
                                width: _isLaunchOfferApplied ? 1.5 : 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Icon(
                                      _isLaunchOfferApplied
                                          ? Icons.local_offer_rounded
                                          : Icons.receipt_long_rounded,
                                      color: _isLaunchOfferApplied
                                          ? AppConstants.successColor
                                          : AppConstants.primaryColor,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _isLaunchOfferApplied
                                            ? 'Platform Fee: ₹0 (Launch Offer Applied)'
                                            : 'Platform Fee: ₹$_vehicleBaseFee',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              color: _isLaunchOfferApplied
                                                  ? AppConstants.successColor
                                                  : AppConstants
                                                        .secondaryDarkColor,
                                            ),
                                      ),
                                    ),
                                    if (_isLaunchOfferApplied)
                                      Text(
                                        '₹$_vehicleBaseFee',
                                        style: TextStyle(
                                          decoration:
                                              TextDecoration.lineThrough,
                                          color: Colors.grey.shade500,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                                if (_isLaunchOfferApplied) ...<Widget>[
                                  const SizedBox(height: 6),
                                  Text(
                                    'You have $_freeBookingsLeft free booking credit(s) remaining.',
                                    style: const TextStyle(
                                      color: AppConstants.successColor,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.shade50,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: Colors.amber.shade300,
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Icon(
                                        Icons.info_outline_rounded,
                                        color: Colors.amber.shade900,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Mechanic repair & parts charges are separate and paid directly to the mechanic. Minimum visit charge ₹$minVisitCharge applies.',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: Colors.amber.shade900,
                                            fontSize: 12.5,
                                            height: 1.35,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 12,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_pendingPaymentBooking != null) ...<Widget>[
                          OutlinedButton(
                            onPressed: _isSubmitting
                                ? null
                                : _discardPendingBooking,
                            child: const Text('Cancel Pending Payment'),
                          ),
                          const SizedBox(height: 8),
                        ],
                        SizedBox(
                          height: 54,
                          child: FilledButton(
                            onPressed: _isSubmitting
                                ? null
                                : _confirmAndCreateBooking,
                            child: _isSubmitting
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    _pendingPaymentBooking != null
                                        ? 'Retry UPI Payment (₹${_pendingPaymentBooking!.amount})'
                                        : _isLaunchOfferApplied
                                        ? 'Confirm Booking (₹0 Fee)'
                                        : 'Pay ₹$_vehicleBaseFee & Find Mechanic',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
