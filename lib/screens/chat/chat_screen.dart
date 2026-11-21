import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/error_helper.dart';
import '../../models/assist_models.dart';
import '../../services/assist_service.dart';
import '../../services/booking_live.dart';
import '../../widgets/speedy_loader.dart';

/// In-app chat with the assigned mechanic — no phone numbers needed.
/// Realtime pings (private broadcast) refresh the thread instantly; a slow
/// poll is the safety net.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.bookingId,
    required this.mechanicId,
    required this.title,
  });

  final String bookingId;
  final String? mechanicId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final AssistService _service = AssistService();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<ChatMessage> _messages = const <ChatMessage>[];
  bool _open = true;
  bool _loading = true;
  bool _sending = false;
  Timer? _poll;
  BookingLive? _live;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(
      AppConstants.chatPollInterval,
      (_) => _load(silent: true),
    );
    _live = BookingLive(
      bookingId: widget.bookingId,
      onChat: () => _load(silent: true),
    )..bindMechanic(widget.mechanicId);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _live?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final thread = await _service.fetchThread(widget.bookingId);
      if (!mounted) return;
      final grew = thread.messages.length != _messages.length;
      setState(() {
        _messages = thread.messages;
        _open = thread.open;
        _loading = false;
      });
      if (grew) _toBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (!silent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(ErrorHelper.friendly(e))));
      }
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final msg = await _service.send(widget.bookingId, text);
      if (!mounted) return;
      HapticFeedback.selectionClick();
      _input.clear();
      setState(() {
        _messages = <ChatMessage>[..._messages, msg];
        _sending = false;
      });
      _toBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ErrorHelper.friendly(e))));
    }
  }

  String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 18,
              backgroundColor: AppConstants.primaryColor.withValues(
                alpha: 0.14,
              ),
              child: const Icon(
                Icons.engineering_rounded,
                color: AppConstants.primaryColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    _open
                        ? 'Messages are private to this booking'
                        : 'Chat closed',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: _loading
                ? const Center(child: WheelLoader(size: 40))
                : _messages.isEmpty
                ? _empty()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _bubble(_messages[i]),
                  ),
          ),
          if (_open) _composer() else _closedBar(),
        ],
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.forum_rounded,
              size: 56,
              color: AppConstants.primaryColor.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            const Text(
              'Say hello to your mechanic',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: AppConstants.secondaryDarkColor,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Share landmarks or ask for an update. For your safety, payment IDs and links are blocked in chat.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF64748B), height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(ChatMessage m) {
    final mine = m.senderRole == 'customer';
    final system = m.senderRole == 'system';
    if (system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE2E8F0),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            m.body,
            style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
          ),
        ),
      );
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.76,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          gradient: mine
              ? const LinearGradient(
                  colors: <Color>[Color(0xFFFF7A45), AppConstants.primaryColor],
                )
              : null,
          color: mine ? null : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                m.body,
                style: TextStyle(
                  color: mine ? Colors.white : AppConstants.secondaryDarkColor,
                  fontSize: 14.5,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _time(m.createdAt),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: mine ? Colors.white70 : const Color(0xFF94A3B8),
                  ),
                ),
                if (mine) ...<Widget>[
                  const SizedBox(width: 4),
                  Icon(
                    m.readAt != null
                        ? Icons.done_all_rounded
                        : Icons.done_rounded,
                    size: 14,
                    color: m.readAt != null ? Colors.white : Colors.white70,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: AppConstants.chatQuickReplies.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ActionChip(
                  label: Text(
                    AppConstants.chatQuickReplies[i],
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  onPressed: _sending
                      ? null
                      : () => _send(AppConstants.chatQuickReplies[i]),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 500,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Type a message',
                      counterText: '',
                      filled: true,
                      fillColor: const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: AppConstants.primaryColor,
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: WheelLoader(size: 20, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _closedBar() {
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: Colors.white,
        child: const Text(
          'This chat is closed because the booking has ended.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF64748B)),
        ),
      ),
    );
  }
}
