import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/stories/data/story_narration_service.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';

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

  test('does not expose a native TTS error to a child', () {
    final flutterTts = FlutterTts();
    final service = DeviceStoryNarrationService(flutterTts: flutterTts);
    String? receivedMessage;

    service.setCallbacks(onError: (message) => receivedMessage = message);

    flutterTts.errorHandler?.call(
      'Android TTS ERROR_SERVICE at com.example.Engine:404',
    );

    expect(receivedMessage, isNot(contains('Android')));
    expect(receivedMessage, isNot(contains('404')));
    expect(receivedMessage, contains('Tap play'));
  });

  group('installed voice resolution', () {
    test(
      'normalizes metadata and chooses the best exact-locale offline voice',
      () async {
        final flutterTts = _FakeFlutterTts(
          voices: [
            const {'name': 'Malformed without locale'},
            'not a voice map',
            const {
              'name': 'Network Premium',
              'locale': 'en_NG',
              'quality': 'premium',
              'network_required': true,
            },
            const {
              'name': 'Not Installed',
              'locale': 'en-NG',
              'quality': 'very high',
              'network_required': 0,
              'features': ['embeddedTts', 'notInstalled'],
            },
            const {
              'name': 'Local Normal',
              'identifier': 'voice.local.normal',
              'locale': 'en_ng',
              'quality': 'normal',
              'latency': 'normal',
              'network_required': '0',
            },
            const {
              'name': 'Local High',
              'identifier': 'voice.local.high',
              'locale': 'en-NG',
              'quality': 'HIGH',
              'latency': 'very_low',
              'network_required': false,
            },
            const {
              'name': 'British Premium',
              'identifier': 'voice.gb.premium',
              'locale': 'en-GB',
              'quality': 'premium',
              'network_required': 0,
            },
          ],
        );
        final service = DeviceStoryNarrationService(flutterTts: flutterTts);

        await service.speak(
          text: 'Nia reads gently.',
          narration: _narration(
            voiceKey: 'nia',
            locale: 'EN_ng',
            speechRate: 0.4,
            pitch: 1.04,
          ),
        );

        expect(flutterTts.getVoicesCalls, 1);
        expect(flutterTts.languageCalls, ['en-NG']);
        expect(flutterTts.voiceCalls, [
          {
            'name': 'Local High',
            'locale': 'en-NG',
            'identifier': 'voice.local.high',
          },
        ]);
        expect(flutterTts.spokenTexts, ['Nia reads gently.']);
        expect(flutterTts.speakFocusValues, [isTrue]);
        expect(flutterTts.speechRates, [0.4]);
        expect(flutterTts.pitches, [1.04]);
      },
    );

    test(
      'ranks locale before quality and uses a stable name tie-break',
      () async {
        final flutterTts = _FakeFlutterTts(
          voices: [
            const {
              'name': 'Zulu',
              'locale': 'en-GB',
              'quality': 'normal',
              'network_required': '0',
            },
            const {
              'name': 'Alpha',
              'locale': 'en-GB',
              'quality': 'normal',
              'network_required': '0',
            },
            const {
              'name': 'US Premium',
              'locale': 'en-US',
              'quality': 'premium',
              'network_required': '0',
            },
          ],
        );
        final service = DeviceStoryNarrationService(flutterTts: flutterTts);

        await service.speak(
          text: 'Kai reads.',
          narration: _narration(voiceKey: 'kai', locale: 'en-ZA'),
        );

        expect(flutterTts.voiceCalls.single['name'], 'Alpha');
        expect(flutterTts.voiceCalls.single['locale'], 'en-GB');
      },
    );

    test('caches one normalized catalog across narrators', () async {
      final flutterTts = _FakeFlutterTts(
        voices: [
          const {'name': 'British', 'locale': 'en-GB', 'network_required': 0},
          const {'name': 'American', 'locale': 'en-US', 'network_required': 0},
        ],
      );
      final service = DeviceStoryNarrationService(flutterTts: flutterTts);

      await service.speak(
        text: 'Kai reads.',
        narration: _narration(voiceKey: 'kai', locale: 'en-GB'),
      );
      flutterTts.voices = [
        const {
          'name': 'A newly installed voice',
          'locale': 'en-US',
          'network_required': 0,
        },
      ];
      await service.speak(
        text: 'Zuri reads.',
        narration: _narration(voiceKey: 'zuri', locale: 'en-US'),
      );

      expect(flutterTts.getVoicesCalls, 1);
      expect(flutterTts.voiceCalls.map((voice) => voice['name']), [
        'British',
        'American',
      ]);
    });

    test('allows null platform acknowledgements and requests focus', () async {
      final flutterTts = _FakeFlutterTts(
        voices: [
          const {
            'name': 'System Voice',
            'identifier': 'system.voice',
            'locale': 'en-US',
          },
        ],
        defaultLanguageResult: null,
        setVoiceResult: null,
      );
      final service = DeviceStoryNarrationService(flutterTts: flutterTts);

      await service.speak(
        text: 'Zuri reads.',
        narration: _narration(voiceKey: 'zuri', locale: 'en-US'),
      );

      expect(flutterTts.spokenTexts, ['Zuri reads.']);
      expect(flutterTts.speakFocusValues, [isTrue]);
      expect(flutterTts.voiceCalls.single, {
        'name': 'System Voice',
        'locale': 'en-US',
        'identifier': 'system.voice',
      });
    });

    test('falls back to the locale default when setVoice rejects', () async {
      final flutterTts = _FakeFlutterTts(
        voices: [
          const {
            'name': 'Stale Identifier',
            'identifier': 'voice.removed',
            'locale': 'en-GB',
            'network_required': 0,
          },
        ],
        setVoiceResult: 0,
      );
      final service = DeviceStoryNarrationService(flutterTts: flutterTts);

      await service.speak(
        text: 'Kai reads.',
        narration: _narration(voiceKey: 'kai', locale: 'en-GB'),
      );

      expect(flutterTts.languageCalls, ['en-GB', 'en-GB']);
      expect(flutterTts.voiceCalls, hasLength(1));
      expect(flutterTts.spokenTexts, ['Kai reads.']);
    });

    test(
      'rejects a catalog containing only network or uninstalled English voices',
      () async {
        final flutterTts = _FakeFlutterTts(
          voices: [
            const {
              'name': 'Cloud only',
              'locale': 'en-US',
              'network_required': '1',
            },
            const {
              'name': 'Download required',
              'locale': 'en-GB',
              'network_required': '0',
              'features': 'embeddedTts\tnot-installed',
            },
          ],
        );
        final service = DeviceStoryNarrationService(flutterTts: flutterTts);

        await expectLater(
          service.speak(
            text: 'Read offline.',
            narration: _narration(voiceKey: 'kai', locale: 'en-GB'),
          ),
          throwsA(
            isA<AppException>().having(
              (error) => error.message,
              'message',
              contains('offline English'),
            ),
          ),
        );

        expect(flutterTts.languageCalls, isEmpty);
        expect(flutterTts.voiceCalls, isEmpty);
        expect(flutterTts.spokenTexts, isEmpty);
      },
    );

    test(
      'falls back through normalized languages when catalog is unavailable',
      () async {
        final flutterTts = _FakeFlutterTts(
          voicesError: StateError('native inventory failed'),
          languageResults: {'en-NG': 0, 'en-GB': 1},
        );
        final service = DeviceStoryNarrationService(flutterTts: flutterTts);

        await service.speak(
          text: 'Nia reads.',
          narration: _narration(voiceKey: 'nia', locale: 'en_ng'),
        );

        expect(flutterTts.getVoicesCalls, 1);
        expect(flutterTts.languageCalls, ['en-NG', 'en-GB']);
        expect(flutterTts.voiceCalls, isEmpty);
        expect(flutterTts.spokenTexts, ['Nia reads.']);
      },
    );

    test('reports an accepted voice that still cannot start safely', () async {
      final flutterTts = _FakeFlutterTts(
        voices: [
          const {
            'name': 'System Voice',
            'locale': 'en-US',
            'network_required': 0,
          },
        ],
        speakResult: 0,
      );
      final service = DeviceStoryNarrationService(flutterTts: flutterTts);

      await expectLater(
        service.speak(
          text: 'Zuri reads.',
          narration: _narration(voiceKey: 'zuri', locale: 'en-US'),
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            contains('could not start'),
          ),
        ),
      );

      expect(flutterTts.speakFocusValues, [isTrue]);
    });

    test(
      'wraps native setup failures without exposing their details',
      () async {
        final flutterTts = _FakeFlutterTts(
          voices: [
            const {
              'name': 'System Voice',
              'locale': 'en-US',
              'network_required': 0,
            },
          ],
          languageError: StateError(
            'com.vendor.secret.Engine ERROR_SERVICE 404',
          ),
        );
        final service = DeviceStoryNarrationService(flutterTts: flutterTts);

        await expectLater(
          service.speak(
            text: 'Zuri reads.',
            narration: _narration(voiceKey: 'zuri', locale: 'en-US'),
          ),
          throwsA(
            isA<AppException>()
                .having(
                  (error) => error.message,
                  'message',
                  'Narration is not available on this device right now.',
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('vendor')),
                ),
          ),
        );

        expect(flutterTts.spokenTexts, isEmpty);
      },
    );

    test(
      'treats an explicit native pause rejection as a safe failure',
      () async {
        final service = DeviceStoryNarrationService(
          flutterTts: _FakeFlutterTts(pauseResult: 0),
        );

        await expectLater(
          service.pause(),
          throwsA(
            isA<AppException>().having(
              (error) => error.userMessage,
              'userMessage',
              'Narration could not be paused.',
            ),
          ),
        );
      },
    );
  });
}

