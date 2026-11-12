import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/features/stories/data/story_narration_service.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';

const _body = 'David trusted God. He stepped forward.';
const _secondOffset = 19;
const _policy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.kingdom-kids.test/api',
  configuredHosts: 'audio.kingdom-kids.test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'player clock advances between passage cues and freezes during pause and buffering',
    () async {
      final player = _FakePlayer();
      final service = _service(player, _FakeFetcher());
      final positions = <(Duration, Duration?)>[];
      var passages = 0;
      service.setCallbacks(
        onPosition: (position, duration) => positions.add((position, duration)),
        onPassage: (_, _, _) => passages++,
      );
      await service.speak(text: _body, narration: _narration());
      player.advance(const Duration(milliseconds: 1234));
      player.advance(const Duration(milliseconds: 2710));
      expect(passages, 1);
      expect(positions.last, (
        const Duration(milliseconds: 2710),
        const Duration(seconds: 10),
      ));
      await service.pause();
      final pausedCount = positions.length;
      player._positions.add(const Duration(seconds: 9));
      expect(positions, hasLength(pausedCount));
      await service.speak(text: _body, narration: _narration(), resume: true);
      expect(positions.last.$1, const Duration(milliseconds: 2710));
      expect(player.seeks, [Duration.zero]);
      player._states.add(PlayerState(true, ProcessingState.buffering));
      final bufferingCount = positions.length;
      player._positions.add(const Duration(seconds: 8));
      expect(positions, hasLength(bufferingCount));
      player._states.add(PlayerState(true, ProcessingState.ready));
      player.advance(const Duration(milliseconds: 3200));
      expect(positions.last.$1, const Duration(milliseconds: 3200));
      await service.speak(
        text: _body.substring(_secondOffset),
        fullText: _body,
        narration: _narration(),
        startOffset: _secondOffset,
      );
      expect(player.seeks.last, const Duration(seconds: 5));
      expect(positions.last.$1, const Duration(seconds: 5));
      await service.dispose();
    },
  );

  test(
    'measured uneven word intervals highlight at their own pace and clear in silence',
    () async {
      final player = _FakePlayer();
      final service = _service(player, _FakeFetcher());
      final highlights = <String?>[];
      final heard = <(int, int)>[];
      service.setCallbacks(
        onWord: (word) => highlights.add(word?.text),
        onProgress: (_, start, end, _) => heard.add((start, end)),
      );
      await service.speak(
        text: _body,
        narration: _narration(words: _words),
      );
      expect(highlights, [null]);
      player.advance(const Duration(milliseconds: 900));
      expect(highlights, [null]);
      player.advance(const Duration(seconds: 1));
      expect(highlights.last, 'David');
      player.advance(const Duration(milliseconds: 1800));
      expect(highlights.last, isNull);
      player.advance(const Duration(milliseconds: 2200));
      expect(highlights.last, 'trusted');
      final count = highlights.length;
      player.advance(const Duration(milliseconds: 3400));
      expect(highlights, hasLength(count));
      player.advance(const Duration(milliseconds: 3600));
      expect(highlights.last, isNull);
      player.advance(const Duration(milliseconds: 4100));
      expect(highlights.last, 'God.');
      expect(heard, isEmpty);
      await service.pause();
      player._positions.add(const Duration(seconds: 9));
      expect(highlights.last, 'God.');
      await service.speak(
        text: _body,
        narration: _narration(words: _words),
        resume: true,
      );
      expect(highlights.last, 'God.');
      player.advance(const Duration(milliseconds: 4900));
      expect(highlights.last, isNull);
      player.advance(const Duration(seconds: 5));
      expect(heard, [(0, 18)]);
      await service.dispose();
    },
  );

  test(
    'invalid word cues preserve paragraph coverage without guessed word highlighting',
    () async {
      final player = _FakePlayer();
      final service = _service(player, _FakeFetcher());
      final highlights = <StoryNarrationSegment?>[];
      final heard = <(int, int)>[];
      service.setCallbacks(
        onWord: highlights.add,
        onProgress: (_, start, end, _) => heard.add((start, end)),
      );
      await service.speak(
        text: _body,
        narration: _narration(
          words: const [
            StoryNarrationSegment(
              text: 'Different',
              startOffset: 0,
              endOffset: 9,
              startTime: Duration.zero,
              endTime: Duration(seconds: 1),
            ),
          ],
        ),
      );
      player.advance(const Duration(seconds: 3));
      expect(highlights, [null]);
      player.complete();
      expect(heard, [(0, 18), (_secondOffset, _body.length)]);
      await service.dispose();
    },
  );

  test(
    'plays downloaded local audio and confirms only heard passages',
    () async {
      final player = _FakePlayer();
      final fetcher = _FakeFetcher();
      final service = _service(player, fetcher);
      final heard = <(int, int)>[];
      final highlights = <(int, int)>[];
      var starts = 0;
      var completions = 0;
      service.setCallbacks(
        onStarted: () => starts++,
        onCompleted: () => completions++,
        onProgress: (text, start, end, word) {
          expect(text, _body);
          expect(word, isEmpty);
          heard.add((start, end));
        },
        onPassage: (text, start, end) => highlights.add((start, end)),
      );

      await service.speak(
        text: _body,
        fullText: _body,
        narration: _narration(),
      );
      expect(starts, 1);
      expect(fetcher.requested.single, _narration().audioUrl);
      final file = File(player.loadedFiles.single);
      expect(await file.readAsBytes(), orderedEquals([1, 2, 3]));
      expect(highlights, [(0, 18)]);
      expect(heard, isEmpty);

      player.advance(const Duration(seconds: 4));
      expect(heard, isEmpty);
      player.advance(const Duration(seconds: 5));
      expect(heard, [(0, 18)]);
      expect(highlights.last, (_secondOffset, _body.length));
      player.complete();
      expect(heard, [(0, 18), (_secondOffset, _body.length)]);
      expect(completions, 1);
      player.complete();
      expect(completions, 1);

      await service.dispose();
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'pause and resume retain the exact player position and pending passage',
    () async {
      final player = _FakePlayer();
      final fetcher = _FakeFetcher();
      final service = _service(player, fetcher);
      final heard = <(int, int)>[];
      var starts = 0;
      var pauses = 0;
      service.setCallbacks(
        onStarted: () => starts++,
        onPaused: () => pauses++,
        onProgress: (_, start, end, _) => heard.add((start, end)),
      );
      await service.speak(
        text: _body,
        fullText: _body,
        narration: _narration(),
      );
      player.advance(const Duration(seconds: 4));
      await service.pause();
      expect(pauses, 1);
      expect(heard, isEmpty);

      await service.speak(
        text: _body,
        fullText: _body,
        narration: _narration(),
        resume: true,
      );
      expect(player.position, const Duration(seconds: 4));
      expect(player.seeks, [Duration.zero]);
      expect(player.loadedFiles, hasLength(1));
      expect(fetcher.requested, hasLength(1));
      expect(starts, 2);
      player.complete();
      expect(heard, [(0, 18), (_secondOffset, _body.length)]);
      await service.dispose();
    },
  );

  test(
    'buffering does not announce playback and native errors never complete',
    () async {
      final player = _FakePlayer()..startReady = false;
      final service = _service(player, _FakeFetcher());
      var starts = 0;
      var completions = 0;
      final errors = <String>[];
      service.setCallbacks(
        onStarted: () => starts++,
        onCompleted: () => completions++,
        onError: errors.add,
      );
      await service.speak(text: _body, narration: _narration());
      expect(starts, 0);
      player._states.add(PlayerState(true, ProcessingState.ready));
      expect(starts, 1);
      player._errors.add(PlayerException(404, 'provider secret abc123', null));
      player._errors.add(PlayerException(404, 'provider secret abc123', null));
      player.complete();
      expect(errors, hasLength(1));
      expect(errors.single, isNot(contains('abc123')));
      expect(completions, 0);
      await service.dispose();
    },
  );

  test(
    'a failed native pause keeps the active run observable for retry or completion',
    () async {
      final player = _FakePlayer();
      final service = _service(player, _FakeFetcher());
      var completions = 0;
      service.setCallbacks(onCompleted: () => completions++);
      await service.speak(text: _body, narration: _narration());
      player.pauseFailure = StateError('native pause failed');
      await expectLater(service.pause(), throwsA(isA<AppException>()));
      player.complete();
      expect(completions, 1);
      await service.dispose();
    },
  );

  test('seeking a passage does not count skipped text as narrated', () async {
    final player = _FakePlayer();
    final service = _service(player, _FakeFetcher());
    final heard = <(int, int)>[];
    final highlights = <(int, int)>[];
    service.setCallbacks(
      onProgress: (_, start, end, _) => heard.add((start, end)),
      onPassage: (_, start, end) => highlights.add((start, end)),
    );
    await service.speak(
      text: _body.substring(_secondOffset),
      fullText: _body,
      startOffset: _secondOffset,
      narration: _narration(),
    );
    expect(player.seeks, [const Duration(seconds: 5)]);
    expect(highlights, [(_secondOffset, _body.length)]);
    expect(heard, isEmpty);
    player.complete();
    expect(heard, [(_secondOffset, _body.length)]);
    await service.dispose();
  });

  test(
    'uncued playback has no invented highlights and confirms at actual end',
    () async {
      final player = _FakePlayer();
      final service = _service(player, _FakeFetcher());
      final heard = <(int, int)>[];
      var highlights = 0;
      service.setCallbacks(
        onProgress: (_, start, end, _) => heard.add((start, end)),
        onPassage: (_, _, _) => highlights++,
      );
      await service.speak(
        text: _body,
        narration: _narration(segments: const []),
      );
      player.advance(const Duration(seconds: 9));
      expect(heard, isEmpty);
      expect(highlights, 0);
      await service.pause();
      await service.speak(
        text: _body,
        narration: _narration(segments: const []),
        resume: true,
      );
      player.complete();
      expect(heard, [(0, _body.length)]);
      expect(highlights, 0);
      await service.dispose();
    },
  );

  test(
    'a short decoder padding difference still confirms the final heard passage',
    () async {
      final player = _FakePlayer();
      final service = _service(player, _FakeFetcher());
      final heard = <(int, int)>[];
      service.setCallbacks(
        onProgress: (_, start, end, _) => heard.add((start, end)),
      );
      await service.speak(
        text: _body,
        narration: _narration(
          segments: [
            _narration().segments.first,
            const StoryNarrationSegment(
              text: 'He stepped forward.',
              startOffset: _secondOffset,
              endOffset: _body.length,
              startTime: Duration(seconds: 5),
              endTime: Duration(milliseconds: 10040),
            ),
          ],
        ),
      );
      player.complete();
      expect(heard, [(0, 18), (_secondOffset, _body.length)]);
      await service.dispose();
    },
  );

  test(
    'rejects untrusted audio before fetch and sanitizes download failure',
    () async {
      final player = _FakePlayer();
      final fetcher = _FakeFetcher();
      final service = _service(player, fetcher);
      var starts = 0;
      service.setCallbacks(onStarted: () => starts++);
      await expectLater(
        service.speak(
          text: _body,
          narration: _narration(url: 'https://tracking.test/private'),
        ),
        throwsA(isA<AppException>()),
      );
      expect(fetcher.requested, isEmpty);
      fetcher.failure = StateError('private provider token abc123');
      await expectLater(
        service.speak(text: _body, narration: _narration()),
        throwsA(
          isA<AppException>().having(
            (error) => error.userMessage,
            'safe error',
            allOf(contains('Check your connection'), isNot(contains('abc123'))),
          ),
        ),
      );
      expect(starts, 0);
      expect(player.playCalls, 0);
      fetcher.failure = null;
      await service.speak(text: _body, narration: _narration());
      expect(starts, 1);
      await service.dispose();
    },
  );

  test(
    'stopping a pending download prevents later playback and callbacks',
    () async {
      final player = _FakePlayer();
      final fetcher = _FakeFetcher()..gate = Completer<void>();
      final service = _service(player, fetcher);
      var starts = 0;
      var completions = 0;
      service.setCallbacks(
        onStarted: () => starts++,
        onCompleted: () => completions++,
      );
      final pending = service.speak(text: _body, narration: _narration());
      await Future<void>.delayed(Duration.zero);
      expect(fetcher.requested, hasLength(1));
      await service.stop();
      fetcher.gate!.complete();
      await pending;
      expect(player.loadedFiles, isEmpty);
      expect(player.playCalls, 0);
      expect(starts, 0);
      expect(completions, 0);
      await service.dispose();
    },
  );

  test(
    'switching character replaces the audio and removes the previous file',
    () async {
      final player = _FakePlayer();
      final fetcher = _FakeFetcher();
      final service = _service(player, fetcher);
      final positions = <Duration>[];
      service.setCallbacks(
        onPosition: (position, _) => positions.add(position),
      );
      await service.speak(text: _body, narration: _narration());
      final previous = File(player.loadedFiles.single);
      player.advance(const Duration(seconds: 3));
      expect(positions.last, const Duration(seconds: 3));
      await service.speak(
        text: _body,
        narration: _narration(url: 'https://audio.kingdom-kids.test/nia.mp3'),
        resume: true,
      );
      expect(fetcher.requested, hasLength(2));
      expect(player.playCalls, 2);
      expect(player.seeks.last, Duration.zero);
      expect(positions.last, Duration.zero);
      expect(await previous.exists(), isFalse);
      await service.dispose();
    },
  );

  test(
    'invalid or stale text cues cannot drive passage highlighting',
    () async {
      final player = _FakePlayer();
      final service = _service(player, _FakeFetcher());
      var highlights = 0;
      service.setCallbacks(onPassage: (_, _, _) => highlights++);
      await service.speak(
        text: _body,
        narration: _narration(
          segments: const [
            StoryNarrationSegment(
              text: 'Wrong edition',
              startOffset: 0,
              endOffset: 13,
              startTime: Duration.zero,
              endTime: Duration(seconds: 5),
            ),
          ],
        ),
      );
      player.advance(const Duration(seconds: 5));
      expect(highlights, 0);
      await service.dispose();
    },
  );

  test(
    'routes declared device speech and ready character audio without fallback',
    () async {
      final device = _FakeService();
      final hosted = _FakeService();
      final service = CharacterStoryNarrationService(
        deviceService: device,
        hostedService: hosted,
      );
      var starts = 0;
      service.setCallbacks(onStarted: () => starts++);
      await service.speak(
        text: _body,
        narration: _narration(status: 'device_tts'),
      );
      expect(device.spoken, 1);
      expect(hosted.spoken, 0);
      await service.speak(
        text: _body,
        fullText: _body,
        narration: _narration(),
      );
      expect(device.stops, 1);
      expect(hosted.spoken, 1);
      expect(starts, 2);
      hosted.failure = const AppException('Audio unavailable.');
      await expectLater(
        service.speak(text: _body, narration: _narration()),
        throwsA(isA<AppException>()),
      );
      expect(device.spoken, 1);
      await service.dispose();
    },
  );

  test(
    'parses measured UTF-16 cues and rejects overlapping or malformed cues',
    () {
      const body = 'Hi 👋. Be kind.';
      final valid = StoryNarrationSegment.listFromJson([
        {
          'text': 'Hi 👋.',
          'start_offset': 0,
          'end_offset': 6,
          'start_seconds': 0,
          'end_seconds': 1.25,
        },
        {
          'text': 'Be kind.',
          'start_offset': 7,
          'end_offset': 15,
          'start_seconds': 1.25,
          'end_seconds': 3,
        },
      ]);
      expect(_narration(segments: valid).segmentsForText(body), hasLength(2));
      expect(valid.first.endTime, const Duration(milliseconds: 1250));
      expect(
        _narration(segments: valid.reversed.toList()).segmentsForText(body),
        isEmpty,
      );
      expect(
        StoryNarrationSegment.listFromJson([
          {
            'text': 'bad',
            'start_offset': -1,
            'end_offset': 2,
            'start_seconds': 0,
            'end_seconds': 1,
          },
        ]),
        isEmpty,
      );
      expect(
        StoryNarrationSegment.listFromJson([
          {
            'text': 'bad',
            'start_offset': 0,
            'end_offset': 3,
            'start_seconds': 0,
            'end_seconds': double.nan,
          },
        ]),
        isEmpty,
      );
    },
  );

  test(
    'story decoding preserves exact whitespace for backend passage offsets',
    () {
      const body = '\n Hi 👋. \n';
      final story = StoryDetail.fromJson({
        'slug': 'hello',
        'title': 'Hello',
        'body': body,
        'narrations': [
          {
            'avatar_key': 'lion',
            'voice_key': 'kai',
            'character_name': 'Kai',
            'status': 'ready',
            'audio_available': true,
            'audio_url': 'https://audio.kingdom-kids.test/hello.mp3',
            'segments': [
              {
                'text': 'Hi 👋.',
                'start_offset': 2,
                'end_offset': 8,
                'start_seconds': 0,
                'end_seconds': 2,
              },
            ],
          },
        ],
      }, mediaPolicy: _policy);
      expect(story.body, body);
      expect(story.narrations.single.segmentsForText(story.body), hasLength(1));
    },
  );
}

