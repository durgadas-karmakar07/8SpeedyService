import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Live updates for one booking through PRIVATE Realtime Broadcast topics
/// (authorised on the server by RLS on realtime.messages):
///
///   `booking:{id}`                 -> 'booking'  (status changed)
///   `booking:{id}:m:{mechanicId}`  -> 'location' (mechanic moved), 'chat' (new message)
///
/// Broadcast scales far better than postgres_changes, and no payload carries
/// anything sensitive. Screens still poll slowly as a safety net, so a dropped
/// socket never leaves the customer stuck.
class BookingLive {
  BookingLive({
    required this.bookingId,
    this.onStatus,
    this.onLocation,
    this.onChat,
    SupabaseClient? client,
  }) : _clientOverride = client;

  final String bookingId;
  final void Function(Map<String, dynamic> payload)? onStatus;
  final void Function(double lat, double lng)? onLocation;
  final void Function()? onChat;
  final SupabaseClient? _clientOverride;

  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  RealtimeChannel? _statusChannel;
  RealtimeChannel? _pairChannel;
  String? _pairMechanicId;
  bool _disposed = false;

  static Map<String, dynamic> _unwrap(Map<String, dynamic> message) {
    final inner = message['payload'];
    if (inner is Map) return Map<String, dynamic>.from(inner);
    return message;
  }

  /// Subscribes to the booking's status topic.
  void start() {
    if (_disposed || _statusChannel != null) return;
    try {
      _statusChannel = _client
          .channel(
            'booking:$bookingId',
            opts: const RealtimeChannelConfig(private: true),
          )
          .onBroadcast(
            event: 'booking',
            callback: (m) => onStatus?.call(_unwrap(m)),
          )
          .subscribe();
    } catch (_) {
      // Realtime unavailable: the screen's polling keeps working.
    }
  }

  /// Subscribes to location + chat pings for the assigned mechanic.
  void bindMechanic(String? mechanicId) {
    if (_disposed ||
        mechanicId == null ||
        mechanicId.isEmpty ||
        mechanicId == _pairMechanicId) {
      return;
    }
    final old = _pairChannel;
    _pairChannel = null;
    if (old != null) unawaited(_client.removeChannel(old));
    _pairMechanicId = mechanicId;
    try {
      _pairChannel = _client
          .channel(
            'booking:$bookingId:m:$mechanicId',
            opts: const RealtimeChannelConfig(private: true),
          )
          .onBroadcast(
            event: 'location',
            callback: (m) {
              final p = _unwrap(m);
              final lat = (p['lat'] as num?)?.toDouble();
              final lng = (p['lng'] as num?)?.toDouble();
              if (lat != null && lng != null) onLocation?.call(lat, lng);
            },
          )
          .onBroadcast(event: 'chat', callback: (_) => onChat?.call())
          .subscribe();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    final channels = <RealtimeChannel?>[_statusChannel, _pairChannel];
    _statusChannel = null;
    _pairChannel = null;
    for (final c in channels) {
      if (c != null) {
        try {
          await _client.removeChannel(c);
        } catch (_) {}
      }
    }
  }
}
