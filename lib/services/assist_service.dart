import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/assist_models.dart';

/// 8Speedy Assist (AI diagnosis), in-app chat and saved places.
class AssistService {
  AssistService({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  static String _error(dynamic data, String fallback) =>
      data is Map && data['error'] is String
      ? data['error'] as String
      : fallback;

  /// Asks the `ai-assistant` Edge Function. The server reads the saved vehicle
  /// itself and stores the answer, so it can later be linked to the booking.
  Future<AssistDiagnosis> diagnose({
    required String? vehicleId,
    required Map<String, dynamic> vehicle,
    required List<String> issueTags,
    required String description,
    String language = 'en',
  }) async {
    try {
      final response = await _client.functions.invoke(
        'ai-assistant',
        body: <String, dynamic>{
          'mode': 'customer',
          'vehicle_id': vehicleId,
          'vehicle': vehicle,
          'issue_tags': issueTags,
          'description': description.trim(),
          'language': language,
        },
      );
      final data = response.data;
      if (data is Map && data['result'] is Map) {
        return AssistDiagnosis.fromResponse(Map<String, dynamic>.from(data));
      }
      throw StateError(_error(data, 'AI help is not available right now.'));
    } on FunctionException catch (e) {
      throw StateError(
        _error(e.details, 'AI help is not available right now.'),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Chat
  // ---------------------------------------------------------------------------

  Future<ChatThread> fetchThread(String bookingId) async {
    final dynamic data = await _client.rpc<dynamic>(
      'get_booking_messages',
      params: <String, dynamic>{'p_booking_id': bookingId},
    );
    if (data is Map) {
      return ChatThread.fromJson(Map<String, dynamic>.from(data));
    }
    return const ChatThread(messages: <ChatMessage>[], open: false, role: null);
  }

  Future<ChatMessage> send(String bookingId, String body) async {
    final dynamic data = await _client.rpc<dynamic>(
      'send_booking_message',
      params: <String, dynamic>{
        'p_booking_id': bookingId,
        'p_body': body.trim(),
      },
    );
    if (data is Map) {
      return ChatMessage.fromJson(Map<String, dynamic>.from(data));
    }
    throw StateError('Message could not be sent.');
  }

  // ---------------------------------------------------------------------------
  // Saved places
  // ---------------------------------------------------------------------------

  Future<List<SavedPlace>> fetchPlaces() async {
    final user = _client.auth.currentUser;
    if (user == null) return const <SavedPlace>[];
    final rows = await _client
        .from('customer_places')
        .select('id, label, address, lat, lng')
        .eq('customer_id', user.id)
        .order('updated_at', ascending: false);
    return rows.map(SavedPlace.fromJson).toList();
  }

  Future<SavedPlace> savePlace({
    required String label,
    required String address,
    required double lat,
    required double lng,
    String? placeId,
  }) async {
    final dynamic data = await _client.rpc<dynamic>(
      'customer_save_place',
      params: <String, dynamic>{
        'p_label': label.trim(),
        'p_address': address.trim(),
        'p_lat': lat,
        'p_lng': lng,
        'p_place_id': placeId,
      },
    );
    if (data is Map) {
      return SavedPlace.fromJson(Map<String, dynamic>.from(data));
    }
    throw StateError('Place could not be saved.');
  }

  Future<void> deletePlace(String placeId) async {
    await _client.rpc<dynamic>(
      'customer_delete_place',
      params: <String, dynamic>{'p_place_id': placeId},
    );
  }
}
