import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/email_verification.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/domain/password_reset.dart';
import 'package:mobile/features/stories/data/story_api.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';

void main() {
  group('StoryDetail', () {
    test('keeps the hardcoded catalogue constructor source-compatible', () {
      const story = StoryDetail(
        title: 'A legacy story',
        author: 'Kingdom Kids',
        category: 'Faith',
        imageAsset: 'assets/images/story.png',
        imageAlignment: Alignment(0.25, -0.5),
        rating: '4.9',
        reviewCount: '3k',
        description: 'The complete story.',
      );

      expect(story.description, 'The complete story.');
      expect(story.body, 'The complete story.');
      expect(story.summary, 'The complete story.');
      expect(story.coverAssetKey, 'assets/images/story.png');
      expect(story.coverFocusX, 0.25);
      expect(story.coverFocusY, -0.5);
      expect(story.rating, '4.9');
      expect(story.reviewCount, '3k');
      expect(story.ratingValue, 4.9);
      expect(story.reviews, 3000);
    });

    test('parses backend detail and character narration metadata', () {
      final story = StoryDetail.fromJson({
        'id': 'ec224294-7b23-4afd-82a7-cf164d0808ac',
        'slug': 'david-and-goliath',
        'title': 'David & Goliath',
        'author': 'Kingdom Kids',
        'category': 'Courage',
        'summary': 'Faith can be bigger than fear.',
        'body': 'David trusted God with his whole heart.',
        'cover_asset_key': 'assets/images/david_and_goliath.png',
        'cover_image_url': 'https://media.test/david.png',
        'cover_focus_x': 0.2,
        'cover_focus_y': -0.1,
        'rating': '4.8',
        'review_count': 2000,
        'estimated_read_seconds': 240,
        'is_featured': true,
        'narrations': [
          {
            'avatar_key': 'lion',
            'voice_key': 'kai',
            'character_name': 'Kai',
            'voice_description': 'Warm and adventurous',
            'locale': 'en-US',
            'speech_rate': 0.44,
            'pitch': 1.05,
            'sample_url': 'https://media.test/kai-sample.mp3',
            'status': 'ready',
            'audio_available': true,
            'audio_url': 'https://media.test/david-kai.mp3',
            'duration_seconds': 218,
          },
        ],
      }, mediaPolicy: _trustedMediaPolicy);

      expect(story.id, 'ec224294-7b23-4afd-82a7-cf164d0808ac');
      expect(story.slug, 'david-and-goliath');
      expect(story.summary, 'Faith can be bigger than fear.');
      expect(story.description, 'David trusted God with his whole heart.');
      expect(
        story.coverAssetKey,
        'assets/images/stories/david-and-goliath-v2.webp',
      );
      expect(story.coverImageUrl, 'https://media.test/david.png');
      expect(story.imageAlignment, const Alignment(0.2, -0.1));
      expect(story.ratingValue, 4.8);
      expect(story.rating, '4.8');
      expect(story.reviews, 2000);
      expect(story.reviewCount, '2k');
      expect(story.estimatedReadSeconds, 240);
      expect(story.isFeatured, isTrue);

      final narration = story.narrations.single;
      expect(narration.avatarKey, 'lion');
      expect(narration.voiceKey, 'kai');
      expect(narration.characterName, 'Kai');
      expect(narration.voiceDescription, 'Warm and adventurous');
      expect(narration.locale, 'en-US');
      expect(narration.speechRate, 0.44);
      expect(narration.pitch, 1.05);
      expect(narration.status, 'ready');
      expect(narration.audioAvailable, isTrue);
      expect(narration.audioUrl, 'https://media.test/david-kai.mp3');
      expect(narration.durationSeconds, 218);
    });

    test('uses the summary as the readable description for list records', () {
      final story = StoryDetail.fromJson({
        'slug': 'creation-week',
        'title': 'Creation Week',
        'summary': 'God fills the world with wonder.',
      });

      expect(story.body, isEmpty);
      expect(story.description, 'God fills the world with wonder.');
      expect(story.narrations, isEmpty);
    });

    test('normalizes legacy covers and rejects unsafe hosted media', () {
      final story = StoryDetail.fromJson({
        'slug': 'david-and-goliath',
        'title': 'David & Goliath',
        'cover_asset_key': 'assets/images/david_and_goliath.png',
        'cover_image_url': 'file:///private/story.png',
        'cover_focus_x': 4,
        'cover_focus_y': -3,
        'rating': 9,
        'review_count': -8,
        'estimated_read_seconds': -20,
        'narrations': [
          {
            'avatar_key': 'lion',
            'voice_key': 'kai',
            'character_name': 'Kai',
            'status': 'ready',
            'audio_available': true,
            'audio_url': 'javascript:alert(1)',
            'sample_url': '/relative/sample.mp3',
            'duration_seconds': -1,
          },
        ],
      });

      expect(
        story.coverAssetKey,
        'assets/images/stories/david-and-goliath-v2.webp',
      );
      expect(story.coverImageUrl, isNull);
      expect(story.imageAlignment, Alignment.center);
      expect(story.ratingValue, 5);
      expect(story.reviews, 0);
      expect(story.estimatedReadSeconds, 0);
      expect(story.narrations.single.audioAvailable, isFalse);
      expect(story.narrations.single.audioUrl, isNull);
      expect(story.narrations.single.sampleUrl, isNull);
      expect(story.narrations.single.durationSeconds, isNull);
    });

    test('drops unowned or cleartext media while keeping bundled art', () {
      final story = StoryDetail.fromJson({
        'slug': 'david-and-goliath',
        'title': 'David & Goliath',
        'cover_asset_key': 'assets/images/david_and_goliath.png',
        'cover_image_url': 'https://tracking.example/david.png',
        'narrations': [
          {
            'avatar_key': 'lion',
            'voice_key': 'kai',
            'character_name': 'Kai',
            'status': 'ready',
            'audio_available': true,
            'sample_url': 'http://media.test/kai-sample.mp3',
            'audio_url': 'https://user:secret@media.test/david-kai.mp3',
          },
        ],
      }, mediaPolicy: _trustedMediaPolicy);

      expect(story.coverImageUrl, isNull);
      expect(
        story.coverAssetKey,
        'assets/images/stories/david-and-goliath-v2.webp',
      );
      expect(story.narrations.single.sampleUrl, isNull);
      expect(story.narrations.single.audioUrl, isNull);
      expect(story.narrations.single.audioAvailable, isFalse);
    });

    test('requires the backend identity fields used for navigation', () {
      expect(
        () => StoryDetail.fromJson({'title': 'Missing its slug'}),
        throwsFormatException,
      );
      expect(
        () => StoryDetail.fromJson({'slug': 'missing-title'}),
        throwsFormatException,
      );
    });

    test('does not promote a catalogue summary to full story text', () {
      const story = StoryDetail(
        slug: 'a-list-record',
        title: 'A List Record',
        author: 'Kingdom Kids',
        category: 'Faith',
        summary: 'This is only a short preview.',
      );

      expect(story.summary, 'This is only a short preview.');
      expect(story.body, isEmpty);
      expect(story.description, 'This is only a short preview.');
    });
  });

  group('HttpStoryApi', () {
    test(
      'reads bare and paginated catalogues with authenticated filters',
      () async {
        final requests = <http.Request>[];
        var requestNumber = 0;
        final api = HttpStoryApi(
          baseUrl: 'https://kingdom-kids.test',
          client: MockClient((request) async {
            requests.add(request);
            requestNumber++;
            final payload = [
              {
                'id': '$requestNumber',
                'slug': 'story-$requestNumber',
                'title': 'Story $requestNumber',
                'summary': 'A summary.',
              },
            ];
            return http.Response(
              jsonEncode(requestNumber == 1 ? payload : {'results': payload}),
              200,
            );
          }),
        );

        final bare = await api.fetchStories(
          'access-token',
          search: ' big fish ',
          category: ' Mercy ',
        );
        final paginated = await api.fetchStories('access-token');

        expect(bare.single.slug, 'story-1');
        expect(paginated.single.slug, 'story-2');
        expect(requests.first.url.path, '/api/stories/');
        expect(requests.first.url.queryParameters, {
          'search': 'big fish',
          'category': 'Mercy',
        });
        expect(requests.first.headers['authorization'], 'Bearer access-token');
        expect(requests.first.headers['accept'], 'application/json');
      },
    );

    test('gets detail by slug and sends the bearer token', () async {
      late http.Request sentRequest;
      final api = HttpStoryApi(
        baseUrl: 'https://kingdom-kids.test/api/',
        client: MockClient((request) async {
          sentRequest = request;
          return http.Response(
            jsonEncode({
              'id': 'story-1',
              'slug': 'david-and-goliath',
              'title': 'David & Goliath',
              'summary': 'A brave shepherd.',
              'body': 'The complete story.',
              'narrations': [],
            }),
            200,
          );
        }),
      );

      final story = await api.fetchStory('david-and-goliath', 'access-token');

      expect(story.body, 'The complete story.');
      expect(sentRequest.url.path, '/api/stories/david-and-goliath/');
      expect(sentRequest.headers['authorization'], 'Bearer access-token');
    });

    test(
      'rejects malformed catalogue rows and mismatched detail slugs',
      () async {
        var call = 0;
        final api = HttpStoryApi(
          baseUrl: 'https://kingdom-kids.test/api/',
          client: MockClient((_) async {
            call++;
            return call == 1
                ? http.Response(
                    jsonEncode([
                      {'title': 'No slug'},
                      'not-a-map',
                    ]),
                    200,
                  )
                : http.Response(
                    jsonEncode({
                      'slug': 'a-different-story',
                      'title': 'The wrong story',
                    }),
                    200,
                  );
          }),
        );

        await expectLater(
          api.fetchStories('access-token'),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'invalid_story_catalogue',
            ),
          ),
        );
        await expectLater(
          api.fetchStory('requested-story', 'access-token'),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'invalid_story_detail',
            ),
          ),
        );
      },
    );

    test('turns non-success responses into detailed AppExceptions', () async {
      final api = HttpStoryApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'detail': 'This story is still being prepared.'}),
            404,
          ),
        ),
      );

      await expectLater(
        api.fetchStory('coming-soon', 'access-token'),
        throwsA(
          isA<AppException>()
              .having((error) => error.statusCode, 'statusCode', 404)
              .having(
                (error) => error.message,
                'message',
                'This story is still being prepared.',
              ),
        ),
      );
    });

    test('turns network failures and timeouts into AppExceptions', () async {
      final networkApi = HttpStoryApi(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      final timeoutApi = HttpStoryApi(
        requestTimeout: const Duration(milliseconds: 1),
        client: MockClient((_) => Completer<http.Response>().future),
      );

      await expectLater(
        networkApi.fetchStories('access-token'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'network_error',
          ),
        ),
      );
      await expectLater(
        timeoutApi.fetchStories('access-token'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'request_timeout',
          ),
        ),
      );
    });
  });

  group('RemoteStoryRepository', () {
    test(
      'filters New Testament stories even from a cached catalogue',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(
          const AuthSession(
            parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
            accessToken: 'access-token',
          ),
        );
        final api = _CatalogueStoryApi();
        final repository = RemoteStoryRepository(
          authRepository: AuthRepository(sessionStore: store),
          api: api,
          catalogueCache: StoryCatalogueCache(),
        );
        for (var read = 0; read < 2; read++) {
          final stories = await repository.fetchStories();
          expect(stories.map((story) => story.slug), ['ruth-and-naomi']);
        }
        expect(api.listCalls, 1);
      },
    );

    test('retired story requests cannot fetch a body or recording', () async {
      final api = _CatalogueStoryApi();
      final repository = RemoteStoryRepository(api: api);
      for (final slug in ['lost-sheep', 'good-samaritan']) {
        await expectLater(
          repository.fetchStory(slug),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'story_unavailable',
            ),
          ),
        );
      }
      expect(api.detailCalls, 0);
    });

    test('uses the refresh-aware AuthRepository token gateway', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(
        const AuthSession(
          parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
          accessToken: 'expired-access',
          refreshToken: 'refresh-token',
        ),
      );
      final authApi = _RefreshingAuthApi();
      final storyApi = _RefreshAwareStoryApi();
      final repository = RemoteStoryRepository(
        authRepository: AuthRepository(api: authApi, sessionStore: store),
        api: storyApi,
      );

      final stories = await repository.fetchStories(category: 'Courage');

      expect(stories.single.slug, 'david-and-goliath');
      expect(storyApi.accessTokens, ['expired-access', 'fresh-access']);
      expect(storyApi.categories, ['Courage', 'Courage']);
      expect(authApi.refreshCalls, 1);
      expect((await store.readSession())?.accessToken, 'fresh-access');
    });
  });
}

