import 'package:eight_speedy_service/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('VoiceClip rounds seconds up and keeps them in the allowed range', () {
    expect(const VoiceClip(path: 'a', duration: Duration(milliseconds: 900)).seconds, 1);
    expect(const VoiceClip(path: 'a', duration: Duration(milliseconds: 12100)).seconds, 13);
    expect(const VoiceClip(path: 'a', duration: Duration(minutes: 5)).seconds, 90);
  });
}
