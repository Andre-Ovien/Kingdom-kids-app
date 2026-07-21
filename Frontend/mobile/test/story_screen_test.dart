import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/domain/parent_settings.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/stories_screen.dart';
import 'package:mobile/features/stories/presentation/story_detail_screen.dart';

void main() {
  testWidgets('library loads backend stories, searches, and routes by slug', (
    tester,
  ) async {
    final repository = _FakeStoryRepository(
      stories: [_previewDavid, _previewJonah],
      detail: _detailedDavid,
    );
    Object? routedArguments;

    await tester.pumpWidget(
      MaterialApp(
        home: StoriesScreen(
          repository: repository,
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
        onGenerateRoute: (settings) {
          routedArguments = settings.arguments;
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Detail route reached')),
            settings: settings,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('David & Goliath'), findsOneWidget);
    expect(find.text('Jonah and the Big Fish'), findsOneWidget);
    expect(find.textContaining('STORY CLUB'), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
    expect(repository.listCalls, 1);

    await tester.enterText(
      find.byKey(const Key('story-search-field')),
      'Jonah',
    );
    await tester.pump();
    expect(find.text('David & Goliath'), findsNothing);
    expect(find.text('Jonah and the Big Fish'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('story-search-field')), '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('story-card-david-and-goliath')));
    await tester.pumpAndSettle();

    expect(find.text('Detail route reached'), findsOneWidget);
    expect((routedArguments! as StoryDetail).slug, 'david-and-goliath');
  });

  testWidgets('library shows an API error and retries successfully', (
    tester,
  ) async {
    final repository = _FakeStoryRepository(
      stories: [_previewDavid],
      detail: _detailedDavid,
      listFailuresRemaining: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoriesScreen(
          repository: repository,
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The story service is resting.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('story-library-retry-button')));
    await tester.pumpAndSettle();

    expect(find.text('David & Goliath'), findsOneWidget);
    expect(repository.listCalls, 2);
  });

  testWidgets('library story-world chips filter the backend catalogue', (
    tester,
  ) async {
    final repository = _FakeStoryRepository(
      stories: [_previewDavid, _previewJonah],
      detail: _detailedDavid,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoriesScreen(
          repository: repository,
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('story-category-rail')), findsOneWidget);
    expect(find.byKey(const Key('story-category-Mercy')), findsOneWidget);

    await tester.tap(find.byKey(const Key('story-category-Mercy')));
    await tester.pumpAndSettle();

    expect(find.text('David & Goliath'), findsNothing);
    expect(find.text('Jonah and the Big Fish'), findsOneWidget);
    expect(repository.listCalls, 1);
  });

  testWidgets('library keeps saved stories visible after a refresh error', (
    tester,
  ) async {
    final repository = _FakeStoryRepository(
      stories: [_previewDavid],
      detail: _detailedDavid,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoriesScreen(
          repository: repository,
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    repository.listFailuresRemaining = 1;

    tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show();
    await tester.pumpAndSettle();

    expect(find.text('David & Goliath'), findsOneWidget);
    expect(find.text('SHOWING SAVED STORIES'), findsOneWidget);
    expect(find.text('The story service is resting.'), findsOneWidget);
    expect(repository.listCalls, 2);
  });

  testWidgets('library remains usable on a compact screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: StoriesScreen(
          repository: _FakeStoryRepository(
            stories: [_previewDavid, _previewJonah],
            detail: _detailedDavid,
          ),
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('story-search-field')), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Featured story: David & Goliath. Courage. 4 min. Open story.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail loads full text and opens the separate read-along flow', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(
      const AuthSession(
        parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
        accessToken: 'access-token',
        profiles: [
          KidProfile(
            id: 'kid-1',
            parentId: 'parent-1',
            displayName: 'Ada',
            avatarKey: 'dove',
          ),
        ],
      ),
    );
    await store.writeSelectedKidId('kid-1');
    final repository = _FakeStoryRepository(
      stories: [_previewDavid],
      detail: _detailedDavid,
    );
    final settingsRepository = _FakeParentalControlsRepository(
      _readerSettings(),
    );
    String? routedName;
    Object? routedArguments;

    await tester.pumpWidget(
      MaterialApp(
        home: StoryDetailScreen(
          story: _previewDavid,
          repository: repository,
          authRepository: AuthRepository(sessionStore: store),
          settingsRepository: settingsRepository,
        ),
        onGenerateRoute: (settings) {
          routedName = settings.name;
          routedArguments = settings.arguments;
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Read along reached')),
            settings: settings,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.detailSlugs, ['david-and-goliath']);
    expect(find.byKey(const Key('story-read-along-card')), findsNothing);
    expect(find.text('Watch every word light up.'), findsNothing);
    expect(
      find.text(
        'Pick a story buddy, press play, and follow the words together.',
      ),
      findsNothing,
    );
    expect(find.byIcon(Icons.star_rounded), findsNothing);

    final readAlongButton = tester.widget<IconButton>(
      find.byKey(const Key('story-read-along-button')),
    );
    expect(readAlongButton.tooltip, 'Open Read Along');
    expect(readAlongButton.onPressed, isNotNull);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

    await _scrollStoryDetailTo(
      tester,
      find.byKey(const Key('story-reading-text')),
    );
    expect(find.text(_detailedDavid.body), findsOneWidget);

    await tester.tap(find.byKey(const Key('story-read-along-button')));
    await tester.pumpAndSettle();

    expect(find.text('Read along reached'), findsOneWidget);
    expect(routedName, AppRoutes.storyReadAlong);
    expect((routedArguments! as StoryDetail).body, _detailedDavid.body);
    expect(settingsRepository.profileIds, ['kid-1']);
  });

  testWidgets('detail applies the saved extra-large story text size', (
    tester,
  ) async {
    final store = await _selectedKidStore();
    final settingsRepository = _FakeParentalControlsRepository(
      _readerSettings(storyTextScale: StoryTextScale.extraLarge),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoryDetailScreen(
          story: _previewDavid,
          repository: _FakeStoryRepository(
            stories: [_previewDavid],
            detail: _detailedDavid,
          ),
          authRepository: AuthRepository(sessionStore: store),
          settingsRepository: settingsRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollStoryDetailTo(
      tester,
      find.byKey(const Key('story-reading-text')),
    );
    final readingText = tester.widget<Text>(
      find.byKey(const Key('story-reading-text')),
    );
    expect(readingText.style?.fontSize, closeTo(22.4, 0.001));
    expect(settingsRepository.profileIds, ['kid-1']);
  });

  testWidgets(
    'detail and top read-along control fit a compact large-text phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: StoryDetailScreen(
            story: _previewDavid,
            repository: _FakeStoryRepository(
              stories: [_previewDavid],
              detail: _detailedDavid,
            ),
            authRepository: AuthRepository(
              sessionStore: MemoryAuthSessionStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('story-read-along-card')), findsNothing);
      final backButton = find.widgetWithIcon(
        IconButton,
        Icons.arrow_back_ios_new_rounded,
      );
      final readAlongButton = find.byKey(const Key('story-read-along-button'));
      final backRect = tester.getRect(backButton);
      final readAlongRect = tester.getRect(readAlongButton);
      expect(backRect.size, const Size.square(48));
      expect(readAlongRect.size, const Size.square(48));
      expect(readAlongRect.center.dy, closeTo(backRect.center.dy, 0.01));
      await _scrollStoryDetailTo(
        tester,
        find.byKey(const Key('story-reading-text')),
      );
      expect(find.text(_detailedDavid.body), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail labels a preview as Summary and retries full text', (
    tester,
  ) async {
    final repository = _FakeStoryRepository(
      stories: [_previewDavid],
      detail: _detailedDavid,
      detailFailuresRemaining: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoryDetailScreen(
          story: _previewDavid,
          repository: repository,
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The full story could not be loaded.'), findsOneWidget);
    expect(find.byKey(const Key('story-detail-retry-button')), findsOneWidget);
    await _scrollStoryDetailTo(
      tester,
      find.byKey(const Key('story-summary-text')),
    );
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text(_previewDavid.summary), findsOneWidget);
    expect(find.text('The story'), findsNothing);
    expect(find.byKey(const Key('story-reading-text')), findsNothing);

    await _scrollStoryDetailTo(
      tester,
      find.byKey(const Key('story-detail-retry-button')),
      delta: -260,
    );
    await tester.tap(find.byKey(const Key('story-detail-retry-button')));
    await tester.pumpAndSettle();

    expect(repository.detailSlugs, ['david-and-goliath', 'david-and-goliath']);
    await _scrollStoryDetailTo(
      tester,
      find.byKey(const Key('story-reading-text')),
    );
    expect(find.text('The story'), findsOneWidget);
    expect(find.text(_detailedDavid.body), findsOneWidget);
  });

  testWidgets('detail waits for full story text before opening read along', (
    tester,
  ) async {
    final repository = _FakeStoryRepository(
      stories: [_previewDavid],
      detail: _summaryOnlyWithNarration,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoryDetailScreen(
          story: _previewDavid,
          repository: repository,
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollStoryDetailTo(
      tester,
      find.byKey(const Key('story-summary-text')),
    );
    expect(find.text('Summary'), findsOneWidget);
    expect(find.byKey(const Key('story-read-along-card')), findsNothing);
    final readAlongButton = tester.widget<IconButton>(
      find.byKey(const Key('story-read-along-button')),
    );
    expect(readAlongButton.tooltip, 'Read Along is unavailable');
    expect(readAlongButton.onPressed, isNull);
  });
}

Future<void> _scrollStoryDetailTo(
  WidgetTester tester,
  Finder target, {
  double delta = 260,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.descendant(
      of: find.byKey(const Key('story-detail-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
}

const _previewDavid = StoryDetail(
  id: 'story-1',
  slug: 'david-and-goliath',
  title: 'David & Goliath',
  author: 'Kingdom Kids',
  category: 'Courage',
  summary: 'Faith can be bigger than fear.',
  estimatedReadSeconds: 240,
);

const _previewJonah = StoryDetail(
  id: 'story-2',
  slug: 'jonah-and-the-big-fish',
  title: 'Jonah and the Big Fish',
  author: 'Kingdom Kids',
  category: 'Mercy',
  summary: 'A story about second chances.',
  estimatedReadSeconds: 240,
);

const _detailedDavid = StoryDetail(
  id: 'story-1',
  slug: 'david-and-goliath',
  title: 'David & Goliath',
  author: 'Kingdom Kids',
  category: 'Courage',
  summary: 'Faith can be bigger than fear.',
  body: 'David trusted God, stepped forward, and remembered he was not alone.',
  estimatedReadSeconds: 240,
  narrations: [
    StoryNarration(
      avatarKey: 'lion',
      voiceKey: 'kai',
      characterName: 'Kai',
      voiceDescription: 'Warm and adventurous',
      locale: 'en-GB',
      speechRate: 0.42,
      pitch: 0.92,
      status: 'device_tts',
      audioAvailable: false,
    ),
    StoryNarration(
      avatarKey: 'dove',
      voiceKey: 'nia',
      characterName: 'Nia',
      voiceDescription: 'Gentle and comforting',
      locale: 'en-NG',
      speechRate: 0.4,
      pitch: 1.04,
      status: 'device_tts',
      audioAvailable: false,
    ),
    StoryNarration(
      avatarKey: 'rainbow',
      voiceKey: 'zuri',
      characterName: 'Zuri',
      voiceDescription: 'Bright and joyful',
      locale: 'en-US',
      speechRate: 0.48,
      pitch: 1.12,
      status: 'device_tts',
      audioAvailable: false,
    ),
  ],
);

const _summaryOnlyWithNarration = StoryDetail(
  id: 'story-1',
  slug: 'david-and-goliath',
  title: 'David & Goliath',
  author: 'Kingdom Kids',
  category: 'Courage',
  summary: 'Faith can be bigger than fear.',
  estimatedReadSeconds: 240,
  narrations: [
    StoryNarration(
      avatarKey: 'lion',
      voiceKey: 'kai',
      characterName: 'Kai',
      voiceDescription: 'Warm and adventurous',
      locale: 'en-GB',
      speechRate: 0.42,
      pitch: 0.92,
      status: 'device_tts',
      audioAvailable: false,
    ),
  ],
);

Future<MemoryAuthSessionStore> _selectedKidStore() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(
    const AuthSession(
      parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
      accessToken: 'access-token',
      profiles: [
        KidProfile(
          id: 'kid-1',
          parentId: 'parent-1',
          displayName: 'Ada',
          avatarKey: 'dove',
        ),
      ],
    ),
  );
  await store.writeSelectedKidId('kid-1');
  return store;
}

ParentSettings _readerSettings({
  StoryTextScale storyTextScale = StoryTextScale.comfortable,
  bool narrationEnabled = true,
}) {
  return ParentSettings(
    profileId: 'kid-1',
    storyTextScale: storyTextScale,
    narrationEnabled: narrationEnabled,
    updatedAt: DateTime.utc(2026, 7, 15, 12),
  );
}

final class _FakeParentalControlsRepository
    implements ParentalControlsRepository {
  _FakeParentalControlsRepository(this.settings);

  final ParentSettings settings;
  final List<String> profileIds = [];

  @override
  Future<ParentSettings> fetchSettings({required String profileId}) async {
    profileIds.add(profileId);
    return settings;
  }

  @override
  Future<ParentSettings> updateSettings({
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  }) {
    throw UnimplementedError();
  }
}

final class _FakeStoryRepository implements StoryRepository {
  _FakeStoryRepository({
    required this.stories,
    required this.detail,
    this.listFailuresRemaining = 0,
    this.detailFailuresRemaining = 0,
  });

  final List<StoryDetail> stories;
  final StoryDetail detail;
  int listFailuresRemaining;
  int detailFailuresRemaining;
  int listCalls = 0;
  final detailSlugs = <String>[];

  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async {
    listCalls++;
    if (listFailuresRemaining > 0) {
      listFailuresRemaining--;
      throw const AppException('The story service is resting.');
    }
    return stories;
  }

  @override
  Future<StoryDetail> fetchStory(String slug) async {
    detailSlugs.add(slug);
    if (detailFailuresRemaining > 0) {
      detailFailuresRemaining--;
      throw const AppException('The full story could not be loaded.');
    }
    return detail;
  }
}
