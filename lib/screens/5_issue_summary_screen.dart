// ignore_for_file: file_names

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/error_helper.dart';
import '../models/app_config_model.dart';
import '../models/assist_models.dart';
import '../models/booking_model.dart';
import '../models/customer_model.dart';
import '../models/customer_vehicle.dart';
import '../services/auth_service.dart';
import '../services/booking_service.dart';
import '../services/payment_service.dart';
import '../services/voice_service.dart';
import '../widgets/premium.dart';
import '../widgets/speedy_loader.dart';
import '../widgets/vehicle_widgets.dart';
import '../widgets/voice_note_recorder.dart';
import '6_searching_radar_screen.dart';
import 'ai/ai_assist_screen.dart';

/// Issue selection (server-driven catalog), optional AI diagnosis, voice note,
/// pricing summary and booking confirmation (Razorpay checkout when the
/// platform fee is above ₹0).
class IssueSummaryScreen extends StatefulWidget {
  const IssueSummaryScreen({
    super.key,
    required this.vehicle,
    required this.pickupLat,
    required this.pickupLng,
    required this.pickupAddress,
    this.initialFreeBookingsLeft = 0,
    this.initialDiagnosis,
  });

  final CustomerVehicle vehicle;

  /// AI diagnosis made before opening this screen (pre-selects its issues).
  final AssistDiagnosis? initialDiagnosis;
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
  List<IssueOption> _catalog = const <IssueOption>[];

  /// Optional recorded description, uploaded right after the booking is made.
  VoiceClip? _voiceClip;

