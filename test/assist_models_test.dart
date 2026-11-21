import 'package:eight_speedy_service/core/constants/app_constants.dart';
import 'package:eight_speedy_service/models/app_config_model.dart';
import 'package:eight_speedy_service/models/assist_models.dart';
import 'package:eight_speedy_service/models/booking_model.dart';
import 'package:eight_speedy_service/widgets/premium.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI assistant response parses and stays within bounds', () {
    final d = AssistDiagnosis.fromResponse(<String, dynamic>{
      'id': 'req-1',
      'engine': 'ai',
      'result': <String, dynamic>{
        'summary': 'Most likely a weak battery.',
        'urgency': 'medium',
        'safe_to_ride': false,
        'likely_causes': <Map<String, dynamic>>[
          <String, dynamic>{
            'title': 'Weak battery',
            'probability': 140,
            'explanation': 'Clicks only.',
          },
          <String, dynamic>{
            'title': '',
            'probability': 10,
            'explanation': 'dropped',
          },
        ],
        'suggested_issue_tags': <String>["Won't Start", 'Battery Dead'],
        'estimated_cost': <String, dynamic>{
          'min_inr': 100,
          'max_inr': 2150,
          'note': 'Mechanic confirms.',
        },
        'do_now': <String>['Switch off lights'],
        'avoid': <String>['Long cranking'],
        'questions_for_mechanic': <String>['Battery or starter?'],
        'diagnostic_steps': <String>[],
        'tools_and_parts': <String>[],
      },
    });
    expect(d.requestId, 'req-1');
    expect(d.isAi, isTrue);
    expect(d.likelyCauses, hasLength(1));
    expect(d.likelyCauses.first.probability, 100);
    expect(d.suggestedIssueTags, contains('Battery Dead'));
    expect(d.costMin, 100);
    expect(d.costMax, 2150);
    expect(d.isEmergency, isFalse);
  });

  test('expert-system answers are marked as not AI', () {
    final d = AssistDiagnosis.fromResponse(<String, dynamic>{
      'id': 'x',
      'engine': 'expert',
      'result': <String, dynamic>{
        'summary': 'Call 112',
        'urgency': 'emergency',
      },
    });
    expect(d.isAi, isFalse);
    expect(d.isEmergency, isTrue);
    expect(d.likelyCauses, isEmpty);
  });

  test('chat thread, saved place, mechanic card and catalog parse', () {
    final t = ChatThread.fromJson(<String, dynamic>{
      'open': true,
      'role': 'customer',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'm1',
          'sender_role': 'mechanic',
          'body': 'On my way',
          'created_at': '2026-11-21T03:00:00Z',
        },
      ],
    });
    expect(t.open, isTrue);
    expect(t.messages.single.senderRole, 'mechanic');

    final p = SavedPlace.fromJson(<String, dynamic>{
      'id': 'p',
      'label': 'Home',
      'address': 'Benachity',
      'lat': 23.5,
      'lng': 87.3,
    });
    expect(p.label, 'Home');
    expect(p.lat, 23.5);

    final c = MechanicCard.fromJson(<String, dynamic>{
      'name': 'Ravi',
      'rating': 4.7,
      'jobs_completed': 12,
      'top_tags': <String>['On time'],
    });
    expect(c.jobsCompleted, 12);
    expect(c.topTags, <String>['On time']);

    final o = IssueOption.fromJson(<String, dynamic>{
      'code': 'fuel',
      'label': 'Fuel Problem',
      'icon': 'local_gas_station',
      'categories': <String>['two_wheeler'],
    });
    expect(o.fits('two_wheeler'), isTrue);
    expect(o.fits('cycle_toto'), isFalse);
  });

  test('booking row exposes bill, OTP lock and AI summary', () {
    final b = BookingModel.fromJson(<String, dynamic>{
      'id': 'b1',
      'customer_id': 'c1',
      'status': 'ARRIVED',
      'issue_tags': <String>['Battery Dead'],
      'otp_attempts': 5,
      'repair_amount': 450,
      'repair_notes': 'Battery terminals cleaned',
      'review_tags': <String>['On time'],
      'ai_diagnosis': <String, dynamic>{'summary': 'Weak battery'},
      'accepted_at': '2026-11-21T03:00:00Z',
    });
    expect(b.otpLocked, isTrue);
    expect(b.repairAmount, 450);
    expect(b.aiSummary, 'Weak battery');
    expect(b.acceptedAt, isNotNull);
    final refreshed = b.copyWith(startOtp: '1234', otpAttempts: 0);
    expect(refreshed.otpLocked, isFalse);
    expect(refreshed.repairAmount, 450);
  });

  test('server message and Indian rupee formatting', () {
    final cfg = AppConfigModel.fromJson(<String, dynamic>{
      'service_message': '  Heavy rain: expect delays  ',
    });
    expect(cfg.serviceMessage, 'Heavy rain: expect delays');
    expect(
      AppConfigModel.fromJson(<String, dynamic>{'service_message': ' '})
          .serviceMessage,
      isNull,
    );
    expect(formatInr(950), '₹950');
    expect(formatInr(2150), '₹2,150');
    expect(formatInr(125000), '₹1,25,000');
  });

  test('fallback issue chips match the server catalog labels', () {
    expect(AppConstants.issueTags, contains("Won't Start"));
    expect(AppConstants.issueTags, contains('Key Lost / Lockout'));
    expect(
      AppConstants.issueTags.toSet(),
      hasLength(AppConstants.issueTags.length),
    );
  });
}
