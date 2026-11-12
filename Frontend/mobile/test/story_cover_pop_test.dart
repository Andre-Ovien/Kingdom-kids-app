import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/stories/data/story_reading_bookmark_store.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/story_detail_screen.dart';

void main() {
  for (final destination in [AppRoutes.home, AppRoutes.stories]) {
    testWidgets('story cover glow stays inside an iOS pop to $destination', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundaryKey = GlobalKey();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [appRouteObserver],
          theme: ThemeData(platform: TargetPlatform.iOS),
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: const Scaffold(backgroundColor: Color(0xFF00FF00)),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage(
            'assets/images/stories/jonah-and-the-big-fish-v2.webp',
          ),
          tester.element(find.byType(Scaffold)),
        ),
      );
      final storyRoute = _FrozenStoryRoute(
        settings: const RouteSettings(name: AppRoutes.storyDetail),
        allowSnapshotting: true,
        builder: (_) => StoryDetailScreen(
          story: _jonah,
          repository: _JonahRepository(),
          authRepository: AuthRepository(
            sessionStore: MemoryAuthSessionStore(),
          ),
          bookmarkStore: MemoryStoryReadingBookmarkStore(),
        ),
      );
      if (destination == AppRoutes.stories) {
        navigatorKey.currentState!.push(
          TabGlideRoute(
            builder: (_) => const Scaffold(backgroundColor: Color(0xFF00FF00)),
            settings: const RouteSettings(name: AppRoutes.stories),
            fromRoute: AppRoutes.home,
          ),
        );
        await tester.pumpAndSettle();
      }
      navigatorKey.currentState!.push(storyRoute);
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 10; attempt++) {
        final decoded = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .where((image) => image.image != null)
            .length;
        if (decoded == 2) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .where((image) => image.image != null),
        hasLength(2),
      );
      expect(find.byType(ImageFiltered), findsOneWidget);
      final viewport = tester.renderObject<RenderViewport>(
        find.descendant(
          of: find.byKey(const Key('story-detail-scroll')),
          matching: find.byType(Viewport),
        ),
      );
      expect(
        viewport.hasVisualOverflow,
        isFalse,
        reason:
            'This regression needs a short page whose viewport skips clipping.',
      );

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      storyRoute.freeze();
      final routeValue = storyRoute.animation!.value;
      final storyLeft = tester.getTopLeft(find.byType(StoryDetailScreen)).dx;
      expect(storyLeft, greaterThan(48));
      expect(storyLeft, lessThan(350));
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = boundary.toImageSync(pixelRatio: 1);
      final bytes = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      List<int> pixel(int x, int y) {
        final index = (y * image.width + x) * 4;
        return bytes.buffer.asUint8List(index, 4).toList();
      }

      if (const bool.fromEnvironment('CAPTURE_STORY_POP')) {
        final folder = Directory(
          '${Directory.current.parent.parent.path}/output/story-back-transition-20261111',
        )..createSync(recursive: true);
        File(
          '${folder.path}/fixed-${destination == AppRoutes.home ? 'home' : 'stories'}-pop.rgba',
        ).writeAsBytesSync(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }
      final samples = <String, Object>{
        'storyLeft': storyLeft,
        'width': image.width,
        'height': image.height,
      };
      samples['outgoingInterior'] = pixel(370, 700);
      expect(
        pixel(370, 700),
        isNot([0, 255, 0, 255]),
        reason: 'The outgoing story must still paint inside its moving bounds.',
      );
      for (final distance in [8, 32, 64]) {
        final x = (storyLeft - distance).floor().clamp(0, image.width - 1);
        final upper = pixel(x, 160);
        final lower = pixel(x, 700);
        samples['$distance'] = {'x': x, 'upper': upper, 'lower': lower};
      }
      image.dispose();
      expect(storyRoute.animation!.value, routeValue);
      if (const bool.fromEnvironment('CAPTURE_STORY_POP')) {
        final file = File(
          '${Directory.current.parent.parent.path}/output/'
          'story-back-transition-20261111/fixed-'
          '${destination == AppRoutes.home ? 'home' : 'stories'}-samples.json',
        );
        file.writeAsStringSync(jsonEncode(samples));
      }
      for (final distance in [8, 32, 64]) {
        final sample = samples['$distance']! as Map<String, Object>;
        expect(
          sample['upper'],
          sample['lower'],
          reason:
              'The cover glow must not tint the revealed destination: $samples',
        );
      }
      storyRoute.finishPop();
      await tester.pumpAndSettle();
      expect(find.byType(StoryDetailScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

class _FrozenStoryRoute extends MaterialPageRoute<void> {
  _FrozenStoryRoute({
    required super.builder,
    required super.settings,
    super.allowSnapshotting,
  });

  void freeze() => controller!.stop();
  void finishPop() => controller!.reverse();
}

const _jonah = StoryDetail(
  id: 'jonah-pop-regression',
  slug: 'jonah-and-the-big-fish',
  title: 'Jonah and the Big Fish',
  author: 'Kingdom Kids',
  category: 'Mercy',
  coverAssetKey: 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
  summary: 'A story about second chances.',
  body: 'Jonah learned that kindness and second chances are for everyone.',
  estimatedReadSeconds: 120,
);

class _JonahRepository implements StoryRepository {
  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async => [_jonah];

  @override
  Future<StoryDetail> fetchStory(String slug) async => _jonah;
}