  /// AI diagnosis the customer made (linked to the booking on the server).
  AssistDiagnosis? _diagnosis;

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
    final d = widget.initialDiagnosis;
    if (d != null) {
      _diagnosis = d;
      _selectedIssues.addAll(d.suggestedIssueTags);
    }
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
        _bookingService.fetchIssueCatalog().catchError(
          (_) => const <IssueOption>[],
        ),
      ]);

      if (!mounted) return;
      final config = results[0] as AppConfigModel;
      final customer = results[1] as CustomerModel?;
      final catalog = results[2] as List<IssueOption>;

      setState(() {
        _appConfig = config;
        _customer = customer;
        _catalog = catalog
            .where((o) => o.fits(widget.vehicle.category))
            .toList();
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

  List<String> get _issueLabels => _catalog.isNotEmpty
      ? _catalog.map((o) => o.label).toList()
      : AppConstants.issueTags;

  IconData _iconFor(String label) {
    for (final o in _catalog) {
      if (o.label == label) return issueIcon(o.icon);
    }
    return issueIconForLabel(label);
  }

  bool get _isLaunchOfferApplied {
    final config = _appConfig;
    if (config == null) return false;
    return config.launchOfferActive && _freeBookingsLeft > 0;
  }

  int get _vehicleBaseFee {
    final config = _appConfig ?? AppConfigModel.defaults();
    return config.feeForVehicle(widget.vehicle.category);
  }

  Future<void> _openAssist() async {
    final result = await Navigator.of(context).push<AssistDiagnosis>(
      MaterialPageRoute<AssistDiagnosis>(
        builder: (_) => AiAssistScreen(
          vehicle: widget.vehicle,
          initialTags: _selectedIssues.toList(),
          initialNote: _noteController.text,
          issueOptions: _issueLabels,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _diagnosis = result;
      final valid = result.suggestedIssueTags.where(_issueLabels.contains);
      if (valid.isNotEmpty) {
        _selectedIssues
          ..clear()
          ..addAll(valid);
      }
    });
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
    HapticFeedback.selectionClick();

    try {
      final result = await _bookingService.createBooking(
        vehicleType: widget.vehicle.category,
        vehicleId: widget.vehicle.id,
        issueTags: _selectedIssues.toList(),
        issueNote: _noteController.text,
        pickupAddress: widget.pickupAddress,
        lat: widget.pickupLat,
        lng: widget.pickupLng,
        aiRequestId: _diagnosis?.requestId.isNotEmpty == true
            ? _diagnosis!.requestId
            : null,
      );

      if (!mounted) return;
      await _sendVoiceNote(result.bookingId);
      if (!mounted) return;

      if (!result.paymentRequired) {
        _navigateToSearchingRadar(result, isFreeOffer: true);
        return;
      }

      setState(() => _pendingPaymentBooking = result);
      await _launchRazorpayCheckout(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError(error, 'Could not create the booking. Please try again.');
    }
  }

  Future<void> _launchRazorpayCheckout(CreateBookingResult result) async {
    final phone = _customer?.phone ?? _authService.currentUser?.phone ?? '';
    final name = _customer?.fullName ?? '8SpeedyService Customer';
    setState(() => _isSubmitting = true);

    late final RazorpayOrderInfo order;
    try {
      order = await _bookingService.createRazorpayOrder(result.bookingId);
    } catch (error) {
      if (!mounted) return;
      final details = error is FunctionException ? error.details : null;
      if (details is Map && details['already_paid'] == true) {
        // Payment was already confirmed (webhook, or a reconciled earlier order).
        _navigateToSearchingRadar(result, isFreeOffer: false);
        return;
      }
      setState(() => _isSubmitting = false);
      _showError(error, 'Could not start the payment. Please try again.');
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
      description: 'Platform Fee - ${widget.vehicle.name}',
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
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
        'Payment received but not confirmed yet. Tap the button again to retry — you will not be charged twice.',
      );
    }
  }

  /// Uploads the voice note for [bookingId]. A failure never blocks the
  /// booking — the typed issues and note are already saved.
  Future<void> _sendVoiceNote(String bookingId) async {
    final clip = _voiceClip;
    if (clip == null) return;
    try {
      await VoiceService.instance
          .uploadForBooking(bookingId: bookingId, clip: clip)
          .timeout(const Duration(seconds: 25));
      _voiceClip = null;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Booking confirmed, but the voice note could not be sent. Mechanics will see your typed details.',
          ),
        ),
      );
    }
  }

  void _showError(Object error, String fallback) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ErrorHelper.friendly(error, fallback: fallback))),
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
      vehicleType: widget.vehicle.category,
      vehicleLabel: widget.vehicle.name,
      vehicleBodyType: widget.vehicle.bodyType,
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
      aiSummary: _diagnosis?.summary,
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SearchingRadarScreen(initialBooking: booking),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final minVisitCharge = _appConfig?.minVisitCharge ?? 49;

    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(title: const Text('Describe the Problem')),
      body: SafeArea(
        child: _isLoadingConfig
            ? const Center(
                child: RoadLoader(
                  messages: <String>[
                    'Loading latest prices…',
                    'Checking your free credits…',
                  ],
                ),
              )
            : _loadError != null
            ? _errorView()
            : Column(
                children: <Widget>[
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _vehicleCard(),
                          const SizedBox(height: 14),
                          _assistCard(),
                          const SizedBox(height: 18),
                          const SectionTitle(
                            'What seems to be the problem?',
                            icon: Icons.build_circle_outlined,
                          ),
                          _issueGrid(),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _noteController,
                            enabled: !_isSubmitting,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 200,
                            decoration: InputDecoration(
                              labelText: 'Landmark or extra details (optional)',
                              hintText: 'E.g. Near Junction Mall gate, engine stops right after starting…',
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                          VoiceNoteRecorder(
                            enabled:
                                !_isSubmitting &&
                                _pendingPaymentBooking == null,
                            onChanged: (clip) => _voiceClip = clip,
                          ),
                          const SizedBox(height: 14),
                          _priceCard(minVisitCharge),
                        ],
                      ),
                    ),
                  ),
                  _bottomBar(),
                ],
              ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
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
    );
  }

  Widget _vehicleCard() {
    return PremiumCard(
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 84,
            child: VehicleImage(asset: widget.vehicle.asset, height: 52),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.vehicle.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: AppConstants.secondaryDarkColor,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.location_on_rounded,
                      size: 14,
                      color: AppConstants.primaryColor,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.pickupAddress,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _assistCard() {
    final d = _diagnosis;
    return Container(
      decoration: BoxDecoration(
        gradient: kNightGradient,
        borderRadius: BorderRadius.circular(22),
        boxShadow: softShadow(2),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: _isSubmitting ? null : _openAssist,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: kBrandGradient,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        d == null
                            ? 'Not sure what\'s wrong?'
                            : 'AI diagnosis ready',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        d == null
                            ? 'Ask 8Speedy Assist — likely cause, fair price and safety tips in seconds.'
                            : '${d.summary}\nEstimated ${formatInr(d.costMin)} – ${formatInr(d.costMax)}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _issueGrid() {
    final labels = _issueLabels;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: labels.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.05,
      ),
      itemBuilder: (_, i) {
        final tag = labels[i];
        final selected = _selectedIssues.contains(tag);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: selected
                ? AppConstants.primaryColor.withValues(alpha: 0.10)
                : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? AppConstants.primaryColor
                  : const Color(0xFFE2E8F0),
              width: selected ? 1.6 : 1,
            ),
            boxShadow: selected ? null : softShadow(0.6),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: _isSubmitting
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      setState(
                        () => selected
                            ? _selectedIssues.remove(tag)
                            : _selectedIssues.add(tag),
                      );
                    },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      _iconFor(tag),
                      size: 28,
                      color: selected
                          ? AppConstants.primaryColor
                          : const Color(0xFF475569),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tag,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.2,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: selected
                            ? AppConstants.primaryDarkColor
                            : AppConstants.secondaryDarkColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _priceCard(int minVisitCharge) {
    return PremiumCard(
      borderColor: _isLaunchOfferApplied ? AppConstants.successColor : null,
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
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: _isLaunchOfferApplied
                        ? AppConstants.successColor
                        : AppConstants.secondaryDarkColor,
                  ),
                ),
              ),
              if (_isLaunchOfferApplied)
                Text(
                  '₹$_vehicleBaseFee',
                  style: TextStyle(
                    decoration: TextDecoration.lineThrough,
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
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFCD34D)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(
                  Icons.info_outline_rounded,
                  color: Color(0xFFB45309),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Repair & parts are paid directly to the mechanic after the work. Minimum visit charge ₹$minVisitCharge. Never pay anyone in advance.',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF92400E),
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
    );
  }

  Widget _bottomBar() {
    return Container(
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
              onPressed: _isSubmitting ? null : _discardPendingBooking,
              child: const Text('Cancel Pending Payment'),
            ),
            const SizedBox(height: 8),
          ],
          GradientButton(
            loading: _isSubmitting,
            icon: Icons.bolt_rounded,
            onPressed: _confirmAndCreateBooking,
            label: _pendingPaymentBooking != null
                ? 'Retry UPI Payment (₹${_pendingPaymentBooking!.amount})'
                : _isLaunchOfferApplied
                ? 'Confirm Booking (₹0 Fee)'
                : 'Pay ₹$_vehicleBaseFee & Find Mechanic',
          ),
        ],
      ),
    );
  }
}
