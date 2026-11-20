import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/constants/app_constants.dart';
import '../services/voice_service.dart';

/// "Describe the problem in your voice" — optional voice note the customer
/// records before booking. Mechanics who see the request can listen to it.
class VoiceNoteRecorder extends StatefulWidget {
  const VoiceNoteRecorder({super.key, required this.onChanged, this.enabled = true});

  /// Called with the finished clip, or null when it was deleted.
  final ValueChanged<VoiceClip?> onChanged;
  final bool enabled;

  @override
  State<VoiceNoteRecorder> createState() => _VoiceNoteRecorderState();
}

enum _Mode { idle, recording, recorded }

class _VoiceNoteRecorderState extends State<VoiceNoteRecorder>
    with SingleTickerProviderStateMixin {
  final VoiceService _voice = VoiceService.instance;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  _Mode _mode = _Mode.idle;
  VoiceClip? _clip;
  final List<double> _levels = <double>[];
  Timer? _meter;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  bool _busy = false;

  // preview playback
  bool _playing = false;
  int _playPosMs = 0;
  Timer? _playTicker;
  StreamSubscription<VoicePlayerEvent>? _playerSub;
  StreamSubscription<String>? _recSub;

  @override
  void initState() {
    super.initState();
    _playerSub = _voice.playerEvents.listen(_onPlayer);
    _recSub = _voice.recorderEvents.listen((e) {
      if (e == 'limit') _stop();
      if (e == 'cancelled') _resetAfterCancel();
    });
  }

  @override
  void dispose() {
    _meter?.cancel();
    _playTicker?.cancel();
    _playerSub?.cancel();
    _recSub?.cancel();
    _pulse.dispose();
    if (_mode == _Mode.recording) _voice.cancelRecording();
    if (_playing) _voice.stop();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  Future<void> _start() async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    try {
      if (!await _voice.hasMicPermission()) {
        final p = await _voice.requestMicPermission();
        if (p != MicPermission.granted) {
          if (!mounted) return;
          if (p == MicPermission.blocked) {
            _askForSettings();
          } else {
            _snack('Microphone permission is needed to record a voice note.');
          }
          return;
        }
      }
      await _voice.startRecording();
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      _levels.clear();
      _startedAt = DateTime.now();
      _pulse.repeat();
      setState(() {
        _mode = _Mode.recording;
        _elapsed = Duration.zero;
      });
      _meter = Timer.periodic(const Duration(milliseconds: 110), (_) async {
        final level = await _voice.amplitude();
        if (!mounted || _mode != _Mode.recording) return;
        setState(() {
          _levels.add(level);
          if (_levels.length > 48) _levels.removeAt(0);
          _elapsed = DateTime.now().difference(_startedAt!);
        });
      });
    } on PlatformException catch (e) {
      _snack(e.message ?? 'Could not start recording.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (_mode != _Mode.recording) return;
    _meter?.cancel();
    _pulse.stop();
    final clip = await _voice.stopRecording();
    HapticFeedback.lightImpact();
    if (!mounted) return;
    if (clip == null) {
      setState(() => _mode = _Mode.idle);
      _snack('Too short — hold on a little longer while speaking.');
      return;
    }
    setState(() {
      _clip = clip;
      _mode = _Mode.recorded;
    });
    widget.onChanged(clip);
  }

  Future<void> _cancelRecording() async {
    _meter?.cancel();
    _pulse.stop();
    await _voice.cancelRecording();
    if (mounted) setState(() => _mode = _Mode.idle);
  }

  void _resetAfterCancel() {
    _meter?.cancel();
    _pulse.stop();
    if (mounted && _mode == _Mode.recording) setState(() => _mode = _Mode.idle);
  }

  Future<void> _delete() async {
    final c = _clip;
    if (_playing) await _voice.stop();
    if (c != null) await _voice.deleteRecording(c.path);
    if (!mounted) return;
    setState(() {
      _clip = null;
      _mode = _Mode.idle;
      _playing = false;
      _playPosMs = 0;
    });
    widget.onChanged(null);
  }

  // ---------------------------------------------------------------------------
  // Preview
  // ---------------------------------------------------------------------------

  void _onPlayer(VoicePlayerEvent e) {
    if (!mounted || e.source != _clip?.path) return;
    switch (e.state) {
      case 'playing':
        setState(() => _playing = true);
        _playTicker?.cancel();
        _playTicker = Timer.periodic(const Duration(milliseconds: 150), (_) async {
          final pos = await _voice.positionMs();
          if (mounted) setState(() => _playPosMs = pos);
        });
      case 'paused':
        _playTicker?.cancel();
        setState(() => _playing = false);
      case 'completed':
      case 'stopped':
      case 'error':
        _playTicker?.cancel();
        setState(() {
          _playing = false;
          _playPosMs = 0;
        });
    }
  }

  Future<void> _togglePlay() async {
    final c = _clip;
    if (c == null) return;
    if (_playing) {
      await _voice.pause();
    } else if (_playPosMs > 0) {
      await _voice.resume();
    } else {
      await _voice.play(c.path);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _askForSettings() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.mic_off_rounded, color: AppConstants.primaryColor),
        title: const Text('Microphone is blocked'),
        content: const Text(
          'To record a voice note, allow the Microphone permission for 8SpeedyService in Settings.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Not now')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _voice.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _mode == _Mode.recording ? const Color(0xFFFFF1EC) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _mode == _Mode.recording
              ? AppConstants.primaryColor
              : _mode == _Mode.recorded
                  ? AppConstants.successColor
                  : Colors.grey.shade200,
          width: _mode == _Mode.idle ? 1 : 1.5,
        ),
      ),
      child: switch (_mode) {
        _Mode.idle => _idle(),
        _Mode.recording => _recording(),
        _Mode.recorded => _recorded(),
      },
    );
  }

  Widget _idle() {
    return Row(
      children: <Widget>[
        _RoundButton(
          icon: Icons.mic_rounded,
          color: AppConstants.primaryColor,
          onTap: widget.enabled && !_busy ? _start : null,
          semantic: 'Record voice note',
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Explain the problem in your voice',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppConstants.secondaryDarkColor,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Optional • up to 60 sec • any language. Nearby mechanics can listen before they come.',
                style: TextStyle(fontSize: 12, color: Colors.blueGrey, height: 1.3),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _recording() {
    final max = AppConstants.voiceNoteMaxLength;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) => Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.4 + 0.6 * (1 - _pulse.value)),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Recording… speak now',
              style: TextStyle(fontWeight: FontWeight.w700, color: AppConstants.secondaryDarkColor),
            ),
            const Spacer(),
            Text(
              '${_fmt(_elapsed)} / ${_fmt(max)}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          width: double.infinity,
          child: CustomPaint(painter: _LiveWavePainter(List<double>.of(_levels))),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (_elapsed.inMilliseconds / max.inMilliseconds).clamp(0.0, 1.0),
            minHeight: 4,
            color: AppConstants.primaryColor,
            backgroundColor: Colors.grey.shade200,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            TextButton.icon(
              onPressed: _cancelRecording,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Cancel'),
              style: TextButton.styleFrom(foregroundColor: Colors.blueGrey.shade700),
            ),
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) => Transform.scale(
                scale: 1 + 0.06 * math.sin(_pulse.value * math.pi * 2),
                child: child,
              ),
              child: _RoundButton(
                icon: Icons.stop_rounded,
                color: Colors.red.shade600,
                onTap: _stop,
                semantic: 'Stop recording',
                size: 58,
              ),
            ),
            const SizedBox(width: 96),
          ],
        ),
      ],
    );
  }

  Widget _recorded() {
    final c = _clip!;
    final progress = c.duration.inMilliseconds == 0
        ? 0.0
        : (_playPosMs / c.duration.inMilliseconds).clamp(0.0, 1.0);
    return Row(
      children: <Widget>[
        _RoundButton(
          icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: AppConstants.successColor,
          onTap: _togglePlay,
          semantic: _playing ? 'Pause voice note' : 'Play voice note',
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.check_circle_rounded, size: 16, color: AppConstants.successColor),
                  const SizedBox(width: 4),
                  Text(
                    'Voice note ready • ${_fmt(c.duration)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppConstants.secondaryDarkColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  color: AppConstants.successColor,
                  backgroundColor: Colors.grey.shade200,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'It will be sent with your booking.',
                style: TextStyle(fontSize: 11.5, color: Colors.blueGrey),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Delete voice note',
          onPressed: widget.enabled ? _delete : null,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.semantic,
    this.size = 50,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final String semantic;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantic,
      child: Material(
        color: onTap == null ? Colors.grey.shade400 : color,
        shape: const CircleBorder(),
        elevation: 3,
        shadowColor: color.withValues(alpha: 0.5),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: size * 0.52),
          ),
        ),
      ),
    );
  }
}

/// Scrolling bars from the live microphone level.
class _LiveWavePainter extends CustomPainter {
  _LiveWavePainter(this.levels);

  final List<double> levels;

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 48;
    final gap = size.width / bars;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2, gap * 0.55);
    for (var i = 0; i < bars; i++) {
      final idx = levels.length - bars + i;
      final raw = idx >= 0 ? levels[idx] : 0.0;
      final v = math.sqrt(raw); // speech is quiet; sqrt makes it visible
      final h = math.max(3.0, size.height * v);
      final x = gap * (i + 0.5);
      paint.color = Color.lerp(
        const Color(0xFFFFB199),
        AppConstants.primaryColor,
        (i / bars),
      )!;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveWavePainter old) => true;
}
