import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/home/presentation/continue_reading_carousel.dart';
import 'package:mobile/features/home/presentation/home_screen.dart';
import 'package:mobile/features/home/presentation/home_story_card.dart';
import 'package:mobile/features/milestones/data/level_milestone_store.dart';
import 'package:mobile/features/stories/data/story_reading_bookmark_store.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/domain/story_read_along_arguments.dart';
import 'package:mobile/features/stories/domain/story_reading_arguments.dart';
import 'package:mobile/features/stories/domain/story_reading_bookmark.dart';
import 'package:mobile/features/streak/data/streak_reminder_service.dart';
import 'package:mobile/features/streak/data/streak_repository.dart';
import 'package:mobile/features/streak/domain/streak_claim_receipt.dart';

void main() {
  testWidgets('Home stays uncluttered when there is no unfinished story', (
    tester,
  ) async {
    await tester.pumpWidget(await _home());
    await tester.pumpAndSettle();
    expect(find.text('Continue reading'), findsNothing);
    expect(find.byType(ContinueReadingCarousel), findsNothing);
    expect(find.text('Story for the day'), findsOneWidget);
    expect(find.byKey(const Key('home-story-for-day-card')), findsOneWidget);
    expect(find.text('Ready, set, read!'), findsNothing);
  });

  testWidgets('multiple unfinished stories occupy one swipeable compact row', (
    tester,
  ) async {
    const renderDirectory = String.fromEnvironment(
      'CONTINUE_READING_RENDER_DIR',
    );
    if (renderDirectory.isNotEmpty) {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final loader = FontLoader('Avenir Next')
          ..addFont(
            File(
              '/System/Library/Fonts/Avenir Next.ttc',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await icons.load();
      });
    }
    final store = await _bookmarks();
    final repository = _Stories(includeFeatured: renderDirectory.isNotEmpty);
    await tester.pumpWidget(await _home(store: store, repository: repository));
    await tester.pumpAndSettle();
    expect(find.text('Continue reading'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    expect(find.byType(ContinueReadingCarousel), findsOneWidget);
    expect(find.text('Story for the day'), findsNothing);
    expect(find.byKey(const Key('continue-story-ruth')), findsOneWidget);
    expect(repository.detailCalls, 0);
    final row = find.byKey(const Key('home-continue-reading'));
    expect(tester.getSize(row).height, lessThan(200));
    expect(
      find.descendant(of: row, matching: find.byType(HomeStoryCard)),
      findsWidgets,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('home-adventure-carousel'))).dy,
      lessThan(tester.getTopLeft(find.text('Continue reading')).dy),
    );
    if (renderDirectory.isNotEmpty) {
      await tester.runAsync(() async {
        final images = tester.widgetList<Image>(find.byType(Image));
        for (final image in images) {
          await precacheImage(
            image.image,
            tester.element(find.byType(HomeScreen)),
          );
        }
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('home-resume-preview-boundary')),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(renderDirectory).create(recursive: true);
        await File(
          '$renderDirectory/home-continue-reading-v3-top.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      await tester.drag(
        find.byKey(const Key('home-scroll')),
        const Offset(0, -280),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final image in tester.widgetList<Image>(find.byType(Image))) {
          await precacheImage(
            image.image,
            tester.element(find.byType(HomeScreen)),
          );
        }
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('home-resume-preview-boundary')),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$renderDirectory/home-continue-reading-v3.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.drag(
      find.byKey(const Key('home-continue-pages')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-story-joseph')), findsOneWidget);
    expect(repository.detailCalls, 0);
  });

  testWidgets(
    'Continue fetches only the chosen full story and requests resume',
    (tester) async {
      final repository = _Stories();
      RouteSettings? opened;
      await tester.pumpWidget(
        await _home(
          store: await _bookmarks(),
          repository: repository,
          onOpen: (settings) => opened = settings,
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 0);
      await tester.tap(find.byKey(const Key('continue-story-ruth')));
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 1);
      expect(repository.requestedSlug, 'ruth');
      expect(opened?.name, AppRoutes.storyReadAlong);
      final args = opened!.arguments! as StoryReadAlongArguments;
      expect(args.story.body, _ruth.body);
      expect(args.resumeReading, isTrue);
      expect(find.text('Reader reached'), findsOneWidget);
    },
  );

  testWidgets('failed story load keeps the bookmark available for retry', (
    tester,
  ) async {
    final repository = _Stories()..failDetail = true;
    await tester.pumpWidget(
      await _home(store: await _bookmarks(), repository: repository),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('continue-story-ruth')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-continue-error')), findsOneWidget);
    expect(find.byKey(const Key('continue-story-ruth')), findsOneWidget);
    repository.failDetail = false;
    await tester.tap(find.byKey(const Key('continue-story-ruth')));
    await tester.pumpAndSettle();
    expect(repository.detailCalls, 2);
    expect(find.text('Reader reached'), findsOneWidget);
  });

  testWidgets(
    'Continue returns visual readers to the story they were reading',
    (tester) async {
      final store = MemoryStoryReadingBookmarkStore();
      await store.save(
        parentId: 'parent',
        profileId: 'kid',
        bookmark: StoryReadingBookmark.forStory(
          story: _ruth,
          textOffset: 12,
          updatedAt: DateTime(2026, 11, 8),
          readingMode: StoryReadingMode.read,
        ),
      );
      RouteSettings? opened;
      await tester.pumpWidget(
        await _home(store: store, onOpen: (settings) => opened = settings),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('continue-story-ruth')));
      await tester.pumpAndSettle();
      expect(opened?.name, AppRoutes.storyDetail);
      final arguments = opened!.arguments! as StoryReadingArguments;
      expect(arguments.story.body, _ruth.body);
      expect(arguments.resumeReading, isTrue);
    },
  );

  testWidgets('returning from reader refreshes completed bookmarks', (
    tester,
  ) async {
    final store = await _bookmarks();
    await tester.pumpWidget(await _home(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('continue-story-ruth')));
    await tester.pumpAndSettle();
    await store.remove(parentId: 'parent', profileId: 'kid', storyId: 'ruth');
    await tester.tap(find.byKey(const Key('reader-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-story-ruth')), findsNothing);
    expect(find.byKey(const Key('continue-story-joseph')), findsOneWidget);
  });

  testWidgets('bookmark row is isolated by child and authenticated parent', (
    tester,
  ) async {
    final store = await _bookmarks();
    final auth = await _auth();
    await tester.pumpWidget(await _home(store: store, auth: auth));
    await tester.pumpAndSettle();
    expect(find.byType(ContinueReadingCarousel), findsOneWidget);
    auth.profile = _otherKid;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(ContinueReadingCarousel), findsNothing);
    auth.profile = _kid.copyWith(parentId: 'another-parent');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(ContinueReadingCarousel), findsNothing);
  });

  testWidgets(
    'changing child while story loads cannot open the old child story',
    (tester) async {
      final auth = await _auth();
      final barrier = Completer<StoryDetail>();
      final repository = _Stories()..detailBarrier = barrier.future;
      await tester.pumpWidget(
        await _home(
          store: await _bookmarks(),
          auth: auth,
          repository: repository,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('continue-story-ruth')));
      await tester.pump();
      auth.profile = _otherKid;
      barrier.complete(_ruth);
      await tester.pumpAndSettle();
      expect(find.text('Reader reached'), findsNothing);
    },
  );

  testWidgets('removed stories are ignored without eager detail requests', (
    tester,
  ) async {
    final store = await _bookmarks();
    await store.save(
      parentId: 'parent',
      profileId: 'kid',
      bookmark: StoryReadingBookmark.forStory(
        story: const StoryDetail(
          id: 'retired',
          slug: 'retired',
          title: 'Retired story',
          author: '',
          category: '',
          body: 'Old text',
        ),
        textOffset: 3,
        updatedAt: DateTime(2027),
      ),
    );
    final repository = _Stories();
    await tester.pumpWidget(await _home(store: store, repository: repository));
    await tester.pumpAndSettle();
    final carousel = tester.widget<ContinueReadingCarousel>(
      find.byType(ContinueReadingCarousel),
    );
    expect(carousel.stories.map((story) => story.id), ['ruth', 'joseph']);
    expect(repository.detailCalls, 0);
  });

  testWidgets('carousel glides automatically and pauses while inactive', (
    tester,
  ) async {
    var active = true;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: ContinueReadingCarousel(
                stories: const [_ruth, _joseph],
                onContinue: (_) {},
                isActive: active,
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-story-joseph')), findsOneWidget);
    rebuild(() => active = false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(find.byKey(const Key('continue-story-joseph')), findsOneWidget);
    rebuild(() => active = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-story-ruth')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home pauses its carousel behind a modal and in background', (
    tester,
  ) async {
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
    }

    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpWidget(
      await _home(store: await _bookmarks(), disableAnimations: false),
    );
    await settle();
    final homeContext = tester.element(find.byType(HomeScreen));
    unawaited(
      showDialog<void>(
        context: homeContext,
        builder: (context) => AlertDialog(
          content: const Text('Paused for a moment'),
          actions: [
            TextButton(
              key: const Key('close-test-modal'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
    await settle();
    await tester.pump(const Duration(seconds: 20));
    PageView pages() => tester.widget<PageView>(
      find.byKey(const Key('home-continue-pages'), skipOffstage: false),
    );
    expect(pages().controller!.page, 0);
    await tester.tap(find.byKey(const Key('close-test-modal')));
    await settle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(pages().controller!.page, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle();
    expect(
      tester
          .widget<ContinueReadingCarousel>(find.byType(ContinueReadingCarousel))
          .isActive,
      isTrue,
    );
    await tester.pump(const Duration(seconds: 6));
    await settle();
    expect(pages().controller!.page, 1);
  });

  testWidgets(
    'touch pauses automatic slide and gives a fresh reading interval',
    (tester) async {
      await tester.pumpWidget(_carouselApp());
      await tester.pump(const Duration(seconds: 5));
      final touch = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('home-continue-pages'))),
      );
      await tester.pump(const Duration(seconds: 8));
      expect(find.byKey(const Key('continue-story-ruth')), findsOneWidget);
      await touch.up();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const Key('continue-story-ruth')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('continue-story-joseph')), findsOneWidget);
    },
  );

  for (final setting in ['reduced motion', 'screen reader']) {
    testWidgets('$setting keeps the card still but allows manual swipes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _carouselApp(
          disableAnimations: setting == 'reduced motion',
          accessibleNavigation: setting == 'screen reader',
        ),
      );
      await tester.pump(const Duration(seconds: 30));
      expect(find.byKey(const Key('continue-story-ruth')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('home-continue-pages')),
        const Offset(-700, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('continue-story-joseph')), findsOneWidget);
    });
  }

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('shared card fits 320px screen at ${scale}x text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_carouselApp(textScale: scale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Continue'), findsNothing);
      expect(find.byIcon(Icons.arrow_forward_rounded), findsWidgets);
    });
  }
}

