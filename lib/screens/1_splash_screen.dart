// ignore_for_file: file_names

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants/app_constants.dart';
import '../services/auth_service.dart';
import '../services/booking_service.dart';
import '2_onboarding_screen.dart';
import '3_phone_login_screen.dart';
import '4_home_map_screen.dart';
import '6_searching_radar_screen.dart';
import '7_live_tracking_screen.dart';

/// Branded launch screen that checks authentication state and restores any
/// ongoing mechanic booking before routing the customer.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final AuthService _authService = AuthService();
  final BookingService _bookingService = BookingService();

  String? _errorMessage;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    _bootstrapApp();
  }

  Future<void> _bootstrapApp() async {
    setState(() {
      _isChecking = true;
      _errorMessage = null;
    });

    try {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;

      if (await _isUpdateRequired()) {
        if (!mounted) return;
        await _showForceUpdateDialog();
        return;
      }
      if (!mounted) return;

      final session = _authService.currentSession;
      if (session == null) {
        _navigateTo(const OnboardingScreen());
        return;
      }

      final customer = await _authService.fetchCustomerProfile();
      if (!mounted) return;

      if (customer != null && customer.isBlocked) {
        await _authService.signOut();
        if (!mounted) return;
        _navigateTo(
          const PhoneLoginScreen(
            blockedNotice:
                'Your account has been restricted. Please contact 8SpeedyService support.',
          ),
        );
        return;
      }

      final activeBooking = await _bookingService.fetchActiveBooking();
      if (!mounted) return;

      if (activeBooking != null) {
        if (activeBooking.isSearching) {
          _navigateTo(SearchingRadarScreen(initialBooking: activeBooking));
        } else {
          _navigateTo(
            LiveTrackingScreen(
              bookingId: activeBooking.id,
              initialBooking: activeBooking,
            ),
          );
        }
        return;
      }

      _navigateTo(const HomeMapScreen());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isChecking = false;
        _errorMessage =
            'Unable to connect to 8SpeedyService servers. Please check your internet connection.';
      });
    }
  }

  /// Checks `app_config.min_android_version`; never blocks the app if the
  /// config cannot be loaded (weak network).
  Future<bool> _isUpdateRequired() async {
    try {
      final config = await _bookingService
          .fetchAppConfig()
          .timeout(const Duration(seconds: 6));
      return AppConstants.isVersionOlder(
        AppConstants.appVersion,
        config.minAndroidVersion,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _showForceUpdateDialog() async {
    setState(() => _isChecking = false);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('Update Required'),
            content: const Text(
              '8SpeedyService ka naya version aa gaya hai. Behtar aur safe service ke liye app update karein.',
            ),
            actions: <Widget>[
              FilledButton(
                onPressed: () {
                  launchUrl(
                    Uri.parse(AppConstants.playStoreUrl),
                    mode: LaunchMode.externalApplication,
                  );
                },
                child: const Text('Update Now'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _navigateTo(Widget screen) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppConstants.secondaryDarkColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: <Color>[
                        AppConstants.primaryColor,
                        AppConstants.primaryDarkColor,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: AppConstants.primaryColor.withValues(alpha: 0.4),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      Icon(
                        Icons.settings_rounded,
                        size: 72,
                        color: Colors.white24,
                      ),
                      Icon(
                        Icons.build_rounded,
                        size: 46,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  AppConstants.appName,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Durgapur • 15-Min On-Spot Mechanic',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 44),
                if (_isChecking) ...<Widget>[
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppConstants.primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Checking active bookings...',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ] else if (_errorMessage != null) ...<Widget>[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Column(
                      children: <Widget>[
                        const Icon(
                          Icons.wifi_off_rounded,
                          color: Colors.orangeAccent,
                          size: 30,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    _navigateTo(const HomeMapScreen()),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.white38),
                                ),
                                child: const Text('Open Map'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: _bootstrapApp,
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppConstants.primaryColor,
                                ),
                                child: const Text('Retry'),
                              ),
                            ),
                          ],
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
