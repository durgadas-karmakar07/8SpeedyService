import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/error_helper.dart';
import '../../models/customer_model.dart';
import '../../services/auth_service.dart';
import '../../services/booking_service.dart';

/// Displays the customer's referral code, remaining free booking credits,
/// and WhatsApp sharing actions.
class ReferEarnScreen extends StatefulWidget {
  const ReferEarnScreen({super.key});

  @override
  State<ReferEarnScreen> createState() => _ReferEarnScreenState();
}

class _ReferEarnScreenState extends State<ReferEarnScreen> {
  final AuthService _authService = AuthService();
  final BookingService _bookingService = BookingService();
  final TextEditingController _friendCodeController = TextEditingController();
  bool _isApplyingCode = false;

  @override
  void dispose() {
    _friendCodeController.dispose();
    super.dispose();
  }

  Future<void> _applyFriendCode() async {
    final code = _friendCodeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your friend\'s referral code.')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _isApplyingCode = true);
    try {
      await _bookingService.applyReferralCode(code);
      if (!mounted) return;
      _friendCodeController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Referral code applied! Your friend gets 1 free booking when your first booking is completed.',
          ),
        ),
      );
      await _loadProfile();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ErrorHelper.friendly(
              error,
              fallback: 'Could not apply the code. Please try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isApplyingCode = false);
    }
  }

  CustomerModel? _customer;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _isLoading = true);
    try {
      final profile = await _authService.fetchCustomerProfile();
      if (!mounted) return;
      setState(() {
        _customer = profile;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  String get _referralCode => _customer?.referralCode.trim() ?? '';

  Future<void> _copyCode() async {
    if (_referralCode.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _referralCode));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Referral code $_referralCode copied!')),
    );
  }

  Future<void> _shareViaWhatsApp() async {
    if (_referralCode.isEmpty) return;
    final message =
        'Vehicle broke down in Durgapur? Book a nearby verified mechanic with the 8SpeedyService app and track them live! ₹0 platform fee on your first 5 bookings. After signing up, enter my code in Refer & Earn: $_referralCode';
    final uri = Uri.parse(
      'https://wa.me/?text=${Uri.encodeComponent(message)}',
    );
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('WhatsApp could not be opened. Referral code copied!'),
          ),
        );
        await _copyCode();
      }
    } catch (_) {
      if (!mounted) return;
      await _copyCode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final freeLeft = _customer?.freeBookingsLeft ?? 0;

    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(title: const Text('Refer & Earn')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: <Color>[
                              AppConstants.primaryColor,
                              AppConstants.primaryDarkColor,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Column(
                          children: <Widget>[
                            const Icon(
                              Icons.card_giftcard_rounded,
                              color: Colors.white,
                              size: 56,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Share 8SpeedyService & Earn Free Bookings',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Help friends in Durgapur never stay stranded. Invite vehicle owners to enjoy ₹0 platform fee bookings.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13.5,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'Free Bookings Left: $freeLeft',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Your Referral Code',
                              style: TextStyle(
                                color: Colors.blueGrey.shade600,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: AppConstants.backgroundColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppConstants.primaryColor.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: <Widget>[
                                  SelectableText(
                                    _referralCode,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.5,
                                      color: AppConstants.secondaryDarkColor,
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: _copyCode,
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Copy'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: FilledButton.icon(
                                onPressed: _shareViaWhatsApp,
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppConstants.successColor,
                                ),
                                icon: const Icon(Icons.share_rounded),
                                label: const Text(
                                  'Invite via WhatsApp',
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_customer != null &&
                          (_customer!.referredBy ?? '').isEmpty) ...<Widget>[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'Invited by a friend? Enter their code',
                                style: TextStyle(
                                  color: Colors.blueGrey.shade600,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: TextField(
                                      controller: _friendCodeController,
                                      textCapitalization:
                                          TextCapitalization.characters,
                                      maxLength: 12,
                                      decoration: const InputDecoration(
                                        hintText: '8SPXXXXXX',
                                        counterText: '',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  FilledButton(
                                    onPressed: _isApplyingCode
                                        ? null
                                        : _applyFriendCode,
                                    child: _isApplyingCode
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Text('Apply'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Can be applied only before your first booking.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
