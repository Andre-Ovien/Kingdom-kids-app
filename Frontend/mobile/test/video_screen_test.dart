import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/videos/data/video_repository.dart';
import 'package:mobile/features/videos/domain/video_story.dart';
import 'package:mobile/features/videos/presentation/videos_screen.dart';

void main() {
  test('watch catalogue consistently uses the refreshed story covers', () {
    const expectedCovers = {
      'david-and-goliath': 'assets/images/stories/david-and-goliath-v2.webp',
      'jonah-big-fish': 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
      'red-sea': 'assets/images/stories/crossing-the-red-sea-v2.webp',
      'noah-ark': 'assets/images/stories/noah-builds-the-ark-v2.webp',
      'creation-week': 'assets/images/stories/creation-week-v2.webp',
      'daniel-lions': 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
      'moses-called': 'assets/images/stories/moses-follows-god-v2.webp',
      'queen-esther': 'assets/images/stories/esther-speaks-up-v2.webp',
    };

    expect(VideoRepository.items, hasLength(expectedCovers.length));
    expect({
      for (final video in VideoRepository.items) video.id: video.imageAsset,
    }, expectedCovers);
    expect(
      VideoRepository.items.every(
        (video) => video.imageAsset.startsWith('assets/images/stories/'),
      ),
      isTrue,
    );
  });

  testWidgets('watch clubhouse searches, filters, and opens a video', (
    tester,
  ) async {
    _useTallSurface(tester);
    Object? routedArguments;

    await tester.pumpWidget(
      MaterialApp(
        home: const VideosScreen(),
        onGenerateRoute: (settings) {
          routedArguments = settings.arguments;
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Watch route reached')),
            settings: settings,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Watch &\nwonder!'), findsOneWidget);
    expect(find.byKey(const Key('video-search-field')), findsOneWidget);
    expect(find.text('David & Goliath'), findsWidgets);
    expect(find.text('Jonah and the Big Fish'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('video-search-field')),
      'Jonah',
    );
    await tester.pump();

    expect(find.text('David & Goliath'), findsNothing);
    expect(find.text('Jonah and the Big Fish'), findsWidgets);

    await tester.tap(find.byKey(const Key('video-search-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('video-category-Courage')));
    await tester.pump();

    expect(find.text('David & Goliath'), findsWidgets);
    expect(find.text('Jonah and the Big Fish'), findsNothing);

    await tester.tap(
      find.byKey(const Key('watch-featured-card-david-and-goliath')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Watch route reached'), findsOneWidget);
    expect((routedArguments! as VideoStory).id, 'david-and-goliath');
  });

  testWidgets('watch clubhouse has a useful empty search state', (
    tester,
  ) async {
    _useTallSurface(tester);
    await tester.pumpWidget(const MaterialApp(home: VideosScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('video-search-field')),
      'not-a-real-show',
    );
    await tester.pump();

    expect(find.byKey(const Key('videos-empty-state')), findsOneWidget);
    expect(find.text('No show hiding here!'), findsOneWidget);

    await tester.tap(find.byKey(const Key('video-filter-reset')));
    await tester.pump();

    expect(find.text('David & Goliath'), findsWidgets);
    expect(find.byKey(const Key('videos-empty-state')), findsNothing);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'watch clubhouse stays usable on a compact ${brightness.name} screen',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 568),
                textScaler: TextScaler.linear(2.2),
              ),
              child: const VideosScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('videos-screen')), findsOneWidget);
        final searchField = find.byKey(const Key('video-search-field'));
        for (var page = 0; page < 6 && searchField.evaluate().isEmpty; page++) {
          await tester.drag(
            find.byKey(const Key('videos-scroll-view')),
            const Offset(0, -180),
          );
          await tester.pump();
        }
        expect(searchField, findsOneWidget);

        final featured = find.byKey(
          const Key('watch-featured-card-david-and-goliath'),
        );
        for (var page = 0; page < 6 && featured.evaluate().isEmpty; page++) {
          await tester.drag(
            find.byKey(const Key('videos-scroll-view')),
            const Offset(0, -180),
          );
          await tester.pump();
        }
        expect(featured, findsOneWidget);
        expect(tester.takeException(), isNull);

        for (var page = 0; page < 5; page++) {
          await tester.drag(
            find.byKey(const Key('videos-scroll-view')),
            const Offset(0, -360),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