Widget _carouselApp({
  bool disableAnimations = false,
  bool accessibleNavigation = false,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: disableAnimations,
      accessibleNavigation: accessibleNavigation,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ContinueReadingCarousel(
          stories: const [_ruth, _joseph],
          onContinue: (_) {},
          isActive: true,
        ),
      ),
    ),
  ),
);

Future<Widget> _home({
  bool disableAnimations = true,
  StoryReadingBookmarkStore? store,
  _Auth? auth,
  _Stories? repository,
  ValueChanged<RouteSettings>? onOpen,
}) async => RepaintBoundary(
  key: const Key('home-resume-preview-boundary'),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildKingdomKidsTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: disableAnimations,
        padding:
            const String.fromEnvironment('CONTINUE_READING_RENDER_DIR').isEmpty
            ? MediaQuery.paddingOf(context)
            : const EdgeInsets.only(top: 59, bottom: 34),
      ),
      child: child!,
    ),
    navigatorObservers: [appRouteObserver],
    home: HomeScreen(
      authRepository: auth ?? await _auth(),
      storyRepository: repository ?? _Stories(),
      bookmarkStore: store ?? MemoryStoryReadingBookmarkStore(),
      milestoneStore: MemoryLevelMilestoneStore(),
      streakRepository: _Streak(),
      streakReminderService: _Reminder(),
    ),
    onGenerateRoute: (settings) {
      onOpen?.call(settings);
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (context) => Scaffold(
          body: Column(
            children: [
              const Text('Reader reached'),
              TextButton(
                key: const Key('reader-back'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      );
    },
  ),
);

Future<_Auth> _auth() async {
  final session = MemoryAuthSessionStore();
  await session.writeSession(
    const AuthSession(
      parent: ParentAccount(id: 'parent', email: 'parent@example.test'),
      accessToken: 'test',
      profiles: [_kid, _otherKid],
    ),
  );
  return _Auth(session);
}

Future<MemoryStoryReadingBookmarkStore> _bookmarks() async {
  final store = MemoryStoryReadingBookmarkStore();
  for (final story in [_joseph, _ruth]) {
    await store.save(
      parentId: 'parent',
      profileId: 'kid',
      bookmark: StoryReadingBookmark.forStory(
        story: story,
        textOffset: 7,
        updatedAt: DateTime(2026, 11, story.id == 'ruth' ? 8 : 7),
      ),
    );
  }
  return store;
}

const _kid = KidProfile(
  id: 'kid',
  parentId: 'parent',
  displayName: 'Ada',
  avatarKey: 'lion',
);
const _otherKid = KidProfile(
  id: 'other-kid',
  parentId: 'parent',
  displayName: 'Nia',
  avatarKey: 'dove',
);
const _ruth = StoryDetail(
  id: 'ruth',
  slug: 'ruth',
  title: 'Ruth and Naomi',
  author: 'Kingdom Kids',
  category: 'Kindness',
  body: 'Ruth gathered grain and cared for Naomi.',
  summary: 'A story of kindness, courage and caring for family.',
  estimatedReadSeconds: 180,
  coverAssetKey: 'assets/images/stories/ruth-and-naomi-storybook-v1.webp',
);
const _joseph = StoryDetail(
  id: 'joseph',
  slug: 'joseph',
  title: 'Joseph’s Colorful Coat',
  author: 'Kingdom Kids',
  category: 'Forgiveness',
  body: 'Joseph forgave his brothers and shared food.',
  summary: 'Discover how Joseph found hope and learned to forgive.',
  estimatedReadSeconds: 180,
  coverAssetKey: 'assets/images/stories/joseph-colorful-coat-storybook-v1.webp',
);

class _Auth extends AuthRepository {
  _Auth(AuthSessionStore store) : super(sessionStore: store);
  KidProfile? profile = _kid;

  @override
  Future<KidProfile?> currentKid() async => profile;
}

class _Stories implements StoryRepository {
  _Stories({this.includeFeatured = false});

  final bool includeFeatured;
  int detailCalls = 0;
  String? requestedSlug;
  bool failDetail = false;
  Future<StoryDetail>? detailBarrier;

  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async => [
    if (includeFeatured)
      const StoryDetail(
        id: 'david',
        slug: 'david-and-goliath',
        title: 'David and Goliath',
        author: 'Kingdom Kids',
        category: 'Courage',
        summary: 'A brave young shepherd trusted God and faced a giant.',
        estimatedReadSeconds: 180,
        isFeatured: true,
        coverAssetKey: 'assets/images/stories/david-and-goliath-v2.webp',
      ),
    for (final story in [_ruth, _joseph])
      StoryDetail(
        id: story.id,
        slug: story.slug,
        title: story.title,
        author: story.author,
        category: story.category,
        summary: story.summary,
        estimatedReadSeconds: story.estimatedReadSeconds,
        coverAssetKey: story.coverAssetKey,
      ),
  ];

  @override
  Future<StoryDetail> fetchStory(String slug) async {
    detailCalls++;
    requestedSlug = slug;
    if (failDetail) throw const AppException('Connect and try again.');
    if (detailBarrier != null) return detailBarrier!;
    return [_ruth, _joseph].firstWhere((story) => story.slug == slug);
  }
}

class _Streak implements StreakRepository {
  @override
  Future<StreakClaimReceipt> claimPresentation({
    required String profileId,
  }) async => const StreakClaimReceipt();
}

class _Reminder implements StreakReminderService {
  @override
  Future<void> disable() async {}
  @override
  Future<bool> enable({required KidProfile profile}) async => true;
  @override
  Future<bool> isEnabled() async => false;
  @override
  Future<void> refreshAfterAppOpen({required KidProfile profile}) async {}
}
