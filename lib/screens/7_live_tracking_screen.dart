// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants/app_constants.dart';
import '../models/booking_model.dart';
import '../models/mechanic_model.dart';
import '../services/booking_service.dart';
import '4_home_map_screen.dart';
import '6_searching_radar_screen.dart';
import '8_job_completed_screen.dart';

/// Displays live mechanic location tracking over OpenStreetMap (top 60%)
/// and mechanic profile, call action, booking status, and Start OTP (bottom 40%).
class LiveTrackingScreen extends StatefulWidget {
  const LiveTrackingScreen({
    super.key,
    required this.bookingId,
    this.initialBooking,
  });

  final String bookingId;
  final BookingModel? initialBooking;

  @override
  State<LiveTrackingScreen> createState() => _LiveTrackingScreenState();
}

class _LiveTrackingScreenState extends State<LiveTrackingScreen> {
  final BookingService _bookingService = BookingService();
  final MapController _mapController = MapController();

  StreamSubscription<BookingModel?>? _bookingSub;
  StreamSubscription<MechanicModel?>? _mechanicSub;

  BookingModel? _booking;
  MechanicModel? _mechanic;
  String? _boundMechanicId;
  bool _mapReady = false;
  bool _hasCompletedNavigation = false;

  @override
  void initState() {
    super.initState();
    _booking = widget.initialBooking;
    _initStreams();
  }

