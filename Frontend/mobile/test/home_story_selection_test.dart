import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/home/domain/home_story_selection.dart';
import 'package:mobile/features/stories/data/story_reading_bookmark_store.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/domain/story_reading_bookmark.dart';

void main() {
  final today = DateTime(2026, 11, 11, 9);
  const stories = [_joseph, _ruth, _noah];

  StoryDetail? daily({
    List<StoryDetail> catalogue = stories,
    String child = 'kid-one',
    DateTime? at,
  }) => selectDailyHomeStory(
    stories: catalogue,
    profileId: child,
    localDate: at ?? today,
  );

  test('daily choice survives rebuilds, time changes, and catalogue order', () {
    final selected = daily();
    expect(selected, isNotNull);
    expect(daily(), same(selected));
    expect(daily(at: DateTime(2026, 11, 11, 23, 59)), same(selected));
    expect(daily(catalogue: stories.reversed.toList()), same(selected));
  });

  test('each next civil day rotates through all backend stories', () {
    final picks = [
      for (var day = 11; day <= 14; day++)
        daily(at: DateTime(2026, 11, day))!.id,
    ];
    expect(picks.take(3).toSet(), hasLength(3));
    expect(picks[3], picks[0]);
    expect(daily(at: DateTime.utc(2026, 11, 11))!.id, picks[0]);
  });

  test('child identity seeds the daily choice independently', () {
    expect(daily(child: 'kid-a')!.id, isNot(daily(child: 'kid-b')!.id));
    expect(daily(child: 'kid-a'), same(daily(child: 'kid-a')));
  });

  test('one-story catalogue remains usable for rereading', () {
    expect(daily(catalogue: [_ruth]), same(_ruth));
    expect(daily(catalogue: [_ruth], at: DateTime(2026, 11, 12)), same(_ruth));
  });

  test('empty catalogue or absent active child has no recommendation', () {
    expect(daily(catalogue: []), isNull);
    expect(daily(child: '  '), isNull);
  });

  test(
    'invalid, unavailable, and duplicate entries do not add daily slots',
    () {
      const unavailable = StoryDetail(
        id: 'lost',
        slug: 'lost-sheep',
        title: 'Lost Sheep',
        author: '',
        category: '',
      );
      const noId = StoryDetail(
        slug: 'other',
        title: 'Other',
        author: '',
        category: '',
      );
      const noSlug = StoryDetail(
        id: 'other',
        title: 'Other',
        author: '',
        category: '',
      );
      expect(
        daily(catalogue: [_ruth, _ruth, unavailable, noId, noSlug]),
        same(_ruth),
      );
    },
  );

  test('unstarted stories are not shown as Continue reading', () {
    expect(
      unfinishedHomeStories(
        stories: stories,
        bookmarks: [_bookmark(_ruth, offset: 0)],
      ),
      isEmpty,
    );
    expect(unfinishedHomeStories(stories: stories, bookmarks: []), isEmpty);
  });

  test('saved visual progress and real heard coverage are resumable', () {
    expect(
      unfinishedHomeStories(
        stories: stories,
        bookmarks: [
          _bookmark(_joseph, offset: 7),
          _bookmark(_ruth, offset: 0, heard: [StoryHeardRange(0, 5)]),
        ],
      ).map((story) => story.id),
      ['joseph', 'ruth'],
    );
  });

  test('catalogue cards without body retain valid reader bookmarks', () {
    final bookmark = _bookmark(_ruth, offset: 7);
    expect(bookmark.hasCurrentBody(_ruth), isFalse);
    expect(unfinishedHomeStories(stories: [_ruth], bookmarks: [bookmark]), [
      _ruth,
    ]);
  });

  test(
    'latest bookmark wins and resume entries are ordered by recent reading',
    () {
      expect(
        unfinishedHomeStories(
          stories: stories,
          bookmarks: [
            _bookmark(_ruth, offset: 7, day: 9),
            _bookmark(_ruth, offset: 8, day: 11),
            _bookmark(_joseph, offset: 7, day: 10),
          ],
        ).map((story) => story.id),
        ['ruth', 'joseph'],
      );
    },
  );

  test('removed catalogue stories and malformed heard ranges stay out', () {
    expect(
      unfinishedHomeStories(
        stories: [_ruth],
        bookmarks: [
          _bookmark(_joseph, offset: 7),
          _bookmark(_ruth, offset: 0, heard: [StoryHeardRange(-1, 5)]),
        ],
      ),
      isEmpty,
    );
  });

  test(
    'real scoped bookmarks disappear after completion without crossing child',
    () async {
      final store = MemoryStoryReadingBookmarkStore();
      for (final child in ['one', 'two']) {
        await store.save(
          parentId: 'parent',
          profileId: child,
          bookmark: _bookmark(_ruth, offset: 7),
        );
      }
      await store.remove(
        parentId: 'parent',
        profileId: 'one',
        storyId: _ruth.id,
      );
      final first = await store.readAll(parentId: 'parent', profileId: 'one');
      final second = await store.readAll(parentId: 'parent', profileId: 'two');
      expect(
        unfinishedHomeStories(stories: stories, bookmarks: first),
        isEmpty,
      );
      expect(unfinishedHomeStories(stories: stories, bookmarks: second), [
        _ruth,
      ]);
      expect(daily(child: 'one'), isNotNull);
    },
  );
}

StoryReadingBookmark _bookmark(
  StoryDetail story, {
  required int offset,
  int day = 11,
  List<StoryHeardRange> heard = const [],
}) => StoryReadingBookmark(
  storyId: story.id,
  storySlug: story.slug,
  bodyFingerprint: '100:reader-edition',
  textOffset: offset,
  updatedAt: DateTime(2026, 11, day),
  heardRanges: heard,
);

const _joseph = StoryDetail(
  id: 'joseph',
  slug: 'joseph',
  title: 'Joseph',
  author: '',
  category: '',
);
const _ruth = StoryDetail(
  id: 'ruth',
  slug: 'ruth',
  title: 'Ruth',
  author: '',
  category: '',
);
const _noah = StoryDetail(
  id: 'noah',
  slug: 'noah',
  title: 'Noah',
  author: '',
  category: '',
);
