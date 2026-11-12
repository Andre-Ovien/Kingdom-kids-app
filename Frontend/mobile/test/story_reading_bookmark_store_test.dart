import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/stories/data/story_reading_bookmark_store.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/domain/story_reading_bookmark.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'multiple stories survive a new store instance and order latest first',
    () async {
      final store = SecureStoryReadingBookmarkStore();
      await Future.wait([
        store.save(
          parentId: 'parent',
          profileId: 'child',
          bookmark: _bookmark('one', 1),
        ),
        store.save(
          parentId: 'parent',
          profileId: 'child',
          bookmark: _bookmark('two', 2),
        ),
        store.save(
          parentId: 'parent',
          profileId: 'child',
          bookmark: _bookmark('three', 3),
        ),
      ]);
      final restarted = SecureStoryReadingBookmarkStore();
      final saved = await restarted.readAll(
        parentId: 'parent',
        profileId: 'child',
      );
      expect(saved.map((bookmark) => bookmark.storyId), [
        'three',
        'two',
        'one',
      ]);
      expect(saved.first.textOffset, 3);
      expect(saved.first.heardRanges.single.end, 3);
      await restarted.save(
        parentId: 'parent',
        profileId: 'child',
        bookmark: _bookmark('one', 4),
      );
      expect(
        (await store.readAll(
          parentId: 'parent',
          profileId: 'child',
        )).map((bookmark) => bookmark.storyId),
        ['one', 'three', 'two'],
      );
    },
  );

  test(
    'an older delayed reader cannot replace a newer reading position',
    () async {
      for (final store in <StoryReadingBookmarkStore>[
        SecureStoryReadingBookmarkStore(),
        MemoryStoryReadingBookmarkStore(),
      ]) {
        await store.save(
          parentId: 'parent',
          profileId: 'child',
          bookmark: _bookmark('same', 4),
        );
        await store.save(
          parentId: 'parent',
          profileId: 'child',
          bookmark: _bookmark('same', 1),
        );
        expect(
          (await store.readAll(
            parentId: 'parent',
            profileId: 'child',
          )).single.textOffset,
          4,
        );
      }
    },
  );

  test(
    'parent and child scopes never overlap, including punctuation',
    () async {
      final store = SecureStoryReadingBookmarkStore();
      await store.save(
        parentId: 'a.b',
        profileId: 'c',
        bookmark: _bookmark('one', 1),
      );
      await store.save(
        parentId: 'a',
        profileId: 'b.c',
        bookmark: _bookmark('two', 2),
      );
      await store.save(
        parentId: 'a.b',
        profileId: 'other',
        bookmark: _bookmark('three', 3),
      );
      expect(
        (await store.readAll(parentId: 'a.b', profileId: 'c')).single.storyId,
        'one',
      );
      expect(
        (await store.readAll(parentId: 'a', profileId: 'b.c')).single.storyId,
        'two',
      );
      expect(
        (await store.readAll(
          parentId: 'a.b',
          profileId: 'other',
        )).single.storyId,
        'three',
      );
    },
  );

  test(
    'completion removes only its story and cannot resurrect queued saves',
    () async {
      final store = SecureStoryReadingBookmarkStore();
      final pending = store.save(
        parentId: 'parent',
        profileId: 'child',
        bookmark: _bookmark('one', 1),
      );
      final removal = store.remove(
        parentId: 'parent',
        profileId: 'child',
        storyId: 'one',
      );
      await store.save(
        parentId: 'parent',
        profileId: 'child',
        bookmark: _bookmark('two', 2),
      );
      await Future.wait([pending, removal]);
      final saved = await SecureStoryReadingBookmarkStore().readAll(
        parentId: 'parent',
        profileId: 'child',
      );
      expect(saved.single.storyId, 'two');
    },
  );

  test('malformed values are ignored and a new reading can be saved', () async {
    const storage = FlutterSecureStorage();
    final key =
        'kingdom_kids.story_reading.v1.${base64Url.encode(utf8.encode(jsonEncode(['parent', 'child'])))}';
    await storage.write(key: key, value: 'not json');
    final store = SecureStoryReadingBookmarkStore(storage: storage);
    expect(
      await store.readAll(parentId: 'parent', profileId: 'child'),
      isEmpty,
    );
    await store.save(
      parentId: 'parent',
      profileId: 'child',
      bookmark: _bookmark('one', 1),
    );
    expect(
      (await store.readAll(
        parentId: 'parent',
        profileId: 'child',
      )).single.storyId,
      'one',
    );
  });

  test(
    'visual reading mode persists and older bookmarks default to read along',
    () {
      final bookmark = StoryReadingBookmark.forStory(
        story: _story('one', 'Read it.'),
        textOffset: 1,
        updatedAt: DateTime.utc(2026),
        readingMode: StoryReadingMode.read,
      );
      expect(
        StoryReadingBookmark.fromJson(bookmark.toJson())!.readingMode,
        StoryReadingMode.read,
      );
      final oldJson = bookmark.toJson()..remove('reading_mode');
      expect(
        StoryReadingBookmark.fromJson(oldJson)!.readingMode,
        StoryReadingMode.readAlong,
      );
    },
  );

  test(
    'changed editions restart safely and catalogue identity needs no body',
    () {
      final original = _story('one', 'Original text to read.');
      final saved = StoryReadingBookmark.forStory(
        story: original,
        textOffset: 10,
        updatedAt: DateTime.utc(2026),
      );
      expect(saved.isForStory(_story('one', '')), isTrue);
      expect(saved.resumeOffsetFor(original), 10);
      expect(saved.resumeOffsetFor(_story('one', 'Edited text.')), 0);
      expect(saved.resumeOffsetFor(_story('two', original.body)), 0);
      final decoded = StoryReadingBookmark.fromJson(saved.toJson())!;
      expect(decoded.resumeOffsetFor(original), 10);
    },
  );
}

StoryDetail _story(String id, String body) => StoryDetail(
  id: id,
  slug: id,
  title: id,
  author: 'Kingdom Kids',
  category: 'Bible',
  body: body,
);

StoryReadingBookmark _bookmark(String id, int second) =>
    StoryReadingBookmark.forStory(
      story: _story(id, 'A story with enough text to save.'),
      textOffset: second,
      updatedAt: DateTime.utc(2026, 11, 8, 10, 0, second),
      heardRanges: [StoryHeardRange(0, second)],
    );
