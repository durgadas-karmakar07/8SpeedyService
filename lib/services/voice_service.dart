import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';

enum MicPermission { granted, denied, blocked }

/// A finished local recording.
class VoiceClip {
  const VoiceClip({required this.path, required this.duration});

  final String path;
  final Duration duration;

  int get seconds => (duration.inMilliseconds / 1000).ceil().clamp(1, 90).toInt();
}

/// Player state reported by the native side.
class VoicePlayerEvent {
  const VoicePlayerEvent(this.state, this.source, this.durationMs);

  final String state; // loading | playing | paused | completed | stopped | error
  final String? source;
  final int durationMs;
}

/// Records / previews the customer's voice note on Android (MainActivity
/// channel) and uploads it to the private `voice-notes` bucket.
class VoiceService {
  VoiceService._() {
    _channel.setMethodCallHandler(_onNative);
  }

  static final VoiceService instance = VoiceService._();

  static const MethodChannel _channel = MethodChannel('com.speedyservice.customer/voice');

  final StreamController<String> _recorderEvents = StreamController<String>.broadcast();
  final StreamController<VoicePlayerEvent> _playerEvents =
      StreamController<VoicePlayerEvent>.broadcast();

  /// `limit` (max length reached) or `cancelled` (app went to background).
  Stream<String> get recorderEvents => _recorderEvents.stream;
  Stream<VoicePlayerEvent> get playerEvents => _playerEvents.stream;

  Future<dynamic> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'onRecordLimit':
        _recorderEvents.add('limit');
      case 'onRecordCancelled':
        _recorderEvents.add('cancelled');
      case 'onPlayer':
        final m = call.arguments;
        if (m is Map) {
          final d = m['durationMs'];
          _playerEvents.add(VoicePlayerEvent(
            m['state']?.toString() ?? 'stopped',
            m['source']?.toString(),
            d is num ? d.toInt() : 0,
          ));
        }
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Permission
  // ---------------------------------------------------------------------------

  Future<bool> hasMicPermission() async => await _invoke<bool>('hasMic') ?? false;

  Future<MicPermission> requestMicPermission() async {
    final s = await _invoke<String>('requestMic');
    return switch (s) {
      'granted' => MicPermission.granted,
      'blocked' => MicPermission.blocked,
      _ => MicPermission.denied,
    };
  }

  Future<void> openAppSettings() => _invoke<void>('openAppSettings');

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  Future<void> startRecording() async {
    await _channel.invokeMethod<String>('startRecording', <String, int>{
      'maxMs': AppConstants.voiceNoteMaxLength.inMilliseconds,
    });
  }

  /// Null when the clip was too short to be useful.
  Future<VoiceClip?> stopRecording() async {
    final m = await _invoke<Map<dynamic, dynamic>>('stopRecording');
    if (m == null || m['path'] == null) return null;
    final ms = m['durationMs'];
    return VoiceClip(
      path: m['path'].toString(),
      duration: Duration(milliseconds: ms is num ? ms.toInt() : 0),
    );
  }

  Future<void> cancelRecording() => _invoke<void>('cancelRecording');

  /// Microphone level 0..1 for the live waveform.
  Future<double> amplitude() async {
    final a = await _invoke<int>('amplitude') ?? 0;
    return (a / 32767).clamp(0.0, 1.0);
  }

  Future<void> deleteRecording(String path) => _invoke<void>('deleteRecording', path);

  // ---------------------------------------------------------------------------
  // Preview playback
  // ---------------------------------------------------------------------------

  Future<void> play(String path) => _invoke<void>('playFile', path);
  Future<void> pause() => _invoke<void>('pauseAudio');
  Future<void> resume() => _invoke<void>('resumeAudio');
  Future<void> stop() => _invoke<void>('stopAudio');

  Future<int> positionMs() async {
    final m = await _invoke<Map<dynamic, dynamic>>('audioPosition');
    final p = m?['positionMs'];
    return p is num ? p.toInt() : 0;
  }

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------

  /// Uploads [clip] for [bookingId] and links it to the booking. The server
  /// only accepts it for the customer's own, still active booking, and only
  /// the mechanics who can see that request are allowed to listen.
  Future<void> uploadForBooking({required String bookingId, required VoiceClip clip}) async {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) throw StateError('Please log in again.');

    final file = File(clip.path);
    final path = '$uid/${bookingId}_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await client.storage.from(AppConstants.voiceNoteBucket).upload(
          path,
          file,
          fileOptions: const FileOptions(contentType: 'audio/mp4', upsert: false),
        );
    await client.rpc<dynamic>(
      'customer_attach_voice_note',
      params: <String, dynamic>{
        'p_booking_id': bookingId,
        'p_path': path,
        'p_seconds': clip.seconds,
      },
    );
    // Sent -> remove the local copy.
    unawaited(deleteRecording(clip.path));
  }
}
