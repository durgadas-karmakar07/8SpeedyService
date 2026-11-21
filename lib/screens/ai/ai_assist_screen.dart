import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/error_helper.dart';
import '../../models/assist_models.dart';
import '../../models/customer_vehicle.dart';
import '../../services/assist_service.dart';
import '../../widgets/premium.dart';
import '../../widgets/speedy_loader.dart';
import '../../widgets/vehicle_widgets.dart';

/// "8Speedy Assist": the customer describes the problem in their own words
/// (English, Hindi or Bengali) and gets likely causes, urgency, a price range
/// and safety tips. Returns the [AssistDiagnosis] when the customer wants to
/// book with the suggested issues (the mechanic then sees the AI summary).
class AiAssistScreen extends StatefulWidget {
  const AiAssistScreen({
    super.key,
    required this.vehicle,
    this.initialTags = const <String>[],
    this.initialNote = '',
    this.issueOptions = const <String>[],
  });

  final CustomerVehicle vehicle;
  final List<String> initialTags;
  final String initialNote;

  /// Labels of the issue chips the customer can toggle.
  final List<String> issueOptions;

  @override
  State<AiAssistScreen> createState() => _AiAssistScreenState();
}

class _AiAssistScreenState extends State<AiAssistScreen> {
  final AssistService _service = AssistService();
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final Set<String> _tags = widget.initialTags.toSet();
  String _language = 'en';
  bool _loading = false;
  AssistDiagnosis? _result;

  static const List<String> _examples = <String>[
    'Self start pe sirf click aata hai',
    'Tyre puncture ho gaya, spare nahi hai',
    'Engine garam ho raha hai aur dhuan',
    'Brake soft lag raha hai',
  ];

  @override
  void initState() {
    super.initState();
    _text.text = widget.initialNote;
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<String> get _options {
    final list = widget.issueOptions.isNotEmpty
        ? widget.issueOptions
        : AppConstants.issueTags;
    return list.where((t) => t != 'Other').toList();
  }

  Future<void> _diagnose() async {
    FocusScope.of(context).unfocus();
    if (_tags.isEmpty && _text.text.trim().length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pick a problem or describe it in a few words.'),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    HapticFeedback.selectionClick();
    try {
      final v = widget.vehicle;
      final result = await _service.diagnose(
        vehicleId: v.id,
        vehicle: <String, dynamic>{
          'category': v.category,
          'body_type': v.bodyType,
          'brand': v.brand,
          'model': v.model,
          'fuel_type': v.fuelType,
        },
        issueTags: _tags.toList(),
        description: _text.text,
        language: _language,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      HapticFeedback.mediumImpact();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent * 0.42,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutCubic,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ErrorHelper.friendly(
              e,
              fallback: 'AI help is not available right now.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _call(String number) async {
    await launchUrl(Uri(scheme: 'tel', path: number));
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.auto_awesome_rounded,
              color: AppConstants.primaryColor,
              size: 22,
            ),
            SizedBox(width: 8),
            Text('8Speedy Assist'),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: <Widget>[
                  _heroCard(),
                  const SizedBox(height: 16),
                  _languagePicker(),
                  const SizedBox(height: 16),
                  const SectionTitle(
                    'What is happening?',
                    icon: Icons.build_circle_outlined,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _options.map((t) {
                      final selected = _tags.contains(t);
                      return FilterChip(
                        avatar: Icon(
                          issueIconForLabel(t),
                          size: 17,
                          color: selected
                              ? AppConstants.primaryColor
                              : const Color(0xFF64748B),
                        ),
                        label: Text(t),
                        selected: selected,
                        showCheckmark: false,
                        selectedColor: AppConstants.primaryColor.withValues(
                          alpha: 0.14,
                        ),
                        side: BorderSide(
                          color: selected
                              ? AppConstants.primaryColor
                              : const Color(0xFFE2E8F0),
                        ),
                        labelStyle: TextStyle(
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: selected
                              ? AppConstants.primaryDarkColor
                              : AppConstants.secondaryDarkColor,
                          fontSize: 13,
                        ),
                        onSelected: _loading
                            ? null
                            : (v) => setState(
                                () => v ? _tags.add(t) : _tags.remove(t),
                              ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _text,
                    enabled: !_loading,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 300,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      labelText: 'Describe it in your own words',
                      hintText: 'e.g. Scooty start nahi ho rahi, button dabane par tik-tik aawaz…',
                      alignLabelWithHint: true,
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _examples.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => ActionChip(
                        label: Text(
                          _examples[i],
                          style: const TextStyle(fontSize: 12),
                        ),
                        avatar: const Icon(Icons.north_west_rounded, size: 14),
                        onPressed: _loading
                            ? null
                            : () => setState(() => _text.text = _examples[i]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  GradientButton(
                    label: result == null ? 'Diagnose with AI' : 'Ask again',
                    icon: Icons.auto_awesome_rounded,
                    loading: _loading,
                    onPressed: _diagnose,
                  ),
                  if (_loading) ...<Widget>[
                    const SizedBox(height: 22),
                    const Center(
                      child: RoadLoader(
                        width: 200,
                        messages: <String>[
                          'Reading your symptoms…',
                          'Checking common faults…',
                          'Estimating the price…',
                        ],
                      ),
                    ),
                  ],
                  if (result != null && !_loading) ...<Widget>[
                    const SizedBox(height: 22),
                    ..._resultWidgets(result),
                  ],
                ],
              ),
            ),
            if (result != null && !_loading) _bottomBar(result),
          ],
        ),
      ),
    );
  }

  Widget _heroCard() {
    final v = widget.vehicle;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: kNightGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: softShadow(2),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 86,
            height: 66,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(16),
            ),
            child: VehicleImage(asset: v.asset, height: 54),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  v.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tell me what happened — I will find the likely cause, a fair price range and what to do right now.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _languagePicker() {
    return Row(
      children: <Widget>[
        const Icon(Icons.translate_rounded, size: 18, color: Color(0xFF64748B)),
        const SizedBox(width: 8),
        const Text(
          'Answer in',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF475569),
          ),
        ),
        const Spacer(),
        SegmentedButton<String>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'en', label: Text('English')),
            ButtonSegment<String>(value: 'hi', label: Text('हिंदी')),
            ButtonSegment<String>(value: 'bn', label: Text('বাংলা')),
          ],
          selected: <String>{_language},
          onSelectionChanged: _loading
              ? null
              : (s) => setState(() => _language = s.first),
        ),
      ],
    );
  }

