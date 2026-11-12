import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage/secure_storage.dart';
import '../domain/story_reading_bookmark.dart';

abstract interface class StoryReadingBookmarkStore {
  Future<List<StoryReadingBookmark>> readAll({
    required String parentId,
    required String profileId,
  });

  Future<void> save({
    required String parentId,
    required String profileId,
    required StoryReadingBookmark bookmark,
  });

  Future<void> remove({
    required String parentId,
    required String profileId,
    required String storyId,
  });
}

class SecureStoryReadingBookmarkStore implements StoryReadingBookmarkStore {
  SecureStoryReadingBookmarkStore({FlutterSecureStorage? storage})
    : _storage = storage ?? kingdomKidsSecureStorage;

  final FlutterSecureStorage _storage;
  // Home and readers create separate store instances. Serialize mutations to
  // avoid one unfinished story overwriting another's read-modify-write.
  static final Map<String, Future<void>> _writes = {};

  String _key(String parentId, String profileId) =>
      'kingdom_kids.story_reading.v1.'
      '${base64Url.encode(utf8.encode(jsonEncode([parentId, profileId])))}';

  Future<List<StoryReadingBookmark>> _read(String key) async {
    final raw = await _storage.read(key: key);
    if (raw == null) return [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return [];
    }
    if (decoded is! List) return [];
    final stories = <String, StoryReadingBookmark>{};
    for (final item in decoded) {
      final bookmark = StoryReadingBookmark.fromJson(item);
      if (bookmark != null) {
        final existing = stories[bookmark.storyId];
        if (existing == null ||
            bookmark.updatedAt.isAfter(existing.updatedAt)) {
          stories[bookmark.storyId] = bookmark;
        }
      }
    }
    return stories.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Future<List<StoryReadingBookmark>> readAll({
    required String parentId,
    required String profileId,
  }) async {
    if (parentId.isEmpty || profileId.isEmpty) return const [];
    final key = _key(parentId, profileId);
    await _writes[key];
    try {
      return await _read(key);
    } catch (_) {
      // Local bookmarks must not prevent stories or Home from opening.
      return const [];
    }
  }

  Future<void> _mutate(
    String parentId,
    String profileId,
    void Function(List<StoryReadingBookmark>) change,
  ) {
    if (parentId.isEmpty || profileId.isEmpty) return Future.value();
    final key = _key(parentId, profileId);
    final next = (_writes[key] ?? Future<void>.value()).then((_) async {
      try {
        final bookmarks = await _read(key);
        change(bookmarks);
        await _storage.write(
          key: key,
          value: jsonEncode(
            bookmarks.map((bookmark) => bookmark.toJson()).toList(),
          ),
        );
      } catch (_) {
        // Do not replace inaccessible storage with an empty collection, or
        // turn a reading session into a save/XP error.
      }
    });
    _writes[key] = next;
    return next;
  }

  @override
  Future<void> save({
    required String parentId,
    required String profileId,
    required StoryReadingBookmark bookmark,
  }) => _mutate(parentId, profileId, (bookmarks) {
    if (bookmarks.any(
      (saved) =>
          saved.storyId == bookmark.storyId &&
          saved.updatedAt.isAfter(bookmark.updatedAt),
    )) {
      return;
    }
    bookmarks.removeWhere((saved) => saved.storyId == bookmark.storyId);
    if (bookmark.storyId.isNotEmpty) bookmarks.add(bookmark);
  });

  @override
  Future<void> remove({
    required String parentId,
    required String profileId,
    required String storyId,
  }) => _mutate(parentId, profileId, (bookmarks) {
    bookmarks.removeWhere((bookmark) => bookmark.storyId == storyId);
  });
}

class MemoryStoryReadingBookmarkStore implements StoryReadingBookmarkStore {
  final Map<String, Map<String, StoryReadingBookmark>> _bookmarks = {};

  String _scope(String parentId, String profileId) =>
      jsonEncode([parentId, profileId]);

  @override
  Future<List<StoryReadingBookmark>> readAll({
    required String parentId,
    required String profileId,
  }) async =>
      (_bookmarks[_scope(parentId, profileId)]?.values.toList() ?? [])
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<void> save({
    required String parentId,
    required String profileId,
    required StoryReadingBookmark bookmark,
  }) async {
    final scoped = _bookmarks[_scope(parentId, profileId)] ??= {};
    final previous = scoped[bookmark.storyId];
    if (previous != null && previous.updatedAt.isAfter(bookmark.updatedAt)) {
      return;
    }
    scoped[bookmark.storyId] = bookmark;
  }

  @override
  Future<void> remove({
    required String parentId,
    required String profileId,
    required String storyId,
  }) async {
    _bookmarks[_scope(parentId, profileId)]?.remove(storyId);
  }
}
