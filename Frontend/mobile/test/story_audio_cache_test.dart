import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/features/stories/data/story_narration_service.dart';

const _policy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.test/api',
  configuredHosts: 'cdn.test',
);
const _source = 'https://cdn.test/story.mp3';

void main() {
  setUp(featureReadCache.invalidate);
  tearDown(featureReadCache.invalidate);

  test(
    'same validated scope reuses audio, every identity change separates it',
    () async {
      final cache = ScopedStoryAudioCache();
      final fetcher = _Fetcher();
      Object scope = ('backend', 'parent', 'child', 'lion', 1);
      Future<FetchedContentMedia> fetch() => cache.fetch(
        source: _source,
        policy: _policy,
        fetcher: fetcher,
        scopeResolver: () async => scope,
        scopeValidator: () async {},
      );
      await fetch();
      await fetch();
      expect(fetcher.calls, 1);
      for (final next in [
        ('other-backend', 'parent', 'child', 'lion', 1),
        ('backend', 'other-parent', 'child', 'lion', 1),
        ('backend', 'parent', 'other-child', 'lion', 1),
        ('backend', 'parent', 'child', 'elephant', 1),
        ('backend', 'parent', 'child', 'lion', 2),
      ]) {
        scope = next;
        await fetch();
      }
      expect(fetcher.calls, 6);
      featureReadCache.invalidate();
      await fetch();
      expect(fetcher.calls, 7);
    },
  );

  test(
    'signed audio cannot reuse bytes at or beyond provider expiry grace',
    () async {
      var now = DateTime.utc(2026, 11, 12, 10);
      final expiry = now.add(const Duration(seconds: 45));
      final cache = ScopedStoryAudioCache(now: () => now);
      final fetcher = _Fetcher();
      final source =
          '$_source?signature=private&expires_at=${expiry.millisecondsSinceEpoch ~/ 1000}';
      Future<FetchedContentMedia> fetch() => cache.fetch(
        source: source,
        policy: _policy,
        fetcher: fetcher,
        scopeResolver: () async => ('parent', 'child', 'lion', 1),
        scopeValidator: () async {},
      );
      await fetch();
      now = now.add(const Duration(seconds: 34));
      await fetch();
      expect(fetcher.calls, 1);
      now = expiry.subtract(const Duration(seconds: 10));
      await fetch();
      now = expiry;
      await fetch();
      expect(fetcher.calls, 3);
    },
  );

  test(
    'missing scope or validator and unknown signed expiry never reuse',
    () async {
      final cache = ScopedStoryAudioCache();
      final fetcher = _Fetcher();
      for (final missing in ['scope', 'validator', 'identity']) {
        for (var attempt = 0; attempt < 2; attempt++) {
          await cache.fetch(
            source: _source,
            policy: _policy,
            fetcher: fetcher,
            scopeResolver: missing == 'scope'
                ? null
                : () async =>
                      missing == 'identity' ? null : 'family-child-avatar',
            scopeValidator: missing == 'validator' ? null : () async {},
          );
        }
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        await cache.fetch(
          source: '$_source?signature=unknown-expiry',
          policy: _policy,
          fetcher: fetcher,
          scopeResolver: () async => 'family-child-avatar',
          scopeValidator: () async {},
        );
      }
      expect(fetcher.calls, 8);
    },
  );

  for (final invalidate in [false, true]) {
    test(
      'late download is rejected after ${invalidate ? 'cache invalidation' : 'scope switch'}',
      () async {
        final cache = ScopedStoryAudioCache();
        final fetcher = _Fetcher()..gate = Completer<FetchedContentMedia>();
        Object scope = 'original-family-child-avatar';
        Future<FetchedContentMedia> fetch() => cache.fetch(
          source: _source,
          policy: _policy,
          fetcher: fetcher,
          scopeResolver: () async => scope,
          scopeValidator: () async {},
        );
        final pending = fetch();
        await Future<void>.delayed(Duration.zero);
        if (invalidate) {
          featureReadCache.invalidate();
        } else {
          scope = 'different-family-child-avatar';
        }
        final expectation = expectLater(pending, throwsA(isA<AppException>()));
        fetcher.gate!.complete(_media(_source));
        await expectation;
        fetcher.gate = null;
        scope = 'original-family-child-avatar';
        await fetch();
        expect(fetcher.calls, 2);
      },
    );
  }

  test(
    'errors are retryable and bounded byte storage evicts old audio',
    () async {
      final cache = ScopedStoryAudioCache(maxBytes: 5);
      final fetcher = _Fetcher()
        ..failure = const ContentMediaFetchException('network_error');
      Future<FetchedContentMedia> fetch(String source) => cache.fetch(
        source: source,
        policy: _policy,
        fetcher: fetcher,
        scopeResolver: () async => 'family-child-avatar',
        scopeValidator: () async {},
      );
      await expectLater(
        fetch(_source),
        throwsA(isA<ContentMediaFetchException>()),
      );
      fetcher.failure = null;
      await fetch(_source);
      await fetch('https://cdn.test/other.mp3');
      await fetch(_source);
      expect(fetcher.calls, 4);
    },
  );

  test('a cached hit still requires current authorization', () async {
    final cache = ScopedStoryAudioCache();
    final fetcher = _Fetcher();
    var authorized = true;
    Future<FetchedContentMedia> fetch() => cache.fetch(
      source: _source,
      policy: _policy,
      fetcher: fetcher,
      scopeResolver: () async => 'family-child-avatar',
      scopeValidator: () async {
        if (!authorized) throw const AppException('Profile changed.');
      },
    );
    await fetch();
    authorized = false;
    await expectLater(fetch(), throwsA(isA<AppException>()));
    expect(fetcher.calls, 1);
  });

  test(
    'progress-only invalidation preserves an in-flight authorized audio download',
    () async {
      final cache = ScopedStoryAudioCache();
      final fetcher = _Fetcher()..gate = Completer<FetchedContentMedia>();
      Future<FetchedContentMedia> fetch() => cache.fetch(
        source: _source,
        policy: _policy,
        fetcher: fetcher,
        scopeResolver: () async => ('backend', 'parent', 'child', 'lion', 1),
        scopeValidator: () async {},
      );
      final pending = fetch();
      await Future<void>.delayed(Duration.zero);
      featureReadCache.invalidate(includeMedia: false);
      fetcher.gate!.complete(_media(_source));
      await pending;
      fetcher.gate = null;
      await fetch();
      expect(fetcher.calls, 1);
      featureReadCache.invalidate();
      await fetch();
      expect(fetcher.calls, 2);
    },
  );
}

FetchedContentMedia _media(String source) => FetchedContentMedia(
  bytes: Uint8List.fromList([1, 2, 3]),
  finalUri: Uri.parse(source),
  contentType: 'audio/mpeg',
);

class _Fetcher implements ContentMediaFetcher {
  int calls = 0;
  Completer<FetchedContentMedia>? gate;
  Object? failure;

  @override
  Future<FetchedContentMedia> fetch(Object? source) async {
    calls++;
    if (failure != null) throw failure!;
    return gate == null ? _media(source.toString()) : gate!.future;
  }
}
