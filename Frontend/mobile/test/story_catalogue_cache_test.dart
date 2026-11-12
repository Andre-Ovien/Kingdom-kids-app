import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';

void main() {
  test('overlapping and recent catalogue requests share one load', () async {
    final cache = StoryCatalogueCache();
    final pending = Completer<List<StoryDetail>>();
    var calls = 0;
    Future<List<StoryDetail>> load() {
      calls++;
      return pending.future;
    }

    final first = cache.fetch(('api', 'token', '', ''), load);
    final second = cache.fetch(('api', 'token', '', ''), load);
    expect(calls, 1);
    pending.complete([]);
    await Future.wait([first, second]);
    await cache.fetch(('api', 'token', '', ''), load);
    expect(calls, 1);
  });

  test('tokens and filters do not share results', () async {
    final cache = StoryCatalogueCache();
    var calls = 0;
    Future<List<StoryDetail>> load() async {
      calls++;
      return [];
    }

    await cache.fetch(('api', 'parent-one-token', '', ''), load);
    await cache.fetch(('api', 'parent-two-token', '', ''), load);
    await cache.fetch(('api', 'parent-one-token', 'Noah', ''), load);
    expect(calls, 3);
  });

  test(
    'expired and evicted entries reload and failures are retryable',
    () async {
      var now = DateTime(2026);
      final cache = StoryCatalogueCache(maxEntries: 1, now: () => now);
      var calls = 0;
      Future<List<StoryDetail>> load() async {
        calls++;
        return [];
      }

      await cache.fetch('one', load);
      now = now.add(const Duration(seconds: 31));
      await cache.fetch('one', load);
      await cache.fetch('two', load);
      await cache.fetch('one', load);
      expect(calls, 4);
      await expectLater(
        cache.fetch('failed', () async => throw StateError('offline')),
        throwsStateError,
      );
      await cache.fetch('failed', load);
      expect(calls, 5);
      await expectLater(
        cache.fetch('synchronous-error', () => throw StateError('offline')),
        throwsStateError,
      );
      await cache.fetch('synchronous-error', load);
      expect(calls, 6);
    },
  );
}