StoryNarration _narration({
  required String voiceKey,
  required String locale,
  double speechRate = 0.45,
  double pitch = 1,
}) {
  return StoryNarration(
    avatarKey: switch (voiceKey) {
      'nia' => 'dove',
      'zuri' => 'rainbow',
      _ => 'lion',
    },
    voiceKey: voiceKey,
    characterName: switch (voiceKey) {
      'nia' => 'Nia',
      'zuri' => 'Zuri',
      _ => 'Kai',
    },
    voiceDescription: 'A friendly reading style',
    locale: locale,
    speechRate: speechRate,
    pitch: pitch,
    status: 'device_tts',
    audioAvailable: false,
  );
}

final class _FakeFlutterTts extends FlutterTts {
  _FakeFlutterTts({
    this.voices = const [],
    this.voicesError,
    this.defaultLanguageResult = 1,
    this.languageResults = const {},
    this.languageError,
    this.setVoiceResult = 1,
    this.speakResult = 1,
    this.pauseResult = 1,
  });

  Object? voices;
  final Object? voicesError;
  final Object? defaultLanguageResult;
  final Map<String, Object?> languageResults;
  final Object? languageError;
  final Object? setVoiceResult;
  final Object? speakResult;
  final Object? pauseResult;

  int getVoicesCalls = 0;
  final List<String> languageCalls = [];
  final List<Map<String, String>> voiceCalls = [];
  final List<String> spokenTexts = [];
  final List<bool> speakFocusValues = [];
  final List<double> speechRates = [];
  final List<double> pitches = [];

  @override
  Future<dynamic> get getVoices async {
    getVoicesCalls++;
    if (voicesError != null) throw voicesError!;
    return voices;
  }

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> setVolume(double volume) async => 1;

  @override
  Future<dynamic> setSpeechRate(double rate) async {
    speechRates.add(rate);
    return 1;
  }

  @override
  Future<dynamic> setPitch(double pitch) async {
    pitches.add(pitch);
    return 1;
  }

  @override
  Future<dynamic> setLanguage(String language) async {
    languageCalls.add(language);
    if (languageError != null) throw languageError!;
    return languageResults.containsKey(language)
        ? languageResults[language]
        : defaultLanguageResult;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    voiceCalls.add(Map<String, String>.unmodifiable(voice));
    return setVoiceResult;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spokenTexts.add(text);
    speakFocusValues.add(focus);
    return speakResult;
  }

  @override
  Future<dynamic> pause() async => pauseResult;
}
