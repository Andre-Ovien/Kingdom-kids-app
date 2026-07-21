import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mobile/features/stories/data/story_narration_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forwards the full native TTS progress event', () {
    final flutterTts = FlutterTts();
    final service = DeviceStoryNarrationService(flutterTts: flutterTts);
    String? receivedText;
    int? receivedStartOffset;
    int? receivedEndOffset;
    String? receivedWord;

    service.setCallbacks(
      onProgress: (text, startOffset, endOffset, word) {
        receivedText = text;
        receivedStartOffset = startOffset;
        receivedEndOffset = endOffset;
        receivedWord = word;
      },
    );

    flutterTts.progressHandler?.call('David trusted God.', 6, 13, 'trusted');

    expect(receivedText, 'David trusted God.');
    expect(receivedStartOffset, 6);
    expect(receivedEndOffset, 13);
    expect(receivedWord, 'trusted');
  });

  test(
    'replacing callbacks prevents a stale progress listener from firing',
    () {
      final flutterTts = FlutterTts();
      final service = DeviceStoryNarrationService(flutterTts: flutterTts);
      var progressCalls = 0;

      service.setCallbacks(
        onProgress: (_, _, _, _) {
          progressCalls++;
        },
      );
      service.setCallbacks();

      flutterTts.progressHandler?.call('Noah built an ark.', 0, 4, 'Noah');

      expect(progressCalls, 0);
    },
  );
}
