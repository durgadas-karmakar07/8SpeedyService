/// Models for 8Speedy Assist (AI diagnosis), chat, saved places, the issue
/// catalog and the mechanic card.
library;

int _int(dynamic v, [int fallback = 0]) =>
    v is num ? v.toInt() : int.tryParse('$v') ?? fallback;

List<String> _strings(dynamic v) => v is List
    ? v.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList()
    : const <String>[];

DateTime? _date(dynamic raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

/// One likely cause in an AI diagnosis.
class LikelyCause {
  const LikelyCause({
    required this.title,
    required this.probability,
    required this.explanation,
  });

  factory LikelyCause.fromJson(Map<String, dynamic> json) => LikelyCause(
    title: json['title']?.toString() ?? '',
    probability: _int(json['probability']).clamp(1, 100),
    explanation: json['explanation']?.toString() ?? '',
  );

  final String title;
  final int probability;
  final String explanation;
}

/// Answer of the `ai-assistant` Edge Function.
class AssistDiagnosis {
  const AssistDiagnosis({
    required this.requestId,
    required this.isAi,
    required this.summary,
    required this.urgency,
    required this.safeToRide,
    required this.likelyCauses,
    required this.suggestedIssueTags,
    required this.costMin,
    required this.costMax,
    required this.costNote,
    required this.doNow,
    required this.avoid,
    required this.questions,
    this.diagnosticSteps = const <String>[],
    this.toolsAndParts = const <String>[],
  });

  factory AssistDiagnosis.fromResponse(Map<String, dynamic> json) {
    final r = json['result'] is Map
        ? Map<String, dynamic>.from(json['result'] as Map)
        : <String, dynamic>{};
    final cost = r['estimated_cost'] is Map
        ? Map<String, dynamic>.from(r['estimated_cost'] as Map)
        : <String, dynamic>{};
    final causes = r['likely_causes'] is List
        ? r['likely_causes'] as List
        : const <dynamic>[];
    return AssistDiagnosis(
      requestId: json['id']?.toString() ?? '',
      isAi: json['engine'] == 'ai',
      summary: r['summary']?.toString() ?? '',
      urgency: r['urgency']?.toString() ?? 'medium',
      safeToRide: r['safe_to_ride'] == true,
      likelyCauses: causes
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => LikelyCause.fromJson(Map<String, dynamic>.from(e)))
          .where((c) => c.title.isNotEmpty)
          .toList(),
      suggestedIssueTags: _strings(r['suggested_issue_tags']),
      costMin: _int(cost['min_inr']),
      costMax: _int(cost['max_inr']),
      costNote: cost['note']?.toString() ?? '',
      doNow: _strings(r['do_now']),
      avoid: _strings(r['avoid']),
      questions: _strings(r['questions_for_mechanic']),
      diagnosticSteps: _strings(r['diagnostic_steps']),
      toolsAndParts: _strings(r['tools_and_parts']),
    );
  }

  final String requestId;

  /// True when Claude answered; false for the built-in expert system.
  final bool isAi;
  final String summary;
  final String urgency;
  final bool safeToRide;
  final List<LikelyCause> likelyCauses;
  final List<String> suggestedIssueTags;
  final int costMin;
  final int costMax;
  final String costNote;
  final List<String> doNow;
  final List<String> avoid;
  final List<String> questions;
  final List<String> diagnosticSteps;
  final List<String> toolsAndParts;

  bool get isEmergency => urgency == 'emergency';
}

/// A chip from the server-driven `issue_catalog`.
class IssueOption {
  const IssueOption({
    required this.code,
    required this.label,
    required this.icon,
    this.categories = const <String>[],
  });

  factory IssueOption.fromJson(Map<String, dynamic> json) => IssueOption(
    code: json['code']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    icon: json['icon']?.toString() ?? '',
    categories: _strings(json['categories']),
  );

  final String code;
  final String label;
  final String icon;
  final List<String> categories;

  bool fits(String category) =>
      categories.isEmpty || categories.contains(category);
}

/// In-app chat message between the customer and the assigned mechanic.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderRole,
    required this.body,
    required this.createdAt,
    this.readAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id']?.toString() ?? '',
    senderRole: json['sender_role']?.toString() ?? 'system',
    body: json['body']?.toString() ?? '',
    createdAt: _date(json['created_at']) ?? DateTime.now(),
    readAt: _date(json['read_at']),
  );

  final String id;
  final String senderRole;
  final String body;
  final DateTime createdAt;
  final DateTime? readAt;
}

/// Result of `get_booking_messages`.
class ChatThread {
  const ChatThread({
    required this.messages,
    required this.open,
    required this.role,
  });

  factory ChatThread.fromJson(Map<String, dynamic> json) => ChatThread(
    messages:
        (json['messages'] is List
                ? json['messages'] as List
                : const <dynamic>[])
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
    open: json['open'] == true,
    role: json['role']?.toString(),
  );

  final List<ChatMessage> messages;
  final bool open;
  final String? role;
}

/// Saved pickup place (Home / Work / ...).
class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.label,
    required this.address,
    required this.lat,
    required this.lng,
  });

  factory SavedPlace.fromJson(Map<String, dynamic> json) => SavedPlace(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? 'Place',
    address: json['address']?.toString() ?? '',
    lat: (json['lat'] as num?)?.toDouble() ?? 0,
    lng: (json['lng'] as num?)?.toDouble() ?? 0,
  );

  final String id;
  final String label;
  final String address;
  final double lat;
  final double lng;
}

/// Mechanic card shown to the customer during the job.
class MechanicCard {
  const MechanicCard({
    required this.name,
    required this.rating,
    required this.jobsCompleted,
    this.shopName,
    this.memberSince,
    this.topTags = const <String>[],
  });

  factory MechanicCard.fromJson(Map<String, dynamic> json) => MechanicCard(
    name: json['name']?.toString() ?? 'Mechanic Partner',
    shopName: json['shop_name']?.toString(),
    rating: (json['rating'] as num?)?.toDouble() ?? 5.0,
    jobsCompleted: _int(json['jobs_completed']),
    memberSince: _date(json['member_since']),
    topTags: _strings(json['top_tags']),
  );

  final String name;
  final String? shopName;
  final double rating;
  final int jobsCompleted;
  final DateTime? memberSince;
  final List<String> topTags;
}
