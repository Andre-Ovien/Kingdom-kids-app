import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/home/presentation/home_screen.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';

void main() {
  testWidgets('home renders backend sections and filters backend categories', (
    tester,
  ) async {
    final repository = _FakeHomeStoryRepository(stories: _stories);

    await tester.pumpWidget(_homeApp(repository));
    await tester.pumpAndSettle();

    expect(find.text('Featured Mercy'), findsOneWidget);
    expect(find.text('A backend-provided featured summary.'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Story picks'),
      280,
      scrollable: _homeScrollable,
    );
    await tester.pump();

    expect(find.text('Story picks'), findsOneWidget);
    expect(find.text('Faith One'), findsOneWidget);
    expect(find.text('Courage One'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('More stories'),
      220,
      scrollable: _homeScrollable,
    );
    await tester.pump();

    expect(find.text('More stories'), findsOneWidget);
    expect(find.text('Continue reading'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('home-category-Courage')),
      -90,
      scrollable: _homeScrollable,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('home-category-Courage')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-category-Courage')));
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('Courage One'),
      240,
      scrollable: _homeScrollable,
    );
    await tester.pump();

    expect(find.text('Courage One'), findsOneWidget);
    expect(find.text('Faith One'), findsNothing);
    expect(find.text('Faith Two'), findsNothing);
    expect(find.text('More stories'), findsNothing);
    expect(repository.listCalls, 1);
  });

  testWidgets('home exposes an API failure and retries the backend', (
    tester,
  ) async {
    final repository = _FakeHomeStoryRepository(
      stories: _stories,
      failuresRemaining: 1,
    );

    await tester.pumpWidget(_homeApp(repository));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-stories-error')), findsOneWidget);
    expect(find.text('Stories couldn\'t load'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-stories-retry')));
    await tester.pumpAndSettle();

    expect(find.text('Featured Mercy'), findsOneWidget);
    expect(find.byKey(const Key('home-stories-error')), findsNothing);
    expect(repository.listCalls, 2);
  });

  testWidgets('home exposes a true empty catalogue state', (tester) async {
    await tester.pumpWidget(
      _homeApp(_FakeHomeStoryRepository(stories: const [])),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-stories-empty')), findsOneWidget);
    expect(find.text('New stories are coming soon'), findsOneWidget);
  });

  testWidgets('home adventure doors move directly to each app world', (
    tester,
  ) async {
    final repository = _FakeHomeStoryRepository(stories: _stories);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          storyRepository: repository,
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: Text('Reached ${settings.name}')),
          settings: settings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-adventure-play')));
    await tester.pumpAndSettle();

    expect(find.text('Reached /games'), findsOneWidget);
  });

  testWidgets('home greets the active profile without duplicating its avatar', (
    tester,
  ) async {
    const profile = KidProfile(
      id: 'kid-1',
      parentId: 'parent-1',
      displayName: 'Ada',
      avatarKey: 'dove',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          storyRepository: _FakeHomeStoryRepository(stories: _stories),
          authRepository: _FakeHomeAuthRepository(profile),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hey, Ada!'), findsOneWidget);
    expect(find.byKey(const Key('home-character-wave')), findsNothing);
    expect(find.byKey(const Key('home-profile-avatar')), findsOneWidget);
  });

  testWidgets('home stays usable on a compact phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: HomeScreen(
          storyRepository: _FakeHomeStoryRepository(stories: _stories),
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('home-adventure-read')),
      180,
      scrollable: _homeScrollable,
    );
    await tester.pump();

    expect(find.byKey(const Key('home-adventure-read')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('home-featured-carousel')),
      260,
      scrollable: _homeScrollable,
    );
    await tester.pump();

    expect(find.byKey(const Key('home-featured-carousel')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.fling(
      find.byKey(const Key('home-scroll')),
      const Offset(0, -700),
      1200,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('home doors and profile entry have descriptive semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _homeApp(_FakeHomeStoryRepository(stories: _stories)),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('READ adventures'), findsOneWidget);
    expect(find.bySemanticsLabel('WATCH adventures'), findsOneWidget);
    expect(find.bySemanticsLabel('PLAY adventures'), findsOneWidget);
    expect(find.bySemanticsLabel('Open my profile'), findsOneWidget);
    semantics.dispose();
  });
}

Finder get _homeScrollable => find
    .descendant(
      of: find.byKey(const Key('home-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

Widget _homeApp(StoryRepository repository) {
  return MaterialApp(
    home: HomeScreen(
      storyRepository: repository,
      authRepository: AuthRepository(sessionStore: MemoryAuthSessionStore()),
    ),
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Story detail reached')),
      settings: settings,
    ),
  );
}

const _stories = [
  StoryDetail(
    slug: 'featured-mercy',
    title: 'Featured Mercy',
    author: 'Kingdom Kids',
    category: 'Mercy',
    summary: 'A backend-provided featured summary.',
    estimatedReadSeconds: 180,
    isFeatured: true,
  ),
  StoryDetail(
    slug: 'faith-one',
    title: 'Faith One',
    author: 'Kingdom Kids',
    category: 'Faith',
    summary: 'The first backend faith story.',
    estimatedReadSeconds: 125,
  ),
  StoryDetail(
    slug: 'courage-one',
    title: 'Courage One',
    author: 'Kingdom Kids',
    category: 'Courage',
    summary: 'A courageous backend story.',
    estimatedReadSeconds: 240,
  ),
  StoryDetail(
    slug: 'faith-two',
    title: 'Faith Two',
    author: 'Kingdom Kids',
    category: 'Faith',
    summary: 'Another backend faith story.',
    estimatedReadSeconds: 300,
  ),
  StoryDetail(
    slug: 'adventure-one',
    title: 'Adventure One',
    author: 'Kingdom Kids',
    category: 'Adventure',
    summary: 'A backend adventure story.',
    estimatedReadSeconds: 210,
  ),
];

final class _FakeHomeStoryRepository implements StoryRepository {
  _FakeHomeStoryRepository({required this.stories, this.failuresRemaining = 0});

  final List<StoryDetail> stories;
  int failuresRemaining;
  int listCalls = 0;

  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async {
    listCalls += 1;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw const AppException('The story service is unavailable.');
    }
    return stories;
  }

  @override
  Future<StoryDetail> fetchStory(String slug) async {
    return stories.firstWhere((story) => story.slug == slug);
  }
}

final class _FakeHomeAuthRepository extends AuthRepository {
  _FakeHomeAuthRepository(this.profile);

  final KidProfile? profile;

  @override
  Future<KidProfile?> currentKid() async => profile;
}