HostedStoryNarrationService _service(
  _FakePlayer player,
  _FakeFetcher fetcher,
) => HostedStoryNarrationService(
  audioPlayer: player,
  mediaPolicy: _policy,
  mediaFetcher: fetcher,
);

StoryNarration _narration({
  String url = 'https://audio.kingdom-kids.test/kai.mp3',
  String status = 'ready',
  List<StoryNarrationSegment>? segments,
  List<StoryNarrationSegment> words = const [],
}) => StoryNarration(
  avatarKey: 'lion',
  voiceKey: 'kai',
  characterName: 'Kai',
  voiceDescription: 'Warm and adventurous',
  locale: 'en-GB',
  speechRate: 0.42,
  pitch: 0.92,
  status: status,
  audioAvailable: status == 'ready',
  audioUrl: url,
  durationSeconds: 10,
  words: words,
  segments:
      segments ??
      const [
        StoryNarrationSegment(
          text: 'David trusted God.',
          startOffset: 0,
          endOffset: 18,
          startTime: Duration.zero,
          endTime: Duration(seconds: 5),
        ),
        StoryNarrationSegment(
          text: 'He stepped forward.',
          startOffset: _secondOffset,
          endOffset: _body.length,
          startTime: Duration(seconds: 5),
          endTime: Duration(seconds: 10),
        ),
      ],
);

