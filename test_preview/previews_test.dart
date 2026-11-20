import 'package:eight_speedy_service/widgets/speedy_loader.dart';
import 'package:eight_speedy_service/widgets/voice_note_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'preview_helpers.dart';

Widget _frame(Widget child, {Color bg = const Color(0xFFFF5722)}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'Poppins', useMaterial3: true),
    home: Scaffold(backgroundColor: bg, body: Center(child: child)),
  );
}

void main() {
  setUpAll(loadPreviewFonts);

  testWidgets('splash loader', (tester) async {
    phoneSurface(tester, height: 520);
    await tester.pumpWidget(_frame(
      Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
        child: const RoadLoader(
          color: Color(0xFF1E293B),
          width: 220,
          messages: <String>['Starting the engine…', 'Checking your bookings…'],
        ),
      ),
    ));
    var elapsed = 0;
    for (final ms in <int>[350, 700, 1000, 1500]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/loader_gauge_$ms.png'));
    }
  });

  testWidgets('inline loaders', (tester) async {
    phoneSurface(tester, height: 300);
    await tester.pumpWidget(_frame(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const WheelLoader(size: 56),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFFF5722),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const DotsLoader(),
          ),
        ],
      ),
      bg: Colors.white,
    ));
    await tester.pump(const Duration(milliseconds: 420));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/loader_inline.png'));
  });

  testWidgets('voice note recorder (idle)', (tester) async {
    phoneSurface(tester, height: 260);
    await tester.pumpWidget(_frame(
      Padding(
        padding: const EdgeInsets.all(16),
        child: VoiceNoteRecorder(onChanged: (_) {}),
      ),
      bg: const Color(0xFFF8FAFC),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/voice_recorder_idle.png'));
  });
}
