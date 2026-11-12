import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/core/media/content_media_image.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/game_cover_image.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/story_cover_image.dart';

const _policy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.example.test/api',
  configuredHosts: 'api.cloudinary.com',
);
String _url(String proof, {bool expired = true}) =>
    'https://api.cloudinary.com/v1_1/synthetic/image/download?type=authenticated&expires_at=${expired ? 1 : 9999999999}&signature=$proof';
StoryDetail _story(String url, {String id = 'story-1'}) => StoryDetail(
  id: id,
  slug: 'jonah',
  title: 'Jonah',
  author: 'Kingdom Kids',
  category: 'Bible',
  body: 'Jonah listened.',
  coverImageUrl: url,
);
MiniGame _game(String url, {String id = 'game-1'}) => MiniGame(
  id: id,
  slug: 'puzzle-jonah',
  title: 'Jonah puzzle',
  type: MiniGameType.jigsaw,
  difficulty: 'Easy',
  duration: '2 min',
  imageAsset: '',
  description: '',
  rewardStars: 3,
  totalLevels: 1,
  coverImageUrl: url,
);

void main() {
  testWidgets(
    'expired story cover obtains fresh authorized metadata before bytes',
    (tester) async {
      final auth = _Auth(),
          repo = _Stories(_story(_url('fresh', expired: false)));
      final fetcher = _Fetcher();
      await _pump(
        tester,
        StoryCoverImage(
          story: _story(_url('old')),
          authRepository: auth,
          storyRepository: repo,
          mediaPolicy: _policy,
          mediaFetcher: fetcher,
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.calls, 1);
      expect(fetcher.requested, [_url('fresh', expired: false)]);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('game refresh stays bound to the selected child and exact game', (
    tester,
  ) async {
    final auth = _Auth(), repo = _Games(_game(_url('fresh', expired: false)));
    final fetcher = _Fetcher();
    await _pump(
      tester,
      GameCoverImage(
        game: _game(_url('old')),
        authRepository: auth,
        gameRepository: repo,
        mediaPolicy: _policy,
        mediaFetcher: fetcher,
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.childIds, ['child-1']);
    expect(fetcher.requested, [_url('fresh', expired: false)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('child switch during story refresh rejects the old response', (
    tester,
  ) async {
    final auth = _Auth(),
        repo = _Stories(_story(_url('fresh', expired: false)))
          ..gate = Completer<StoryDetail>();
    final fetcher = _Fetcher();
    await _pump(
      tester,
      StoryCoverImage(
        story: _story(_url('old')),
        authRepository: auth,
        storyRepository: repo,
        mediaPolicy: _policy,
        mediaFetcher: fetcher,
      ),
    );
    await tester.pump();
    expect(repo.calls, 1);
    auth.child = auth.child.copyWith(id: 'other-child');
    repo.gate!.complete(repo.fresh);
    await tester.pumpAndSettle();
    expect(fetcher.requested, isEmpty);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed game identity never supplies replacement media', (
    tester,
  ) async {
    final fetcher = _Fetcher();
    await _pump(
      tester,
      GameCoverImage(
        game: _game(_url('old')),
        authRepository: _Auth(),
        gameRepository: _Games(_game(_url('foreign'), id: 'other-game')),
        mediaPolicy: _policy,
        mediaFetcher: fetcher,
      ),
    );
    await tester.pumpAndSettle();
    expect(fetcher.requested, isEmpty);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'denied unexpired URL refreshes once and never loops on second denial',
    (tester) async {
      final fetcher = _Fetcher()..denied = true;
      var refreshes = 0;
      await _pump(
        tester,
        _image(_url('old', expired: false), fetcher, () async {
          refreshes++;
          return _url('fresh', expired: false);
        }),
      );
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(fetcher.requested, [
        _url('old', expired: false),
        _url('fresh', expired: false),
      ]);
      expect(find.text('safe-fallback'), findsOneWidget);
      expect(find.textContaining('signature='), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same or untrusted replacement is not fetched', (tester) async {
    for (final replacement in [_url('old'), 'https://foreign.example/secret']) {
      final fetcher = _Fetcher();
      var calls = 0;
      await _pump(
        tester,
        _image(_url('old'), fetcher, () async {
          calls++;
          return replacement;
        }),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(fetcher.requested, isEmpty);
      expect(find.text('safe-fallback'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing pending refresh prevents download or late UI error', (
    tester,
  ) async {
    final reply = Completer<Object?>(), fetcher = _Fetcher();
    await _pump(tester, _image(_url('old'), fetcher, () => reply.future));
    await tester.pumpWidget(const SizedBox());
    reply.complete(_url('fresh', expired: false));
    await tester.pumpAndSettle();
    expect(fetcher.requested, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ordinary unsigned covers do not read auth or request new metadata',
    (tester) async {
      final auth = _Auth(),
          repo = _Stories(_story('https://api.cloudinary.com/public.png'));
      final fetcher = _Fetcher();
      await _pump(
        tester,
        StoryCoverImage(
          story: repo.fresh,
          authRepository: auth,
          storyRepository: repo,
          mediaPolicy: _policy,
          mediaFetcher: fetcher,
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.calls, 0);
      expect(auth.reads, 0);
      expect(fetcher.requested, ['https://api.cloudinary.com/public.png']);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 200, height: 220, child: child)),
  ),
);
Widget _image(
  String url,
  ContentMediaFetcher fetcher,
  Future<Object?> Function() refresh,
) => ContentMediaImage(
  source: url,
  mediaPolicy: _policy,
  mediaFetcher: fetcher,
  sourceRefresher: refresh,
  fit: BoxFit.cover,
  alignment: Alignment.center,
  loadingBuilder: (_) => const Text('loading'),
  errorBuilder: (_) => const Text('safe-fallback'),
);

class _Auth extends AuthRepository {
  int reads = 0;
  AuthSession? session = const AuthSession(
    parent: ParentAccount(id: 'parent-1', email: 'parent@example.test'),
    accessToken: 'synthetic',
  );
  KidProfile child = const KidProfile(
    id: 'child-1',
    parentId: 'parent-1',
    displayName: 'Kid',
    avatarKey: 'lion',
  );
  @override
  Future<AuthSession?> restoreSession() async {
    reads++;
    return session;
  }

  @override
  Future<KidProfile?> currentKid() async => child;
}

class _Stories implements StoryRepository {
  _Stories(this.fresh);
  final StoryDetail fresh;
  int calls = 0;
  Completer<StoryDetail>? gate;
  @override
  Future<StoryDetail> fetchStory(String slug) async {
    calls++;
    return gate == null ? fresh : gate!.future;
  }

  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async => [fresh];
}

class _Games implements GameRepository {
  _Games(this.fresh);
  final MiniGame fresh;
  final childIds = <String>[];
  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) async {
    childIds.add(profileId);
    return fresh;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fetcher implements ContentMediaFetcher {
  final requested = <String>[];
  bool denied = false;
  @override
  Future<FetchedContentMedia> fetch(Object? source) async {
    requested.add(source.toString());
    if (denied) throw const ContentMediaFetchException('unexpected_status');
    return FetchedContentMedia(
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      finalUri: Uri.parse(source.toString()),
      contentType: 'image/png',
    );
  }
}
