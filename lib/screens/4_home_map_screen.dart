// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/location_helper.dart';
import '../models/app_config_model.dart';
import '../models/customer_model.dart';
import '../services/auth_service.dart';
import '../services/booking_service.dart';
import '3_phone_login_screen.dart';
import '5_issue_summary_screen.dart';
import 'drawer/my_bookings_screen.dart';
import 'drawer/refer_earn_screen.dart';

/// Main booking entry screen featuring an interactive OpenStreetMap pickup pin,
/// live free-credits badge, navigation drawer, and vehicle type selector.
class HomeMapScreen extends StatefulWidget {
  const HomeMapScreen({super.key});

  @override
  State<HomeMapScreen> createState() => _HomeMapScreenState();
}

class _HomeMapScreenState extends State<HomeMapScreen> {
  final MapController _mapController = MapController();
  final AuthService _authService = AuthService();
  final BookingService _bookingService = BookingService();

  StreamSubscription<MapEvent>? _mapEventSub;
  Timer? _geocodeDebounce;

  LatLng _pickupCoords = const LatLng(
    AppConstants.defaultLat,
    AppConstants.defaultLng,
  );
  String _pickupAddress = AppConstants.defaultPickupAddress;
  String _selectedVehicleType = 'two_wheeler';

  CustomerModel? _customer;
  AppConfigModel _appConfig = AppConfigModel.defaults();