  List<Widget> _resultWidgets(AssistDiagnosis r) {
    final color = urgencyColor(r.urgency);
    return <Widget>[
      if (r.isEmergency)
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFFCA5A5)),
          ),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.emergency_rounded,
                color: Color(0xFFDC2626),
                size: 30,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Safety first. If anyone is hurt or there is fire or smoke, call emergency services now.',
                  style: TextStyle(
                    color: Color(0xFF7F1D1D),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                ),
                onPressed: () => _call(AppConstants.emergencyNumber),
                child: const Text('Call 112'),
              ),
            ],
          ),
        ),
      PremiumCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                StatusPill(
                  label:
                      '${r.urgency[0].toUpperCase()}${r.urgency.substring(1)} urgency',
                  color: color,
                  icon: Icons.speed_rounded,
                ),
                const SizedBox(width: 8),
                StatusPill(
                  label: r.safeToRide ? 'OK to wait' : 'Don\'t ride',
                  color: r.safeToRide
                      ? AppConstants.successColor
                      : const Color(0xFFDC2626),
                  icon: r.safeToRide
                      ? Icons.verified_user_rounded
                      : Icons.do_not_disturb_on_rounded,
                ),
                const Spacer(),
                Icon(
                  r.isAi ? Icons.auto_awesome_rounded : Icons.menu_book_rounded,
                  size: 16,
                  color: const Color(0xFF94A3B8),
                ),
                const SizedBox(width: 4),
                Text(
                  r.isAi ? 'AI' : 'Expert guide',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              r.summary,
              style: const TextStyle(
                fontSize: 15,
                height: 1.45,
                fontWeight: FontWeight.w600,
                color: AppConstants.secondaryDarkColor,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      if (r.likelyCauses.isNotEmpty)
        PremiumCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionTitle(
                'Likely causes',
                icon: Icons.troubleshoot_rounded,
              ),
              ...r.likelyCauses.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              c.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: AppConstants.secondaryDarkColor,
                              ),
                            ),
                          ),
                          Text(
                            '${c.probability}%',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppConstants.primaryColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ProbabilityBar(value: c.probability),
                      if (c.explanation.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(
                          c.explanation,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF64748B),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 14),
      PremiumCard(
        color: const Color(0xFFFFFBF5),
        borderColor: const Color(0xFFFED7AA),
        child: Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppConstants.primaryColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.currency_rupee_rounded,
                color: AppConstants.primaryColor,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Estimated repair cost',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatInr(r.costMin)} – ${formatInr(r.costMax)}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppConstants.secondaryDarkColor,
                    ),
                  ),
                  if (r.costNote.isNotEmpty)
                    Text(
                      r.costNote,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF94A3B8),
                        height: 1.3,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      if (r.doNow.isNotEmpty) ...<Widget>[
        const SizedBox(height: 14),
        PremiumCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionTitle(
                'Do this now',
                icon: Icons.health_and_safety_rounded,
              ),
              BulletList(items: r.doNow),
            ],
          ),
        ),
      ],
      if (r.avoid.isNotEmpty) ...<Widget>[
        const SizedBox(height: 14),
        PremiumCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionTitle('Avoid', icon: Icons.block_rounded),
              BulletList(
                items: r.avoid,
                icon: Icons.cancel_rounded,
                color: const Color(0xFFDC2626),
              ),
            ],
          ),
        ),
      ],
      if (r.questions.isNotEmpty) ...<Widget>[
        const SizedBox(height: 14),
        PremiumCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionTitle(
                'Ask your mechanic',
                icon: Icons.question_answer_rounded,
              ),
              BulletList(
                items: r.questions,
                icon: Icons.help_rounded,
                color: AppConstants.secondaryDarkColor,
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 14),
      const Text(
        'AI suggestions can be wrong. Your mechanic checks the vehicle and confirms the problem and the price before starting any work.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8), height: 1.4),
      ),
    ];
  }

  Widget _bottomBar(AssistDiagnosis r) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: GradientButton(
        label: 'Use these issues & book',
        icon: Icons.build_circle_rounded,
        onPressed: () => Navigator.of(context).pop(r),
      ),
    );
  }
}