final class _CatalogueStoryApi implements StoryApi {
  int listCalls = 0;
  int detailCalls = 0;

  @override
  Future<List<StoryDetail>> fetchStories(
    String accessToken, {
    String? search,
    String? category,
  }) async {
    listCalls++;
    return const [
      StoryDetail(
        slug: 'ruth-and-naomi',
        title: 'Ruth and Naomi',
        author: 'Kingdom Kids',
        category: 'Kindness',
      ),
      StoryDetail(
        slug: 'lost-sheep',
        title: 'The Lost Sheep',
        author: 'Kingdom Kids',
        category: 'Kindness',
      ),
      StoryDetail(
        slug: 'good-samaritan',
        title: 'The Good Samaritan',
        author: 'Kingdom Kids',
        category: 'Kindness',
      ),
    ];
  }

  @override
  Future<StoryDetail> fetchStory(String slug, String accessToken) async {
    detailCalls++;
    return StoryDetail(
      slug: slug,
      title: slug,
      body: 'A saved story.',
      author: 'Kingdom Kids',
      category: 'Kindness',
    );
  }
}

const _trustedMediaPolicy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.test/api',
  configuredHosts: 'media.test',
);

final class _RefreshAwareStoryApi implements StoryApi {
  final accessTokens = <String>[];
  final categories = <String?>[];

