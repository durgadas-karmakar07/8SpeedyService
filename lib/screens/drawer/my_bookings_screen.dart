import 'package:material_ui/material_ui.dart';

import '../../core/constants/app_constants.dart';
import '../../models/booking_model.dart';
import '../../services/booking_service.dart';
import '../../widgets/vehicle_widgets.dart';
import '../6_searching_radar_screen.dart';
import '../7_live_tracking_screen.dart';
import '../8_job_completed_screen.dart';
import '../../widgets/speedy_loader.dart';

/// Displays the customer's booking history and allows resuming active
/// bookings or rating completed services.
class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  final BookingService _bookingService = BookingService();

  List<BookingModel> _bookings = const <BookingModel>[];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadBookings();
  }

  Future<void> _loadBookings() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final list = await _bookingService.fetchCustomerBookings();
      if (!mounted) return;
      setState(() {
        _bookings = list;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Could not load your bookings. Pull down to retry.';
      });
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case AppConstants.statusSearching:
        return 'Searching';
      case AppConstants.statusAccepted:
        return 'On the way';
      case AppConstants.statusArrived:
        return 'Arrived';
      case AppConstants.statusInProgress:
        return 'In progress';
      case AppConstants.statusCompleted:
        return 'Completed';
      case AppConstants.statusCancelled:
        return 'Cancelled';
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case AppConstants.statusSearching:
        return AppConstants.primaryColor;
      case AppConstants.statusAccepted:
      case AppConstants.statusCompleted:
        return AppConstants.successColor;
      case AppConstants.statusArrived:
        return AppConstants.warningColor;
      case AppConstants.statusInProgress:
        return Colors.blue;
      case AppConstants.statusCancelled:
      default:
        return Colors.grey;
    }
  }

  void _onBookingTap(BookingModel booking) {
    if (booking.isSearching) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SearchingRadarScreen(initialBooking: booking),
        ),
      );
      return;
    }

    if (booking.isActive) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LiveTrackingScreen(
            bookingId: booking.id,
            initialBooking: booking,
          ),
        ),
      );
      return;
    }

    if (booking.isCompleted && booking.rating == null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => JobCompletedScreen(booking: booking),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(title: const Text('My Bookings')),
      body: RefreshIndicator(
        onRefresh: _loadBookings,
        child: _isLoading
            ? const Center(child: RoadLoader(messages: <String>['Loading your bookings…']))
            : _errorMessage != null
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: <Widget>[
                  const SizedBox(height: 80),
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 48,
                    color: AppConstants.primaryColor,
                  ),
                  const SizedBox(height: 12),
                  Text(_errorMessage!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton(
                      onPressed: _loadBookings,
                      child: const Text('Retry'),
                    ),
                  ),
                ],
              )
            : _bookings.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: <Widget>[
                  const SizedBox(height: 90),
                  Icon(
                    Icons.history_rounded,
                    size: 64,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No Bookings Yet',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppConstants.secondaryDarkColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your mechanic requests in ${AppConstants.cityName} will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.blueGrey.shade600),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _bookings.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final booking = _bookings[index];
                  final statusColor = _statusColor(booking.status);

                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _onBookingTap(booking),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              SizedBox(
                                width: 64,
                                child: VehicleImage(
                                  asset: booking.vehicleAsset,
                                  height: 40,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  booking.vehicleDisplayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AppConstants.secondaryDarkColor,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  _statusLabel(booking.status),
                                  style: TextStyle(
                                    color: statusColor,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (booking.issueTags.isNotEmpty) ...<Widget>[
                            Text(
                              booking.issueTags.join(' • '),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: AppConstants.secondaryDarkColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            booking.pickupAddress,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.blueGrey.shade600,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[
                              Text(
                                booking.isFreeOfferUsed
                                    ? 'Platform Fee: ₹0 (Free Offer)'
                                    : 'Platform Fee: ₹${booking.platformFee}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                  color: booking.isFreeOfferUsed
                                      ? AppConstants.successColor
                                      : AppConstants.secondaryDarkColor,
                                ),
                              ),
                              if (booking.rating != null)
                                Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.star_rounded,
                                      size: 16,
                                      color: Colors.amber.shade700,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '${booking.rating}/5',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ],
                                )
                              else if (booking.isActive)
                                const Text(
                                  'Tap to track →',
                                  style: TextStyle(
                                    color: AppConstants.primaryColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5,
                                  ),
                                )
                              else if (booking.isCompleted)
                                const Text(
                                  'Tap to rate →',
                                  style: TextStyle(
                                    color: AppConstants.primaryColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