  bool _isLocating = false;
  bool _isResolvingAddress = false;
  bool _isDraggingMap = false;
  bool _isLoadingCredits = true;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _loadCustomerAndConfig();
    _locateUser(showMessages: false);
  }

  @override
  void dispose() {
    _geocodeDebounce?.cancel();
    _mapEventSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadCustomerAndConfig() async {
    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        _authService.fetchCustomerProfile(),
        _bookingService.fetchAppConfig(),
      ]);
      if (!mounted) return;
      setState(() {
        _customer = results[0] as CustomerModel?;
        _appConfig = results[1] as AppConfigModel;
        _isLoadingCredits = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingCredits = false);
    }
  }

  Future<void> _locateUser({bool showMessages = true}) async {
    if (_isLocating) return;
    setState(() => _isLocating = true);

    final result = await LocationHelper.getCurrentLocationWithAddress();
    if (!mounted) return;

    setState(() {
      _pickupCoords = result.coordinates;
      _pickupAddress = result.address;
      _isLocating = false;
    });

    if (_mapReady) {
      _mapController.move(result.coordinates, AppConstants.defaultMapZoom);
    }

    if (showMessages && result.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage!),
          action: result.permissionPermanentlyDenied
              ? SnackBarAction(
                  label: 'Settings',
                  onPressed: LocationHelper.openAppSettings,
                )
              : result.serviceDisabled
              ? SnackBarAction(
                  label: 'Enable GPS',
                  onPressed: LocationHelper.openLocationSettings,
                )
              : null,
        ),
      );
    }
  }

  void _onMapReady() {
    _mapReady = true;
    _mapController.move(_pickupCoords, AppConstants.defaultMapZoom);
    _mapEventSub?.cancel();
    _mapEventSub = _mapController.mapEventStream.listen((event) {
      if (event is MapEventMoveStart) {
        if (mounted && !_isDraggingMap) {
          setState(() => _isDraggingMap = true);
        }
      } else if (event is MapEventMoveEnd) {
        if (mounted && _isDraggingMap) {
          setState(() => _isDraggingMap = false);
        }
        _scheduleReverseGeocode(event.camera.center);
      }
    });
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    _pickupCoords = camera.center;
    if (hasGesture) {
      if (!_isDraggingMap) {
        setState(() => _isDraggingMap = true);
      }
      _scheduleReverseGeocode(camera.center);
    }
  }

  void _scheduleReverseGeocode(LatLng target) {
    _geocodeDebounce?.cancel();
    _geocodeDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      setState(() => _isResolvingAddress = true);
      final resolved = await LocationHelper.getAddressFromLatLng(
        target.latitude,
        target.longitude,
      );
      if (!mounted) return;
      setState(() {
        _pickupAddress = resolved;
        _isResolvingAddress = false;
        _isDraggingMap = false;
      });
    });
  }

  Future<void> _openWhatsAppSupport() async {
    final uri = Uri.parse(AppConstants.whatsappSupportUrl);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open WhatsApp on this device.'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to launch WhatsApp Support.'),
        ),
      );
    }
  }

  void _showTermsAndPrivacy() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Terms & Privacy Policy',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppConstants.secondaryDarkColor,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '• 8SpeedyService connects vehicle owners in Durgapur with independent verified roadside mechanics.\n'
                  '• Platform booking fee covers dispatch and live tracking. Repair labour & spare parts are settled directly with the mechanic (₹${_appConfig.minVisitCharge} minimum visit charge applies).\n'
                  '• Your GPS location and phone number are used solely to dispatch your mechanic and share arrival updates.',
                  style: TextStyle(
                    color: Colors.blueGrey.shade700,
                    height: 1.45,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse(AppConstants.termsAndPrivacyUrl);
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Read Full Policy Online'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Sign Out?'),
          content: const Text(
            'You will need to verify your +91 mobile number via OTP to sign back in.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Sign Out'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;
    await _authService.signOut();
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const PhoneLoginScreen()),
      (_) => false,
    );
  }

  Future<void> _proceedToIssueSummary() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => IssueSummaryScreen(
          vehicleType: _selectedVehicleType,
          pickupLat: _pickupCoords.latitude,
          pickupLng: _pickupCoords.longitude,
          pickupAddress: _pickupAddress,
          initialFreeBookingsLeft: _customer?.freeBookingsLeft ?? 0,
        ),
      ),
    );
    if (mounted) {
      _loadCustomerAndConfig();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final freeBookingsLeft = _customer?.freeBookingsLeft ?? 0;
    final hasFreeOffer = _appConfig.launchOfferActive && freeBookingsLeft > 0;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: const Text(
          AppConstants.appName,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ReferEarnScreen(),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: hasFreeOffer
                      ? AppConstants.successColor.withValues(alpha: 0.14)
                      : AppConstants.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: hasFreeOffer
                        ? AppConstants.successColor.withValues(alpha: 0.4)
                        : AppConstants.primaryColor.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.local_offer_rounded,
                      size: 15,
                      color: hasFreeOffer
                          ? AppConstants.successColor
                          : AppConstants.primaryColor,
                    ),
                    const SizedBox(width: 5),
                    _isLoadingCredits
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            'Free Left: $freeBookingsLeft',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12.5,
                              color: hasFreeOffer
                                  ? AppConstants.successColor
                                  : AppConstants.primaryDarkColor,
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: AppConstants.secondaryDarkColor,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const CircleAvatar(
                      radius: 26,
                      backgroundColor: AppConstants.primaryColor,
                      child: Icon(
                        Icons.person_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _customer?.fullName ?? '8SpeedyService Rider',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _customer?.phone.isNotEmpty == true
                          ? _customer!.phone
                          : (_authService.currentUser?.phone ??
                                AppConstants.cityName),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppConstants.primaryColor,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        'Free Left: $freeBookingsLeft',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.receipt_long_rounded),
                title: const Text('My Bookings'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const MyBookingsScreen(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.card_giftcard_rounded),
                title: const Text('Refer & Earn'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ReferEarnScreen(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.support_agent_rounded,
                  color: AppConstants.successColor,
                ),
                title: const Text('WhatsApp Support'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openWhatsAppSupport();
                },
              ),
              ListTile(
                leading: const Icon(Icons.policy_rounded),
                title: const Text('Terms & Privacy'),
                onTap: () {
                  Navigator.of(context).pop();
                  _showTermsAndPrivacy();
                },
              ),
              const Spacer(),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: Colors.red),
                title: const Text(
                  'Sign Out',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _confirmSignOut();
                },
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _pickupCoords,
                    initialZoom: AppConstants.defaultMapZoom,
                    minZoom: 5.0,
                    maxZoom: 18.0,
                    onMapReady: _onMapReady,
                    onPositionChanged: _onPositionChanged,
                  ),
                  children: <Widget>[
                    TileLayer(
                      urlTemplate: AppConstants.osmTileUrl,
                      userAgentPackageName:
                          AppConstants.osmUserAgentPackageName,
                    ),
                  ],
                ),
                IgnorePointer(
                  child: Center(
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 140),
                      offset: _isDraggingMap
                          ? const Offset(0, -0.22)
                          : const Offset(0, -0.1),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppConstants.secondaryDarkColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'Pickup Location',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.location_pin,
                            size: 46,
                            color: AppConstants.primaryColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 14,
                  right: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(
                          Icons.my_location_rounded,
                          color: AppConstants.primaryColor,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Text(
                                'DRAG MAP TO SET EXACT SPOT',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: AppConstants.primaryColor,
                                  letterSpacing: 0.6,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _isResolvingAddress
                                    ? 'Updating address...'
                                    : _pickupAddress,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppConstants.secondaryDarkColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 14,
                  right: 14,
                  child: ElevatedButton.icon(
                    onPressed: _isLocating ? null : () => _locateUser(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppConstants.secondaryDarkColor,
                      elevation: 4,
                      shadowColor: Colors.black26,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    icon: _isLocating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.gps_fixed_rounded,
                            color: AppConstants.primaryColor,
                            size: 20,
                          ),
                    label: const Text(
                      'Locate Me',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 16,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        'Select Your Vehicle',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppConstants.secondaryDarkColor,
                        ),
                      ),
                      Text(
                        hasFreeOffer
                            ? '₹0 Platform Fee'
                            : '15-min arrival',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: hasFreeOffer
                              ? AppConstants.successColor
                              : Colors.blueGrey.shade600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 2.35,
                        ),
                    itemCount: AppConstants.vehicleOptions.length,
                    itemBuilder: (context, index) {
                      final option = AppConstants.vehicleOptions[index];
                      final isSelected = option.key == _selectedVehicleType;
                      final fee = _appConfig.feeForVehicle(option.key);

                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          setState(() => _selectedVehicleType = option.key);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppConstants.primaryColor.withValues(
                                    alpha: 0.1,
                                  )
                                : AppConstants.backgroundColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected
                                  ? AppConstants.primaryColor
                                  : Colors.grey.shade300,
                              width: isSelected ? 1.8 : 1,
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                option.icon,
                                size: 26,
                                color: isSelected
                                    ? AppConstants.primaryColor
                                    : AppConstants.secondaryDarkColor,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      option.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: isSelected
                                            ? AppConstants.primaryDarkColor
                                            : AppConstants.secondaryDarkColor,
                                      ),
                                    ),
                                    Text(
                                      hasFreeOffer
                                          ? 'Fee ₹0 (was ₹$fee)'
                                          : 'Platform Fee ₹$fee',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: hasFreeOffer
                                            ? AppConstants.successColor
                                            : Colors.blueGrey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _proceedToIssueSummary,
                      icon: const Icon(Icons.build_circle_rounded),
                      label: Text(
                        'Book ${AppConstants.vehicleOptionForKey(_selectedVehicleType).title} Mechanic',
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