  @override
  Future<List<StoryDetail>> fetchStories(
    String accessToken, {
    String? search,
    String? category,
  }) async {
    accessTokens.add(accessToken);
    categories.add(category);
    if (accessToken == 'expired-access') {
      throw const AppException('Expired.', statusCode: 401);
    }
    return [
      StoryDetail.fromJson({
        'id': 'story-1',
        'slug': 'david-and-goliath',
        'title': 'David & Goliath',
        'summary': 'A brave shepherd.',
      }),
    ];
  }

  @override
  Future<StoryDetail> fetchStory(String slug, String accessToken) {
    throw UnimplementedError();
  }
}

final class _RefreshingAuthApi implements AuthApi {
  int refreshCalls = 0;

  @override
  Future<AuthSession> refresh(AuthSession session) async {
    refreshCalls++;
    return session.copyWith(
      accessToken: 'fresh-access',
      refreshToken: 'fresh-refresh',
    );
  }

  @override
  Future<PendingPasswordReset> requestPasswordReset(
    PasswordResetRequest request,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<void> verifyPasswordResetCode(PasswordResetVerifyRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> confirmPasswordReset(PasswordResetConfirmRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<KidProfile> createKidProfile(
    CreateKidProfileRequest request,
    String accessToken,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<ParentAccount> currentParent(String accessToken) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteAccount({
    required String password,
    required String accessToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<KidProfile>> fetchKidProfiles(
    String accessToken, {
    required String expectedParentId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<KidProfile> retrieveKidProfile(String profileId, String accessToken) {
    throw UnimplementedError();
  }

  @override
  Future<KidProfile> updateKidProfile({
    required String profileId,
    required String displayName,
    required String avatarKey,
    required String accessToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> login(LoginRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PendingEmailVerification> register(RegisterParentRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<PendingEmailVerification> resendEmailVerification(String challengeId) {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> verifyEmail(VerifyEmailRequest request) {
    throw UnimplementedError();
  }
}
