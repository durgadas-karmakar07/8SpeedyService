// ignore_for_file: file_names

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/error_helper.dart';
import '../models/booking_model.dart';
import '../models/mechanic_model.dart';
import '../services/booking_service.dart';
import '../widgets/premium.dart';
import '../widgets/speedy_loader.dart';
import '4_home_map_screen.dart';

/// Job completion: digital bill, summary, 1–5 star rating with quick tags and
/// an optional review.
class JobCompletedScreen extends StatefulWidget {
  const JobCompletedScreen({super.key, required this.booking, this.mechanic});

  final BookingModel booking;
  final MechanicModel? mechanic;

  @override
  State<JobCompletedScreen> createState() => _JobCompletedScreenState();
}

class _JobCompletedScreenState extends State<JobCompletedScreen>
    with SingleTickerProviderStateMixin {
  final BookingService _bookingService = BookingService();
  final TextEditingController _reviewController = TextEditingController();
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  final Set<String> _tags = <String>{};

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
    _pop.dispose();
    super.dispose();
  }

  List<String> get _tagOptions => _selectedRating >= 4
      ? AppConstants.positiveReviewTags
      : <String>[
          ...AppConstants.negativeReviewTags,
          ...AppConstants.positiveReviewTags.take(3),
        ];

  Future<void> _submitRating() async {
    if (_selectedRating < 1 || _selectedRating > 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a 1 to 5 star rating.')),
      );
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      await _bookingService.submitReview(
        bookingId: widget.booking.id,
        rating: _selectedRating,
        reviewText: _reviewController.text,
        tags: _tags.where(_tagOptions.contains).toList(),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thank you for rating your 8SpeedyService mechanic!'),
        ),
      );
      _goHome();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ErrorHelper.friendly(
              e,
              fallback: 'Could not submit review right now. Please retry.',
            ),
          ),
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

  Future<void> _shareReceipt() async {
    final b = widget.booking;
    final text = StringBuffer('8SpeedyService receipt\n')
      ..write('Vehicle: ${b.vehicleDisplayName}\n')
      ..write('Issues: ${b.issueTags.join(', ')}\n')
      ..write(
        'Platform fee: ${b.isFreeOfferUsed ? '₹0 (Launch Offer)' : '₹${b.platformFee}'}\n',
      )
      ..write(
        b.repairAmount != null
            ? 'Repair bill (paid to mechanic): ${formatInr(b.repairAmount!)}\n'
            : '',
      )
      ..write('Booking: ${b.id.length >= 8 ? b.id.substring(0, 8) : b.id}');
    try {
      await launchUrl(
        Uri.parse(
          'https://wa.me/?text=${Uri.encodeComponent(text.toString())}',
        ),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  String? get _duration {
    final s = widget.booking.startedAt;
    final c = widget.booking.completedAt;
    if (s == null || c == null || c.isBefore(s)) return null;
    final m = c.difference(s).inMinutes;
    return m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min';
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Job Completed'),
        centerTitle: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'Share receipt',
            onPressed: _shareReceipt,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: ScaleTransition(
                  scale: CurvedAnimation(
                    parent: _pop,
                    curve: Curves.elasticOut,
                  ),
                  child: Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: <Color>[
                          Color(0xFF22C55E),
                          AppConstants.successColor,
                        ],
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: AppConstants.successColor.withValues(
                            alpha: 0.35,
                          ),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 56,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Service Completed!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppConstants.secondaryDarkColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.mechanic != null
                    ? 'Repaired by ${widget.mechanic!.fullName}'
                    : 'Your ${b.vehicleDisplayName} service is complete.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 18),
              if (b.repairAmount != null) ...<Widget>[
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: kNightGradient,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: softShadow(2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Row(
                        children: <Widget>[
                          Icon(
                            Icons.receipt_long_rounded,
                            color: Colors.white70,
                            size: 18,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Repair bill',
                            style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        formatInr(b.repairAmount!),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (b.repairNotes != null && b.repairNotes!.isNotEmpty)
                        Text(
                          b.repairNotes!,
                          style: const TextStyle(
                            color: Colors.white70,
                            height: 1.4,
                          ),
                        ),
                      const SizedBox(height: 6),
                      const Text(
                        'Paid directly to the mechanic',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              PremiumCard(
                child: Column(
                  children: <Widget>[
                    _row('Vehicle', b.vehicleDisplayName),
                    _row(
                      'Platform Fee',
                      b.isFreeOfferUsed
                          ? '₹0 (Launch Offer)'
                          : '₹${b.platformFee}',
                    ),
                    _row('Payment Status', b.paymentStatus),
                    if (_duration != null) _row('Repair time', _duration!),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              PremiumCard(
                child: Column(
                  children: <Widget>[
                    const Text(
                      'How was your mechanic?',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppConstants.secondaryDarkColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _ratingLabels[_selectedRating],
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppConstants.primaryColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List<Widget>.generate(5, (index) {
                        final starValue = index + 1;
                        return IconButton(
                          iconSize: 40,
                          onPressed: _isSubmitting
                              ? null
                              : () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _selectedRating = starValue);
                                },
                          icon: Icon(
                            starValue <= _selectedRating
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            color: const Color(0xFFF59E0B),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: _tagOptions.map((t) {
                        final selected = _tags.contains(t);
                        final negative = AppConstants.negativeReviewTags
                            .contains(t);
                        final color = negative
                            ? const Color(0xFFDC2626)
                            : AppConstants.successColor;
                        return FilterChip(
                          label: Text(t),
                          selected: selected,
                          showCheckmark: false,
                          selectedColor: color.withValues(alpha: 0.14),
                          side: BorderSide(
                            color: selected ? color : const Color(0xFFE2E8F0),
                          ),
                          labelStyle: TextStyle(
                            color: selected
                                ? color
                                : AppConstants.secondaryDarkColor,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontSize: 12.5,
                          ),
                          onSelected: _isSubmitting
                              ? null
                              : (v) => setState(
                                  () => v ? _tags.add(t) : _tags.remove(t),
                                ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _reviewController,
                      enabled: !_isSubmitting,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 300,
                      decoration: InputDecoration(
                        hintText: 'Tell us more (optional)',
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              GradientButton(
                label: 'Submit Rating',
                icon: Icons.send_rounded,
                loading: _isSubmitting,
                onPressed: _submitRating,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isSubmitting ? null : _goHome,
                child: const Text('Skip & Return to Home'),
              ),
              if (_isSubmitting) const Center(child: WheelLoader(size: 22)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Text(label, style: const TextStyle(color: Color(0xFF64748B))),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppConstants.secondaryDarkColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
