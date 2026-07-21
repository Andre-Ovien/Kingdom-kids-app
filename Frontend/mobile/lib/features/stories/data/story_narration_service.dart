import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../../core/errors/app_exception.dart';
import '../domain/story_detail.dart';

typedef NarrationErrorCallback = void Function(String message);
typedef NarrationProgressCallback =
    void Function(String text, int startOffset, int endOffset, String word);

abstract interface class StoryNarrationService {
  void setCallbacks({
    VoidCallback? onStarted,
    VoidCallback? onCompleted,
    VoidCallback? onPaused,
    VoidCallback? onCancelled,
    NarrationErrorCallback? onError,
    NarrationProgressCallback? onProgress,
  });

  Future<void> speak({required String text, required StoryNarration narration});

  Future<void> pause();

  Future<void> stop();

  Future<void> dispose();
}

/// Uses voices already installed on the device, then applies the narrator's
/// backend-controlled pace and pitch to keep each character recognizable.
class DeviceStoryNarrationService implements StoryNarrationService {
  DeviceStoryNarrationService({FlutterTts? flutterTts})
    : _flutterTts = flutterTts ?? FlutterTts();

  final FlutterTts _flutterTts;
  bool _callbacksBound = false;

  @override
  void setCallbacks({
    VoidCallback? onStarted,
    VoidCallback? onCompleted,
    VoidCallback? onPaused,
    VoidCallback? onCancelled,
    NarrationErrorCallback? onError,
    NarrationProgressCallback? onProgress,
  }) {
    _flutterTts.setStartHandler(() => onStarted?.call());
    _flutterTts.setCompletionHandler(() => onCompleted?.call());
    _flutterTts.setPauseHandler(() => onPaused?.call());
    _flutterTts.setCancelHandler(() => onCancelled?.call());
    _flutterTts.setErrorHandler(
      (message) => onError?.call(message?.toString() ?? 'Narration stopped.'),
    );
    _flutterTts.setProgressHandler(
      (text, startOffset, endOffset, word) =>
          onProgress?.call(text, startOffset, endOffset, word),
    );
    _callbacksBound = true;
  }

  @override
  Future<void> speak({
    required String text,
    required StoryNarration narration,
  }) async {
    final readableText = text.trim();
    if (readableText.isEmpty) {
      throw const AppException('This story does not have narration text yet.');
    }
    if (!_callbacksBound) {
      setCallbacks();
    }

    try {
      await _flutterTts.awaitSpeakCompletion(false);
      await _flutterTts.setVolume(1);
      await _flutterTts.setSpeechRate(narration.speechRate.clamp(0.1, 1));
      await _flutterTts.setPitch(narration.pitch.clamp(0.5, 2));
      await _selectInstalledVoice(narration);
      final result = await _flutterTts.speak(readableText);
      if (result != 1) {
        throw const AppException(
          'Narration could not start on this device. Try another installed voice.',
        );
      }
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException(
        'Narration is not available on this device right now.',
      );
    }
  }

  Future<void> _selectInstalledVoice(StoryNarration narration) async {
    final rawVoices = await _flutterTts.getVoices;
    final voices = rawVoices is List
        ? rawVoices
              .whereType<Map>()
              .map(
                (voice) => voice.map(
                  (key, value) => MapEntry(key.toString(), value.toString()),
                ),
              )
              .where((voice) => _voiceLocale(voice).startsWith('en'))
              .toList(growable: false)
        : const <Map<String, String>>[];

    if (voices.isEmpty) {
      await _flutterTts.setLanguage(narration.locale);
      return;
    }

    final preferredLocales = <String>[
      narration.locale,
      'en-NG',
      'en-GB',
      'en-US',
    ];
    List<Map<String, String>> candidates = const [];
    for (final locale in preferredLocales) {
      candidates = voices
          .where(
            (voice) =>
                _voiceLocale(voice).toLowerCase() == locale.toLowerCase(),
          )
          .toList(growable: false);
      if (candidates.isNotEmpty) {
        break;
      }
    }
    if (candidates.isEmpty) {
      candidates = voices;
    }

    final sorted = [...candidates]
      ..sort((left, right) => _voiceName(left).compareTo(_voiceName(right)));
    final characterIndex = switch (narration.voiceKey) {
      'nia' => 1,
      'zuri' => 2,
      _ => 0,
    };
    final voice = sorted[characterIndex % sorted.length];
    final locale = voice['locale'] ?? narration.locale;
    final name = voice['name'];
    await _flutterTts.setLanguage(locale);
    if (name != null && name.isNotEmpty) {
      await _flutterTts.setVoice({'name': name, 'locale': locale});
    }
  }

  String _voiceLocale(Map<String, String> voice) {
    return (voice['locale'] ?? '').toLowerCase();
  }

  String _voiceName(Map<String, String> voice) {
    return voice['name'] ?? voice['identifier'] ?? '';
  }

  @override
  Future<void> pause() async {
    try {
      await _flutterTts.pause();
    } catch (_) {
      throw const AppException('Narration could not be paused.');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _flutterTts.stop();
    } catch (_) {
      throw const AppException('Narration could not be stopped.');
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _flutterTts.stop();
    } catch (_) {
      // The platform channel may already be gone while the app is closing.
    }
  }
}
