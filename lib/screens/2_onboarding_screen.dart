// ignore_for_file: file_names

import 'package:material_ui/material_ui.dart';

import '../core/constants/app_constants.dart';
import '../services/auth_service.dart';
import '3_phone_login_screen.dart';

/// Introduces 8SpeedyService's fast roadside repair service in Durgapur
/// and highlights the ₹0 platform fee launch offer.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  final AuthService _authService = AuthService();
  int _currentPage = 0;

  static const List<_OnboardingSlide> _slides = <_OnboardingSlide>[
    _OnboardingSlide(
      icon: Icons.bolt_rounded,
      title: 'Nearby Mechanic, Fast Arrival',
      description: 'Stranded in City Centre, Benachity, Bidhannagar, or anywhere in Durgapur? The nearest verified mechanic comes to your exact pin — track them live on the map.',
    ),
    _OnboardingSlide(
      icon: Icons.two_wheeler_rounded,
      title: 'Cycle, Toto, Bike, Car & Heavy',
      description: 'Puncture, starting trouble, dead battery, or brake issue — get specialized roadside assistance for every vehicle type.',
    ),
    _OnboardingSlide(
      icon: Icons.verified_user_rounded,
      title: 'Live Tracking & OTP Safety',
      description: 'Track your mechanic live on the map, call directly, and share your 4-digit Start OTP only when repairs begin.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _goToPhoneLogin() async {
    await _authService.markOnboardingSeen();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const PhoneLoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppConstants.primaryColor,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.build_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppConstants.appName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppConstants.secondaryDarkColor,
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: _goToPhoneLogin,
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: <Color>[
                    AppConstants.primaryColor,
                    AppConstants.primaryDarkColor,
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AppConstants.primaryColor.withValues(alpha: 0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Row(
                children: <Widget>[
                  Icon(
                    Icons.local_offer_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'LAUNCH OFFER: First 5 Bookings Platform Fee ₹0',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _slides.length,
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                },
                itemBuilder: (context, index) {
                  final slide = _slides[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            color: AppConstants.primaryColor.withValues(
                              alpha: 0.12,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            slide.icon,
                            size: 70,
                            color: AppConstants.primaryColor,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          slide.title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppConstants.secondaryDarkColor,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          slide.description,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: Colors.blueGrey.shade700,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List<Widget>.generate(_slides.length, (index) {
                final isSelected = index == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: isSelected ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppConstants.primaryColor
                        : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: () {
                    if (_currentPage < _slides.length - 1) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutCubic,
                      );
                    } else {
                      _goToPhoneLogin();
                    }
                  },
                  icon: Icon(
                    _currentPage < _slides.length - 1
                        ? Icons.arrow_forward_rounded
                        : Icons.login_rounded,
                  ),
                  label: Text(
                    _currentPage < _slides.length - 1
                        ? 'Next'
                        : 'Continue with Mobile Number',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingSlide {
  const _OnboardingSlide({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}
