import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/videos/domain/video_story.dart';
import 'package:mobile/features/videos/presentation/video_watch_screen.dart';
import 'package:mobile/features/videos/presentation/videos_screen.dart';

void main() {
  testWidgets('watch tab honestly presents the beta coming-soon state', (
    tester,
  ) async {
    _useSurface(tester, const Size(390, 844));

    await tester.pumpWidget(
      _videoApp(const VideosScreen(), disableAnimations: true),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('videos-screen')), findsOneWidget);
    expect(find.byKey(const Key('videos-coming-soon')), findsOneWidget);
    expect(find.byKey(const Key('coming-soon-tv-tile')), findsOneWidget);
    expect(find.text('Videos are\ncoming soon!'), findsOneWidget);
    expect(
      find.textContaining('Watch Clubhouse will open its doors soon'),
      findsOneWidget,
    );
    expect(find.text('New stories are on the way'), findsOneWidget);

    // Placeholder catalogue and playback actions must not leak into the beta.
    expect(find.byKey(const Key('video-search-field')), findsNothing);
    expect(find.text('David & Goliath'), findsNothing);
    expect(find.text('Play video'), findsNothing);
    expect(find.text('More to watch'), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byKey(const Key('bottom-nav-main-dock')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the television gently moves when motion is allowed', (
    tester,
  ) async {
    _useSurface(tester, const Size(390, 844));

    await tester.pumpWidget(_videoApp(const VideosScreen()));
    await tester.pump();

    final before = _tvVerticalOffset(tester);
    await tester.pump(const Duration(milliseconds: 460));
    final after = _tvVerticalOffset(tester);

    expect(after, isNot(closeTo(before, 0.01)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the television stays still when reduced motion is enabled', (
    tester,
  ) async {
    _useSurface(tester, const Size(390, 844));

    await tester.pumpWidget(
      _videoApp(
        const VideosScreen(),
        disableAnimations: true,
        accessibleNavigation: true,
      ),
    );
    await tester.pump();

    final before = _tvVerticalOffset(tester);
    await tester.pump(const Duration(milliseconds: 900));
    final after = _tvVerticalOffset(tester);

    expect(after, closeTo(before, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the coming-soon message exposes one concise semantic summary', (
    tester,
  ) async {
    _useSurface(tester, const Size(390, 844));
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _videoApp(const VideosScreen(), disableAnimations: true),
    );
    await tester.pumpAndSettle();

    final node = tester.getSemantics(
      find.byKey(const Key('videos-coming-soon')),
    );
    expect(node.label, contains('Videos are coming soon'));
    expect(node.label, contains('joyful Bible adventures'));
    semantics.dispose();
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'coming-soon page stays usable on a compact ${brightness.name} screen',
      (tester) async {
        _useSurface(tester, const Size(320, 568));

        await tester.pumpWidget(
          _videoApp(
            const VideosScreen(),
            brightness: brightness,
            disableAnimations: true,
            textScaler: const TextScaler.linear(2.2),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('videos-screen')), findsOneWidget);
        expect(find.byKey(const Key('coming-soon-tv-tile')), findsOneWidget);
        expect(find.byKey(const Key('bottom-nav-main-dock')), findsOneWidget);
        expect(tester.takeException(), isNull);

        final scrollable = find.byKey(const Key('videos-coming-soon-scroll'));
        for (var page = 0; page < 5; page++) {
          await tester.drag(scrollable, const Offset(0, -180));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('a legacy video detail route cannot expose the dummy player', (
    tester,
  ) async {
    _useSurface(tester, const Size(390, 844));

    await tester.pumpWidget(
      _videoApp(
        const VideoWatchScreen(video: VideoStory.fallback),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-detail-coming-soon')), findsOneWidget);
    expect(find.byKey(const Key('videos-coming-soon')), findsOneWidget);
    expect(find.text('Play video'), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

double _tvVerticalOffset(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.byKey(const Key('coming-soon-tv-motion')),
  );
  return transform.transform.storage[13];
}

Widget _videoApp(
  Widget home, {
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
  bool accessibleNavigation = false,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Builder(
      builder: (context) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            accessibleNavigation: accessibleNavigation,
            textScaler: textScaler,
          ),
          child: home,
        );
      },
    ),
  );
}

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
