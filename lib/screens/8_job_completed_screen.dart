// ignore_for_file: file_names

import 'package:material_ui/material_ui.dart';

import '../core/constants/app_constants.dart';
import '../models/booking_model.dart';
import '../models/mechanic_model.dart';
import '../services/booking_service.dart';
import '4_home_map_screen.dart';
import '../widgets/speedy_loader.dart';

/// Displays job completion summary, interactive 1-to-5 star rating bar,
/// and optional review box before returning to [HomeMapScreen].
class JobCompletedScreen extends StatefulWidget {
  const JobCompletedScreen({
    super.key,
    required this.booking,
    this.mechanic,
  });

  final BookingModel booking;
  final MechanicModel? mechanic;

  @override
  State<JobCompletedScreen> createState() => _JobCompletedScreenState();
}

class _JobCompletedScreenState extends State<JobCompletedScreen> {
  final BookingService _bookingService = BookingService();
  final TextEditingController _reviewController = TextEditingController();

  int _selectedRating = 5;
  bool _isSubmitting = false;

  static const List<String> _ratingLabels = <String>[
    'Tap a star to rate',
    'Poor',
    'Fair',
    'Good',
    'Very Good',
    'Excellent!',
  ];

  @override
  void dispose() {
    _reviewController.dispose();
    super.dispose();
  }

  Future<void> _submitRating() async {
    if (_selectedRating < 1 || _selectedRating > 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a 1 to 5 star rating.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      await _bookingService.submitBookingReview(
        bookingId: widget.booking.id,
        rating: _selectedRating,
        reviewText: _reviewController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thank you for rating your 8SpeedyService mechanic!'),
        ),
      );
      _goHome();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not submit review right now. Please retry.'),
        ),
      );
    }
  }

  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const HomeMapScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Job Completed'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade200),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      children: <Widget>[
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: AppConstants.successColor.withValues(
                              alpha: 0.12,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check_circle_rounded,
                            color: AppConstants.successColor,
                            size: 46,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Service Completed!',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppConstants.secondaryDarkColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.mechanic != null
                              ? 'Repaired by ${widget.mechanic!.fullName} (${widget.mechanic!.shopName})'
                              : 'Your ${widget.booking.vehicleDisplayName} service is complete.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.blueGrey.shade700,
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Divider(height: 1),
                        const SizedBox(height: 14),
                        _SummaryRow(
                          label: 'Vehicle',
                          value: widget.booking.vehicleDisplayName,
                        ),
                        const SizedBox(height: 8),
                        _SummaryRow(
                          label: 'Platform Fee',
                          value: widget.booking.isFreeOfferUsed
                              ? '₹0 (Launch Offer)'
                              : '₹${widget.booking.platformFee}',
                          valueColor: widget.booking.isFreeOfferUsed
                              ? AppConstants.successColor
                              : AppConstants.secondaryDarkColor,
                        ),
                        const SizedBox(height: 8),
                        _SummaryRow(
                          label: 'Payment Status',
                          value: widget.booking.paymentStatus,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      children: <Widget>[
                        Text(
                          'Rate Your Experience',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppConstants.secondaryDarkColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _ratingLabels[_selectedRating],
                          style: const TextStyle(
                            color: AppConstants.primaryColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List<Widget>.generate(5, (index) {
                            final starValue = index + 1;
                            final isSelected = starValue <= _selectedRating;
                            return IconButton(
                              onPressed: _isSubmitting
                                  ? null
                                  : () {
                                      setState(
                                        () => _selectedRating = starValue,
                                      );
                                    },
                              iconSize: 34,
                              padding: const EdgeInsets.all(4),
                              constraints: const BoxConstraints(
                                minWidth: 42,
                                minHeight: 42,
                              ),
                              splashRadius: 24,
                              icon: Icon(
                                isSelected
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                color: isSelected
                                    ? Colors.amber.shade600
                                    : Colors.grey.shade400,
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _reviewController,
                          enabled: !_isSubmitting,
                          maxLines: 3,
                          maxLength: 300,
                          decoration: InputDecoration(
                            labelText: 'Optional Review',
                            hintText:
                                'Share feedback on arrival time, repair quality, or pricing...',
                            alignLabelWithHint: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 54,
                    child: FilledButton(
                      onPressed: _isSubmitting ? null : _submitRating,
                      child: _isSubmitting
                          ? const DotsLoader()
                          : const Text(
                              'Submit Rating & Back to Home',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _isSubmitting ? null : _goHome,
                    child: const Text('Skip & Return to Home'),
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

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(color: Colors.blueGrey.shade600, fontSize: 13.5),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? AppConstants.secondaryDarkColor,
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
          ),
        ),
      ],
    );
  }
}
