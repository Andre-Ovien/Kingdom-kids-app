// All HTTP/audio/auth objects below are synthetic; no real channel or network.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/stories/data/story_narration_metadata_refresher.dart';
import 'package:mobile/features/stories/data/story_narration_service.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';

const body = 'Jonah listened.';
const oldUrl =
    'https://api.cloudinary.com/v1_1/synthetic/video/download?expires_at=1&signature=old-synthetic';
const freshUrl =
    'https://api.cloudinary.com/v1_1/synthetic/video/download?expires_at=9999999999&signature=fresh-synthetic';
const policy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.example.test/api',
  configuredHosts: 'api.cloudinary.com',
);
StoryNarration narration(
  String url, {
  String avatar = 'lion',
  String voice = 'kai',
}) => StoryNarration(
  avatarKey: avatar,
  voiceKey: voice,
  characterName: 'Kai',
  voiceDescription: '',
  locale: 'en-US',
  speechRate: .45,
  pitch: 1,
  status: 'ready',
  audioAvailable: true,
  audioUrl: url,
);
StoryDetail story({String text = body, List<StoryNarration>? voices}) =>
    StoryDetail(
      id: 'synthetic-story',
      slug: 'jonah-and-the-big-fish',
      title: 'Jonah',
      author: 'Kingdom Kids',
      category: 'Bible',
      body: text,
      narrations: voices ?? [narration(oldUrl)],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unprepared expired track uses fresh authorized same-edition voice; resume stays local',
    () async {
      final auth = _Auth(), repo = _Repo(story(voices: [narration(freshUrl)]));
      final resolver = StoryNarrationMetadataRefresher(
        story: story(),
        authRepository: auth,
        storyRepository: repo,
      );
      final player = _FakePlayer();
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        return http.Response.bytes(
          [1, 2, 3],
          request.url.toString() == freshUrl ? 200 : 403,
          headers: {'content-type': 'audio/mpeg'},
        );
      });
      final service = HostedStoryNarrationService(
        audioPlayer: player,
        mediaPolicy: policy,
        mediaFetcher: HttpContentMediaFetcher(policy: policy, client: client),
        metadataResolver: resolver.resolve,
        scopeValidator: resolver.validateScope,
      );
      await service.speak(text: body, narration: narration(oldUrl));
      expect(requested.map((u) => u.toString()), [freshUrl]);
      expect(repo.calls, 1);
      final local = File(player.loadedFiles.single);
      expect(await local.exists(), true);
      await service.pause();
      await service.speak(
        text: body,
        narration: narration(oldUrl),
        resume: true,
      );
      expect(repo.calls, 1);
      expect(requested.length, 1);
      expect(player.playCalls, 2);
      await service.dispose();
      expect(await local.exists(), false);
      client.close();
    },
  );

  test(
    'child switch during metadata refresh rejects reply before media request',
    () async {
      final auth = _Auth(),
          repo = _Repo(story(voices: [narration(freshUrl)]))
            ..gate = Completer<StoryDetail>();
      final resolver = StoryNarrationMetadataRefresher(
        story: story(),
        authRepository: auth,
        storyRepository: repo,
      );
      await resolver.validateScope();
      final pending = resolver.resolve(narration(oldUrl), body);
      await Future<void>.delayed(Duration.zero);
      auth.child = auth.child.copyWith(id: 'synthetic-other-child');
      repo.gate!.complete(repo.fresh);
      await expectLater(
        pending,
        throwsA(
          isA<AppException>().having(
            (e) => e.code,
            'code',
            'active_kid_changed',
          ),
        ),
      );
      expect(repo.calls, 1);
    },
  );

  test(
    'changed story text or selected voice cannot replace current reader edition',
    () async {
      for (final changed in [
        story(text: 'A different edition.', voices: [narration(freshUrl)]),
        story(voices: [narration(freshUrl, voice: 'different')]),
        story(voices: [narration(freshUrl, avatar: 'elephant')]),
      ]) {
        final resolver = StoryNarrationMetadataRefresher(
          story: story(),
          authRepository: _Auth(),
          storyRepository: _Repo(changed),
        );
        await expectLater(
          resolver.resolve(narration(oldUrl), body),
          throwsA(isA<AppException>()),
        );
      }
    },
  );

  test(
    'same child moved to another parent and signed-out scope never load metadata',
    () async {
      for (final signedOut in [false, true]) {
        final auth = _Auth(),
            repo = _Repo(story(voices: [narration(freshUrl)]));
        final resolver = StoryNarrationMetadataRefresher(
          story: story(),
          authRepository: auth,
          storyRepository: repo,
        );
        await resolver.validateScope();
        if (signedOut) {
          auth.session = null;
        } else {
          auth.session = auth.session!.copyWith(
            parent: const ParentAccount(
              id: 'other-parent',
              email: 'other@example.test',
            ),
          );
        }
        await expectLater(
          resolver.resolve(narration(oldUrl), body),
          throwsA(isA<AppException>()),
        );
        expect(repo.calls, 0);
      }
    },
  );

  test(
    'metadata failure does not expose response details or bearer URL',
    () async {
      final repo = _Repo(story())
        ..failure = const AppException('synthetic-private-response-marker');
      final resolver = StoryNarrationMetadataRefresher(
        story: story(),
        authRepository: _Auth(),
        storyRepository: repo,
      );
      await expectLater(
        resolver.resolve(narration(oldUrl), body),
        throwsA(
          isA<AppException>()
              .having((e) => e.code, 'code', 'story_media_refresh_failed')
              .having(
                (e) => e.userMessage,
                'sanitized',
                isNot(contains('synthetic-private')),
              ),
        ),
      );
    },
  );

  test(
    'stop during metadata wait prevents subsequent download and playback',
    () async {
      final player = _FakePlayer(), gate = Completer<StoryNarration>();
      var fetched = 0;
      final client = MockClient((request) async {
        fetched++;
        return http.Response.bytes([1], 200);
      });
      final service = HostedStoryNarrationService(
        audioPlayer: player,
        mediaPolicy: policy,
        mediaFetcher: HttpContentMediaFetcher(policy: policy, client: client),
        metadataResolver: (_, _) => gate.future,
      );
      final pending = service.speak(text: body, narration: narration(oldUrl));
      await Future<void>.delayed(Duration.zero);
      await service.stop();
      gate.complete(narration(freshUrl));
      await pending;
      expect(fetched, 0);
      expect(player.playCalls, 0);
      await service.dispose();
      client.close();
    },
  );

  test(
    'child switch during asset download is rejected again before native playback',
    () async {
      final auth = _Auth(), repo = _Repo(story(voices: [narration(freshUrl)]));
      final resolver = StoryNarrationMetadataRefresher(
        story: story(),
        authRepository: auth,
        storyRepository: repo,
      );
      final reply = Completer<http.Response>(),
          started = Completer<void>(),
          player = _FakePlayer();
      final client = MockClient((request) {
        started.complete();
        return reply.future;
      });
      final service = HostedStoryNarrationService(
        audioPlayer: player,
        mediaPolicy: policy,
        mediaFetcher: HttpContentMediaFetcher(policy: policy, client: client),
        metadataResolver: resolver.resolve,
        scopeValidator: resolver.validateScope,
      );
      final pending = service.speak(text: body, narration: narration(oldUrl));
      await started.future;
      auth.child = auth.child.copyWith(id: 'synthetic-other-child');
      reply.complete(
        http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      );
      await expectLater(pending, throwsA(isA<AppException>()));
      expect(player.playCalls, 0);
      await service.dispose();
      client.close();
    },
  );
}

class _Auth extends AuthRepository {
  AuthSession? session = const AuthSession(
    parent: ParentAccount(id: 'synthetic-parent', email: 'parent@example.test'),
    accessToken: 'synthetic-test-token',
  );
  KidProfile child = const KidProfile(
    id: 'synthetic-child',
    parentId: 'synthetic-parent',
    displayName: 'Kid',
    avatarKey: 'lion',
  );
  @override
  Future<AuthSession?> restoreSession() async => session;
  @override
  Future<KidProfile?> currentKid() async => child;
}

class _Repo implements StoryRepository {
  _Repo(this.fresh);
  final StoryDetail fresh;
  int calls = 0;
  Object? failure;
  Completer<StoryDetail>? gate;
  @override
  Future<StoryDetail> fetchStory(String slug) async {
    calls++;
    if (failure != null) throw failure!;
    return gate == null ? fresh : gate!.future;
  }

  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async => [fresh];
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