const _words = [
  StoryNarrationSegment(
    text: 'David',
    startOffset: 0,
    endOffset: 5,
    startTime: Duration(seconds: 1),
    endTime: Duration(milliseconds: 1800),
  ),
  StoryNarrationSegment(
    text: 'trusted',
    startOffset: 6,
    endOffset: 13,
    startTime: Duration(milliseconds: 2200),
    endTime: Duration(milliseconds: 3600),
  ),
  StoryNarrationSegment(
    text: 'God.',
    startOffset: 14,
    endOffset: 18,
    startTime: Duration(seconds: 4),
    endTime: Duration(milliseconds: 4800),
  ),
];

final class _FakeFetcher implements ContentMediaFetcher {
  final requested = <String>[];
  Object? failure;
  Completer<void>? gate;

  @override
  Future<FetchedContentMedia> fetch(Object? source) async {
    requested.add(source.toString());
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    return FetchedContentMedia(
      bytes: Uint8List.fromList([1, 2, 3]),
      finalUri: Uri.parse(source.toString()),
      contentType: 'audio/mpeg',
    );
  }
}

final class _FakePlayer extends AudioPlayer {
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _errors = StreamController<PlayerException>.broadcast(sync: true);
  final loadedFiles = <String>[];
  final seeks = <Duration>[];
  int playCalls = 0;
  bool startReady = true;
  Object? pauseFailure;
  Duration _position = Duration.zero;
  static const _duration = Duration(seconds: 10);

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) {
    expect(minPeriod, const Duration(milliseconds: 50));
    expect(maxPeriod, const Duration(milliseconds: 50));
    return _positions.stream;
  }

  @override
  Stream<PlayerException> get errorStream => _errors.stream;
  @override
  Duration get position => _position;

  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    loadedFiles.add(filePath);
    _position = initialPosition ?? Duration.zero;
    return _duration;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _position = position ?? Duration.zero;
    seeks.add(_position);
  }

  @override
  Future<void> play() async {
    playCalls++;
    _states.add(
      PlayerState(
        true,
        startReady ? ProcessingState.ready : ProcessingState.buffering,
      ),
    );
  }

  void advance(Duration position) {
    _position = position;
    _positions.add(position);
  }

  void complete() {
    advance(_duration);
    _states.add(PlayerState(true, ProcessingState.completed));
  }

  @override
  Future<void> pause() async {
    if (pauseFailure != null) throw pauseFailure!;
    _states.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> stop() async =>
      _states.add(PlayerState(false, ProcessingState.idle));
  @override
  Future<void> dispose() async {
    await _states.close();
    await _positions.close();
    await _errors.close();
  }
}

final class _FakeService implements StoryNarrationService {
  int spoken = 0;
  int stops = 0;
  AppException? failure;
  VoidCallback? _onStarted;

  @override
  void setCallbacks({
    VoidCallback? onStarted,
    VoidCallback? onCompleted,
    VoidCallback? onPaused,
    VoidCallback? onCancelled,
    NarrationErrorCallback? onError,
    NarrationProgressCallback? onProgress,
    NarrationPassageCallback? onPassage,
    NarrationPositionCallback? onPosition,
    NarrationWordCallback? onWord,
  }) => _onStarted = onStarted;
  @override
  Future<void> speak({
    required String text,
    required StoryNarration narration,
    String? fullText,
    int startOffset = 0,
    bool resume = false,
  }) async {
    if (failure != null) throw failure!;
    spoken++;
    _onStarted?.call();
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
}
