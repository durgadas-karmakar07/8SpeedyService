// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/error_helper.dart';
import '../models/assist_models.dart';
import '../models/booking_model.dart';
import '../models/mechanic_model.dart';
import '../services/booking_live.dart';
import '../services/booking_service.dart';
import '../widgets/premium.dart';
import '../widgets/sos_sheet.dart';
import '../widgets/speedy_loader.dart';
import '4_home_map_screen.dart';
import '6_searching_radar_screen.dart';
import '8_job_completed_screen.dart';
import 'chat/chat_screen.dart';

/// Live tracking after a mechanic accepted: full-screen map with a draggable
/// sheet (status timeline, ETA, mechanic card, start OTP, call / chat / SOS /
/// cancel). Updates arrive over private Realtime Broadcast; a 10-second poll
/// is the safety net.
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

  BookingModel? _booking;
  MechanicModel? _mechanic;
  MechanicCard? _card;
  LatLng? _mechanicPos;
  BookingLive? _live;
  Timer? _poll;
  String? _boundMechanicId;
  bool _mapReady = false;
  bool _userMovedMap = false;
  bool _navigated = false;
  bool _busy = false;
  bool _chatUnread = false;

  @override
  void initState() {
    super.initState();
    _booking = widget.initialBooking;
    _live = BookingLive(
      bookingId: widget.bookingId,
      onStatus: (_) => _refresh(),
      onLocation: (lat, lng) {
        if (!mounted) return;
        setState(() => _mechanicPos = LatLng(lat, lng));
        _autoFit();
      },
      onChat: () {
        if (mounted) setState(() => _chatUnread = true);
      },
    )..start();
    _refresh();
    _poll = Timer.periodic(
      AppConstants.trackingPollInterval,
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _live?.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  Future<void> _refresh() async {
    if (_navigated) return;
    try {
      final b = await _bookingService.fetchBookingById(widget.bookingId);
      if (!mounted || b == null || _navigated) return;
      setState(() => _booking = b);
      _bindMechanic(b.mechanicId);
      _handleStatus(b);
    } catch (_) {
      // Weak network: keep showing the last known state.
    }
  }

  void _bindMechanic(String? mechanicId) {
    if (mechanicId == null || mechanicId.isEmpty) return;
    _live?.bindMechanic(mechanicId);
    final fresh = mechanicId != _boundMechanicId;
    _boundMechanicId = mechanicId;
    _bookingService
        .fetchMechanicById(mechanicId)
        .then((m) {
          if (!mounted || m == null) return;
          setState(() {
            _mechanic = m;
            if (m.hasValidCoordinates) {
              _mechanicPos = LatLng(m.currentLat, m.currentLng);
            }
          });
          _autoFit();
        })
        .catchError((_) {});
    if (fresh) {
      _bookingService
          .fetchMechanicCard(widget.bookingId)
          .then((c) {
            if (mounted && c != null) setState(() => _card = c);
          })
          .catchError((_) {});
    }
  }

  void _handleStatus(BookingModel b) {
    if (_navigated) return;
    if (b.isCompleted) {
      _navigated = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => JobCompletedScreen(booking: b, mechanic: _mechanic),
        ),
      );
    } else if (b.isSearching) {
      _navigated = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The mechanic could not come. Finding another mechanic for you…',
          ),
        ),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => SearchingRadarScreen(initialBooking: b),
        ),
      );
    } else if (b.isCancelled) {
      _navigated = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This booking was cancelled.')),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeMapScreen()),
        (_) => false,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Map
  // ---------------------------------------------------------------------------

  void _autoFit({bool force = false}) {
    if (!_mapReady || _booking == null || (_userMovedMap && !force)) return;
    final pickup = LatLng(_booking!.pickupLat, _booking!.pickupLng);
    final mech = _mechanicPos;
    try {
      if (mech != null) {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: <LatLng>[pickup, mech],
            padding: const EdgeInsets.fromLTRB(60, 120, 60, 380),
            maxZoom: 16.5,
          ),
        );
      } else {
        _mapController.move(pickup, AppConstants.defaultMapZoom);
      }
    } catch (_) {}
  }

  double? get _distanceMeters {
    final b = _booking;
    final m = _mechanicPos;
    if (b == null || m == null) return null;
    return const Distance().as(
      LengthUnit.Meter,
      LatLng(b.pickupLat, b.pickupLng),
      m,
    );
  }

  String get _etaLabel {
    final d = _distanceMeters;
    if (d == null) return 'Locating your mechanic…';
    if (d < 120) return 'Your mechanic is here';
    final minutes =
        (d / 1000 / AppConstants.cityAverageSpeedKmh * 60).ceil() + 1;
    final km = d < 1000
        ? '${d.round()} m'
        : '${(d / 1000).toStringAsFixed(1)} km';
    return '$km away • about $minutes min';
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _callMechanic() async {
    final phone = _mechanic?.phone.trim() ?? '';
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Phone number is not available yet — use the chat.'),
        ),
      );
      return;
    }
    try {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } catch (_) {}
  }

  Future<void> _openChat() async {
    final b = _booking;
    if (b == null) return;
    setState(() => _chatUnread = false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          bookingId: b.id,
          mechanicId: b.mechanicId,
          title: _card?.name ?? _mechanic?.fullName ?? 'Your mechanic',
        ),
      ),
    );
  }

  Future<void> _refreshOtp() async {
    final b = _booking;
    if (b == null || _busy) return;
    setState(() => _busy = true);
    try {
      final otp = await _bookingService.refreshStartOtp(b.id);
      if (!mounted) return;
      setState(() => _booking = b.copyWith(startOtp: otp, otpAttempts: 0));
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('New OTP: $otp — tell it to your mechanic.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(ErrorHelper.friendly(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final b = _booking;
    if (b == null) return;
    if (!b.isAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The mechanic has already reached. Please talk to them or contact support.',
          ),
        ),
      );
      return;
    }
    final reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Why do you want to cancel?',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppConstants.secondaryDarkColor,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'The mechanic is already on the way. Free booking credits are not returned after acceptance.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
              ),
            ),
            ...AppConstants.cancelReasons.map(
              (r) => ListTile(
                leading: const Icon(
                  Icons.radio_button_unchecked_rounded,
                  size: 20,
                ),
                title: Text(r),
                onTap: () => Navigator.of(ctx).pop(r),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _bookingService.cancelBookingWithReason(b.id, reason);
      if (!mounted) return;
      _navigated = true;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeMapScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ErrorHelper.friendly(e))));
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final booking = _booking;
    if (booking == null) {
      return const Scaffold(
        body: Center(
          child: RoadLoader(
            messages: <String>[
              'Connecting to your mechanic…',
              'Loading live map…',
            ],
          ),
        ),
      );
    }
    final pickup = LatLng(booking.pickupLat, booking.pickupLng);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute<void>(builder: (_) => const HomeMapScreen()),
            (_) => false,
          );
        }
      },
      child: Scaffold(
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: pickup,
                  initialZoom: AppConstants.defaultMapZoom,
                  onMapReady: () {
                    _mapReady = true;
                    _autoFit(force: true);
                  },
                  onPositionChanged: (_, hasGesture) {
                    if (hasGesture && !_userMovedMap) {
                      setState(() => _userMovedMap = true);
                    }
                  },
                ),
                children: <Widget>[
                  TileLayer(
                    urlTemplate: AppConstants.osmTileUrl,
                    userAgentPackageName: AppConstants.osmUserAgentPackageName,
                  ),
                  if (_mechanicPos != null)
                    PolylineLayer(
                      polylines: <Polyline>[
                        Polyline(
                          points: <LatLng>[_mechanicPos!, pickup],
                          strokeWidth: 4,
                          color: AppConstants.primaryColor.withValues(
                            alpha: 0.7,
                          ),
                          pattern: StrokePattern.dashed(
                            segments: const <double>[10, 8],
                          ),
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: <Marker>[
                      Marker(
                        point: pickup,
                        width: 64,
                        height: 64,
                        child: const _PickupMarker(),
                      ),
                      if (_mechanicPos != null)
                        Marker(
                          point: _mechanicPos!,
                          width: 70,
                          height: 70,
                          child: const _MechanicMarker(),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: <Widget>[
                    _roundButton(Icons.arrow_back_rounded, () {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute<void>(
                          builder: (_) => const HomeMapScreen(),
                        ),
                        (_) => false,
                      );
                    }),
                    const SizedBox(width: 10),
                    Expanded(child: _etaChip()),
                    const SizedBox(width: 10),
                    _roundButton(Icons.shield_rounded, () {
                      showSosSheet(
                        context,
                        pickupAddress: booking.pickupAddress,
                        lat: booking.pickupLat,
                        lng: booking.pickupLng,
                        mechanicName: _card?.name ?? _mechanic?.fullName,
                        vehicleName: booking.vehicleDisplayName,
                        bookingId: booking.id,
                      );
                    }, color: const Color(0xFFDC2626)),
                  ],
                ),
              ),
            ),
            DraggableScrollableSheet(
              initialChildSize: 0.5,
              minChildSize: 0.3,
              maxChildSize: 0.92,
              builder: (context, controller) => _sheet(booking, controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton(
    IconData icon,
    VoidCallback onTap, {
    Color color = AppConstants.secondaryDarkColor,
  }) {
    return Material(
      color: Colors.white,
      elevation: 6,
      shadowColor: Colors.black26,
      shape: const CircleBorder(),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: color),
      ),
    );
  }

  Widget _etaChip() {
    return GestureDetector(
      onTap: () {
        setState(() => _userMovedMap = false);
        _autoFit(force: true);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: softShadow(2),
        ),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.navigation_rounded,
              size: 18,
              color: AppConstants.primaryColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _etaLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: AppConstants.secondaryDarkColor,
                ),
              ),
            ),
            if (_userMovedMap)
              const Icon(
                Icons.center_focus_strong_rounded,
                size: 18,
                color: Color(0xFF64748B),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sheet(BookingModel b, ScrollController controller) {
    return Container(
      decoration: BoxDecoration(
        color: AppConstants.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: <Widget>[
          Center(
            child: Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _timeline(b),
          const SizedBox(height: 14),
          _mechanicCard(),
          const SizedBox(height: 12),
          _actions(b),
          const SizedBox(height: 14),
          _otpCard(b),
          if (b.aiSummary != null && b.aiSummary!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            PremiumCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.auto_awesome_rounded,
                    color: AppConstants.primaryColor,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'AI note for your mechanic: ${b.aiSummary}',
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          PremiumCard(
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.location_on_rounded,
                  color: AppConstants.primaryColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        b.vehicleDisplayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppConstants.secondaryDarkColor,
                        ),
                      ),
                      Text(
                        b.pickupAddress,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Repair & parts are paid directly to the mechanic after the work. Never pay in advance or share payment IDs in chat.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              color: Color(0xFF94A3B8),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeline(BookingModel b) {
    final steps = <(String, DateTime?, bool)>[
      ('Accepted', b.acceptedAt, true),
      ('Arrived', b.arrivedAt, b.isArrived || b.isInProgress || b.isCompleted),
      ('Repairing', b.startedAt, b.isInProgress || b.isCompleted),
      ('Done', b.completedAt, b.isCompleted),
    ];
    String time(DateTime? t) {
      if (t == null) return '';
      final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
      return '$h:${t.minute.toString().padLeft(2, '0')}';
    }

    final title = switch (b.status) {
      AppConstants.statusArrived => 'Your mechanic has arrived',
      AppConstants.statusInProgress => 'Repair in progress',
      _ => 'Mechanic is on the way',
    };
    return PremiumCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppConstants.secondaryDarkColor,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              for (var i = 0; i < steps.length; i++) ...<Widget>[
                Expanded(
                  child: Column(
                    children: <Widget>[
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: steps[i].$3 ? kBrandGradient : null,
                          color: steps[i].$3 ? null : const Color(0xFFE2E8F0),
                        ),
                        child: Icon(
                          steps[i].$3 ? Icons.check_rounded : Icons.circle,
                          size: steps[i].$3 ? 16 : 6,
                          color: steps[i].$3
                              ? Colors.white
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        steps[i].$1,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: steps[i].$3
                              ? AppConstants.secondaryDarkColor
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                      Text(
                        time(steps[i].$2),
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _mechanicCard() {
    final card = _card;
    final name = card?.name ?? _mechanic?.fullName ?? 'Assigning mechanic…';
    final shop = card?.shopName ?? _mechanic?.shopName;
    final rating = card?.rating ?? _mechanic?.rating ?? 5.0;
    return PremiumCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: kBrandGradient,
                ),
                child: const Icon(
                  Icons.engineering_rounded,
                  color: Colors.white,
                  size: 30,
                ),
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
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              color: AppConstants.secondaryDarkColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.verified_rounded,
                          size: 18,
                          color: Color(0xFF2563EB),
                        ),
                      ],
                    ),
                    if (shop != null && shop.isNotEmpty)
                      Text(
                        shop,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF64748B),
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.star_rounded,
                        color: Color(0xFFF59E0B),
                        size: 18,
                      ),
                      Text(
                        rating.toStringAsFixed(1),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppConstants.secondaryDarkColor,
                        ),
                      ),
                    ],
                  ),
                  if (card != null)
                    Text(
                      '${card.jobsCompleted} jobs',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF64748B),
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (card != null && card.topTags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: card.topTags
                  .map(
                    (t) => StatusPill(
                      label: t,
                      color: AppConstants.successColor,
                      icon: Icons.thumb_up_alt_rounded,
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actions(BookingModel b) {
    Widget action(
      IconData icon,
      String label,
      VoidCallback? onTap, {
      Color color = AppConstants.secondaryDarkColor,
      bool dot = false,
    }) {
      return Expanded(
        child: PremiumCard(
          padding: const EdgeInsets.symmetric(vertical: 12),
          onTap: onTap,
          child: Column(
            children: <Widget>[
              Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Icon(icon, color: color),
                  if (dot)
                    Positioned(
                      right: -3,
                      top: -3,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Color(0xFFDC2626),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        action(
          Icons.call_rounded,
          'Call',
          _callMechanic,
          color: AppConstants.successColor,
        ),
        const SizedBox(width: 10),
        action(
          Icons.chat_rounded,
          'Chat',
          _openChat,
          color: const Color(0xFF2563EB),
          dot: _chatUnread,
        ),
        const SizedBox(width: 10),
        action(
          Icons.close_rounded,
          'Cancel',
          _busy ? null : _cancel,
          color: const Color(0xFFDC2626),
        ),
      ],
    );
  }

  Widget _otpCard(BookingModel b) {
    final otp = b.startOtp.isEmpty ? '----' : b.startOtp;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: kNightGradient,
        borderRadius: BorderRadius.circular(22),
        boxShadow: softShadow(2),
      ),
      child: Column(
        children: <Widget>[
          const Text(
            'START OTP — share only when the mechanic is with you',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: otp.split('').map((d) {
              return Container(
                width: 50,
                height: 58,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  d,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }).toList(),
          ),
          if (b.otpAttempts > 0 && !b.isInProgress) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              b.otpLocked
                  ? 'The mechanic entered a wrong OTP 5 times. Create a new OTP and tell it to them.'
                  : 'The mechanic entered a wrong OTP ${b.otpAttempts} time(s).',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFED7AA),
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              onPressed: _busy ? null : _refreshOtp,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('New OTP'),
            ),
          ],
        ],
      ),
    );
  }
}

class _PickupMarker extends StatelessWidget {
  const _PickupMarker();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          Icons.location_on_rounded,
          color: AppConstants.primaryColor,
          size: 38,
        ),
      ],
    );
  }
}

class _MechanicMarker extends StatelessWidget {
  const _MechanicMarker();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppConstants.successColor.withValues(alpha: 0.18),
          ),
        ),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppConstants.successColor,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 8,
              ),
            ],
          ),
          child: const Icon(
            Icons.two_wheeler_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
      ],
    );
  }
}
