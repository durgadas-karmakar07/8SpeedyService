// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../core/constants/app_constants.dart';
import '../models/booking_model.dart';
import '../models/mechanic_model.dart';
import '../services/booking_service.dart';
import '4_home_map_screen.dart';
import '7_live_tracking_screen.dart';

/// Displays an animated pulsing radar over the pickup map while expanding
/// `get_nearby_mechanics` search radii (`3000m -> 6000m -> 10000m`) every 45s
/// and listening to the booking realtime stream for mechanic acceptance.
class SearchingRadarScreen extends StatefulWidget {
  const SearchingRadarScreen({
    super.key,
    required this.initialBooking,
  });

  final BookingModel initialBooking;

  @override
  State<SearchingRadarScreen> createState() => _SearchingRadarScreenState();
}

class _SearchingRadarScreenState extends State<SearchingRadarScreen>
    with SingleTickerProviderStateMixin {
  final BookingService _bookingService = BookingService();

  late final AnimationController _radarController;
  StreamSubscription<BookingModel?>? _bookingSub;
  Timer? _radiusTimer;

  late BookingModel _booking;
  List<MechanicModel> _nearbyMechanics = const <MechanicModel>[];
  int _radiusIndex = 0;
  bool _isCancelling = false;
  bool _hasNavigated = false;
  String? _searchStatusNote;

  int get _currentRadiusMeters => AppConstants.searchRadiiMeters[_radiusIndex];

  @override
  void initState() {
    super.initState();
    _booking = widget.initialBooking;
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _startBookingStream();
    _searchNearbyMechanics();
    _startRadiusExpansionTimer();
  }

  void _startBookingStream() {
    _bookingSub = _bookingService
        .streamBooking(_booking.id)
        .listen(
          (updated) {
            if (!mounted || updated == null || _hasNavigated) return;
            setState(() => _booking = updated);

            if (updated.status == AppConstants.statusAccepted ||
                updated.isArrived ||
                updated.isInProgress) {
              _hasNavigated = true;
              _stopSearching();
              Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => LiveTrackingScreen(
                    bookingId: updated.id,
                    initialBooking: updated,
                  ),
                ),
              );
            } else if (updated.isCancelled) {
              _hasNavigated = true;
              _stopSearching();
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute<void>(builder: (_) => const HomeMapScreen()),
                (_) => false,
              );
            }
          },
          onError: (_) {
            if (!mounted) return;
            setState(() {
              _searchStatusNote =
                  'Reconnecting to live booking status updates...';
            });
          },
        );
  }

  void _startRadiusExpansionTimer() {
    _radiusTimer = Timer.periodic(
      AppConstants.radarExpansionInterval,
      (timer) {
        if (!mounted || _hasNavigated) {
          timer.cancel();
          return;
        }
        if (_radiusIndex < AppConstants.searchRadiiMeters.length - 1) {
          setState(() {
            _radiusIndex += 1;
          });
        }
        _searchNearbyMechanics();
      },
    );
  }

  Future<void> _searchNearbyMechanics() async {
    try {
      final mechanics = await _bookingService.getNearbyMechanics(
        lat: _booking.pickupLat,
        lng: _booking.pickupLng,
        radiusMeters: _currentRadiusMeters,
        vehicleType: _booking.vehicleType,
      );
      if (!mounted || _hasNavigated) return;
      setState(() {
        _nearbyMechanics = mechanics;
        _searchStatusNote = mechanics.isEmpty
            ? 'Expanding search across ${_currentRadiusMeters ~/ 1000} km in Durgapur...'
            : 'Found ${mechanics.length} verified partner(s) within ${_currentRadiusMeters ~/ 1000} km';
      });
    } catch (_) {
      if (!mounted || _hasNavigated) return;
      setState(() {
        _searchStatusNote =
            'Broadcasting your request within ${_currentRadiusMeters ~/ 1000} km...';
      });
    }
  }

  Future<void> _cancelRequest() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Cancel Mechanic Request?'),
          content: const Text(
            'Are you sure you want to cancel this booking request?',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep Searching'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Cancel Request'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    setState(() => _isCancelling = true);

    try {
      await _bookingService.cancelBooking(_booking.id);
      if (!mounted) return;
      _hasNavigated = true;
      _stopSearching();
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeMapScreen()),
        (_) => false,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCancelling = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not cancel booking right now. Please retry.'),
        ),
      );
    }
  }

  void _stopSearching() {
    _radiusTimer?.cancel();
    _radiusTimer = null;
    _bookingSub?.cancel();
    _bookingSub = null;
  }

  @override
  void dispose() {
    _stopSearching();
    _radarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pickupPoint = LatLng(_booking.pickupLat, _booking.pickupLng);
    final vehicleOption = AppConstants.vehicleOptionForKey(
      _booking.vehicleType,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_isCancelling) {
          _cancelRequest();
        }
      },
      child: Scaffold(
        body: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                children: <Widget>[
                  FlutterMap(
                    options: MapOptions(
                      initialCenter: pickupPoint,
                      initialZoom: 14.2,
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                      ),
                    ),
                    children: <Widget>[
                      TileLayer(
                        urlTemplate: AppConstants.osmTileUrl,
                        userAgentPackageName:
                            AppConstants.osmUserAgentPackageName,
                      ),
                      MarkerLayer(
                        markers: <Marker>[
                          Marker(
                            point: pickupPoint,
                            width: 60,
                            height: 60,
                            child: const Icon(
                              Icons.location_pin,
                              color: AppConstants.primaryColor,
                              size: 42,
                            ),
                          ),
                          ..._nearbyMechanics
                              .where((m) => m.hasValidCoordinates)
                              .map(
                                (mech) => Marker(
                                  point: LatLng(
                                    mech.currentLat,
                                    mech.currentLng,
                                  ),
                                  width: 38,
                                  height: 38,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: AppConstants.successColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.build_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ],
                  ),
                  IgnorePointer(
                    child: Container(
                      color: AppConstants.secondaryDarkColor.withValues(
                        alpha: 0.22,
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: Center(
                      child: SizedBox(
                        width: 240,
                        height: 240,
                        child: AnimatedBuilder(
                          animation: _radarController,
                          builder: (context, _) {
                            return CustomPaint(
                              painter: _RadarPulsePainter(
                                progress: _radarController.value,
                                color: AppConstants.primaryColor,
                              ),
                              child: Center(
                                child: Container(
                                  width: 58,
                                  height: 58,
                                  decoration: BoxDecoration(
                                    color: AppConstants.primaryColor,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 3,
                                    ),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: AppConstants.primaryColor
                                            .withValues(alpha: 0.4),
                                        blurRadius: 16,
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    vehicleOption.icon,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 18,
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
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: AppConstants.primaryColor.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'Radius: ${_currentRadiusMeters ~/ 1000} km',
                            style: const TextStyle(
                              color: AppConstants.primaryColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'OTP: ${_booking.startOtp}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppConstants.secondaryDarkColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Finding Nearby Verified Mechanics...',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppConstants.secondaryDarkColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _searchStatusNote ??
                          'Contacting mechanics within ${_currentRadiusMeters ~/ 1000} km of your pickup point.',
                      style: TextStyle(
                        color: Colors.blueGrey.shade700,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        const Icon(
                          Icons.location_on_outlined,
                          size: 16,
                          color: Colors.blueGrey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _booking.pickupAddress,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.blueGrey.shade600,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(
                      color: AppConstants.primaryColor,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 50,
                      child: OutlinedButton.icon(
                        onPressed: _isCancelling ? null : _cancelRequest,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                          side: BorderSide(color: Colors.red.shade300),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: _isCancelling
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.close_rounded),
                        label: Text(
                          _isCancelling ? 'Cancelling...' : 'Cancel Request',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
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
      ),
    );
  }
}

class _RadarPulsePainter extends CustomPainter {
  const _RadarPulsePainter({
    required this.progress,
    required this.color,
  });

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    for (var i = 0; i < 3; i++) {
      final waveProgress = (progress + i / 3) % 1.0;
      final radius = 28 + (maxRadius - 28) * waveProgress;
      final opacity = (1.0 - waveProgress).clamp(0.0, 1.0) * 0.45;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RadarPulsePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