  Future<void> _initStreams() async {
    if (_booking == null) {
      try {
        final fetched = await _bookingService.fetchBookingById(
          widget.bookingId,
        );
        if (mounted && fetched != null) {
          setState(() => _booking = fetched);
          _maybeBindMechanicStream(fetched.mechanicId);
        }
      } catch (_) {
        // Realtime stream below will still hydrate once connected.
      }
    } else {
      _maybeBindMechanicStream(_booking!.mechanicId);
    }

    _bookingSub = _bookingService
        .streamBooking(widget.bookingId)
        .listen(
          _onBookingUpdate,
          onError: (_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Live booking connection interrupted. Retrying...'),
              ),
            );
          },
        );
  }

  void _onBookingUpdate(BookingModel? updated) {
    if (!mounted || updated == null || _hasCompletedNavigation) return;

    setState(() => _booking = updated);
    _maybeBindMechanicStream(updated.mechanicId);

    if (updated.isCompleted) {
      _hasCompletedNavigation = true;
      _disposeStreams();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              JobCompletedScreen(booking: updated, mechanic: _mechanic),
        ),
      );
      return;
    }

    // Mechanic dropped the job before starting -> booking is back in search.
    if (updated.isSearching) {
      _hasCompletedNavigation = true;
      _disposeStreams();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Mechanic nahi aa paaye. Aapke liye dusra mechanic dhoondh rahe hain...',
          ),
        ),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => SearchingRadarScreen(initialBooking: updated),
        ),
      );
      return;
    }

    if (updated.isCancelled) {
      _hasCompletedNavigation = true;
      _disposeStreams();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This booking was cancelled.')),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeMapScreen()),
        (_) => false,
      );
    }
  }

  void _maybeBindMechanicStream(String? mechanicId) {
    if (mechanicId == null ||
        mechanicId.isEmpty ||
        mechanicId == _boundMechanicId) {
      return;
    }

    _boundMechanicId = mechanicId;
    _mechanicSub?.cancel();

    _bookingService.fetchMechanicById(mechanicId).then((mech) {
      if (!mounted || mech == null) return;
      setState(() => _mechanic = mech);
      _fitBounds();
    }).catchError((_) {});

    _mechanicSub = _bookingService
        .streamMechanic(mechanicId)
        .listen(
          (mech) {
            if (!mounted || mech == null) return;
            setState(() => _mechanic = mech);
            _fitBounds();
          },
          onError: (_) {
            // Keep tracking screen responsive on transient realtime socket drops.
          },
        );
  }

  void _fitBounds() {
    if (!_mapReady || _booking == null) return;

    final pickup = LatLng(_booking!.pickupLat, _booking!.pickupLng);
    final mech = _mechanic;
    if (mech != null && mech.hasValidCoordinates) {
      final mechPos = LatLng(mech.currentLat, mech.currentLng);
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: <LatLng>[pickup, mechPos],
          padding: const EdgeInsets.all(64),
          maxZoom: 16.5,
        ),
      );
    } else {
      _mapController.move(pickup, AppConstants.defaultMapZoom);
    }
  }

  Future<void> _callMechanic() async {
    final phone = _mechanic?.phone.trim() ?? '';
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mechanic phone number is not available yet.'),
        ),
      );
      return;
    }

    final uri = Uri(scheme: 'tel', path: phone);
    try {
      final launched = await launchUrl(uri);
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Dial $phone directly to reach mechanic.')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to launch dialer for $phone.')),
      );
    }
  }

  void _disposeStreams() {
    _bookingSub?.cancel();
    _bookingSub = null;
    _mechanicSub?.cancel();
    _mechanicSub = null;
  }

  @override
  void dispose() {
    _disposeStreams();
    _mapController.dispose();
    super.dispose();
  }

  String _distanceLabel(BookingModel booking, MechanicModel? mechanic) {
    if (mechanic == null || !mechanic.hasValidCoordinates) {
      return 'Locating mechanic...';
    }
    final meters = const Distance().as(
      LengthUnit.Meter,
      LatLng(booking.pickupLat, booking.pickupLng),
      LatLng(mechanic.currentLat, mechanic.currentLng),
    );
    if (meters < 1000) {
      return '${meters.round()} m away';
    }
    return '${(meters / 1000).toStringAsFixed(1)} km away';
  }

  _StatusMeta _statusMeta(String status) {
    switch (status) {
      case AppConstants.statusArrived:
        return const _StatusMeta(
          label: 'ARRIVED',
          subtitle: 'Mechanic has reached your pickup location',
          color: AppConstants.warningColor,
        );
      case AppConstants.statusInProgress:
        return const _StatusMeta(
          label: 'IN_PROGRESS',
          subtitle: 'Vehicle inspection & repair in progress',
          color: Colors.blue,
        );
      case AppConstants.statusAccepted:
      default:
        return const _StatusMeta(
          label: 'ACCEPTED',
          subtitle: 'Mechanic is heading to your location',
          color: AppConstants.successColor,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final booking = _booking;
    if (booking == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final theme = Theme.of(context);
    final pickupPoint = LatLng(booking.pickupLat, booking.pickupLng);
    final mechanic = _mechanic;
    final mechanicPoint = (mechanic != null && mechanic.hasValidCoordinates)
        ? LatLng(mechanic.currentLat, mechanic.currentLng)
        : null;
    final statusMeta = _statusMeta(booking.status);
    final otpDigits = booking.startOtp.isEmpty ? '----' : booking.startOtp;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Mechanic Tracking'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          IconButton(
            tooltip: 'Center Map',
            onPressed: _fitBounds,
            icon: const Icon(Icons.center_focus_strong_rounded),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 6,
            child: Stack(
              children: <Widget>[
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: pickupPoint,
                    initialZoom: AppConstants.defaultMapZoom,
                    onMapReady: () {
                      _mapReady = true;
                      _fitBounds();
                    },
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
                          width: 90,
                          height: 70,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppConstants.secondaryDarkColor,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'You',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.location_pin,
                                color: AppConstants.primaryColor,
                                size: 40,
                              ),
                            ],
                          ),
                        ),
                        if (mechanicPoint != null)
                          Marker(
                            point: mechanicPoint,
                            width: 110,
                            height: 74,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppConstants.successColor,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'Mechanic',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: AppConstants.successColor,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2.5,
                                    ),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.25,
                                        ),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.build_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.navigation_rounded,
                            color: AppConstants.primaryColor,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _distanceLabel(booking, mechanic),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: AppConstants.secondaryDarkColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 14,
                  right: 14,
                  child: Material(
                    color: Colors.white,
                    elevation: 4,
                    shadowColor: Colors.black26,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'Center Map',
                      color: AppConstants.secondaryDarkColor,
                      onPressed: _fitBounds,
                      icon: const Icon(Icons.my_location_rounded),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Container(
              width: double.infinity,
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
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
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
                              color: statusMeta.color.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.circle,
                                  size: 8,
                                  color: statusMeta.color,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  statusMeta.label,
                                  style: TextStyle(
                                    color: statusMeta.color,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              statusMeta.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.blueGrey.shade700,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          CircleAvatar(
                            radius: 26,
                            backgroundColor: AppConstants.primaryColor
                                .withValues(alpha: 0.14),
                            backgroundImage:
                                (mechanic?.avatarUrl != null &&
                                    mechanic!.avatarUrl!.isNotEmpty)
                                ? NetworkImage(mechanic.avatarUrl!)
                                : null,
                            child:
                                (mechanic?.avatarUrl == null ||
                                    mechanic!.avatarUrl!.isEmpty)
                                ? const Icon(
                                    Icons.engineering_rounded,
                                    color: AppConstants.primaryColor,
                                    size: 28,
                                  )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Flexible(
                                      child: Text(
                                        mechanic?.fullName ??
                                            'Assigning Mechanic...',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              color: AppConstants
                                                  .secondaryDarkColor,
                                            ),
                                      ),
                                    ),
                                    if (mechanic != null) ...<Widget>[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.amber.shade50,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Icon(
                                              Icons.star_rounded,
                                              size: 14,
                                              color: Colors.amber.shade700,
                                            ),
                                            const SizedBox(width: 2),
                                            Text(
                                              mechanic.rating.toStringAsFixed(
                                                1,
                                              ),
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  mechanic?.shopName ??
                                      '8SpeedyService Partner Garage',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.blueGrey.shade700,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (mechanic?.isVerified ?? true)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppConstants.successColor
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Icon(
                                          Icons.verified_rounded,
                                          size: 14,
                                          color: AppConstants.successColor,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          'Verified Partner',
                                          style: TextStyle(
                                            color: AppConstants.successColor,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 11.5,
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
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: FilledButton.icon(
                          onPressed: _callMechanic,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppConstants.successColor,
                          ),
                          icon: const Icon(Icons.call_rounded, size: 18),
                          label: const Text(
                            'Call Mechanic',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppConstants.secondaryDarkColor,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'START OTP',
                                    style: TextStyle(
                                      color: Colors.orangeAccent,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    'Share with mechanic when repair begins',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                otpDigits.split('').join(' '),
                                style: const TextStyle(
                                  color: AppConstants.secondaryDarkColor,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 20,
                                  letterSpacing: 2,
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
        ],
      ),
    );
  }
}

class _StatusMeta {
  const _StatusMeta({
    required this.label,
    required this.subtitle,
    required this.color,
  });

  final String label;
  final String subtitle;
  final Color color;
}
