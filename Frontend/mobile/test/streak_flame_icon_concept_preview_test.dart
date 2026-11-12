import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';
import 'package:mobile/features/streak/presentation/streak_screen.dart';

import 'support/streak_flame_icon_concept.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load((font as Map)['asset'] as String));
      }
      await loader.load();
    }
    final nativeManifest = File('/private/tmp/kk-auth-fonts/manifest.json');
    if (nativeManifest.existsSync()) {
      final entries = (jsonDecode(await nativeManifest.readAsString()) as List)
          .cast<Map<String, dynamic>>();
      for (final family in ['Avenir Next', 'Helvetica Neue']) {
        final loader = FontLoader(family);
        for (final entry in entries.where((e) => e['family'] == family)) {
          loader.addFont(
            Future.value(
              ByteData.sublistView(
                await File(entry['path'] as String).readAsBytes(),
              ),
            ),
          );
        }
        await loader.load();
      }
    } else {
      final native = File('/System/Library/Fonts/Avenir Next.ttc');
      await (FontLoader('Avenir Next')..addFont(
            Future.value(ByteData.sublistView(await native.readAsBytes())),
          ))
          .load();
    }
    // The production CTA intentionally has no explicit family and uses iOS's
    // native default. Replace only the test engine's square Ahem fallback.
    final systemFont = ByteData.sublistView(
      await File('/System/Library/Fonts/SFNS.ttf').readAsBytes(),
    );
    for (final family in ['Ahem', 'SF Pro Display', '.SF UI Display']) {
      await (FontLoader(family)..addFont(Future.value(systemFont))).load();
    }
  });

  testWidgets('capture the current streak layout with one large orange flame icon', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    final output = Directory(
      '${Directory.current.parent.parent.path}/output/streak-fire-preview-20261111-v2',
    )..createSync(recursive: true);
    final boundary = GlobalKey();
    final presentation = _presentation();
    final baselineGeometry = <String, Rect>{};
    const retainedKeys = [
      'streak-character-stage',
      'streak-title',
      'streak-message',
      'streak-xp-reward',
      'streak-recent-days',
      'streak-continue-button',
      'streak-close-button',
    ];
    await tester.pumpWidget(
      _app(
        boundary,
        StreakScreen(presentation: presentation, xpAwarded: 20, onClose: () {}),
      ),
    );
    await _images(tester);
    await tester.pumpAndSettle();
    await _nativeFallbackText(tester);
    expect(tester.takeException(), isNull);
    for (final key in retainedKeys) {
      baselineGeometry[key] = tester.getRect(find.byKey(Key(key)));
    }
    await _png(tester, boundary, '${output.path}/streak-current-reference.png');
    await tester.pumpWidget(const SizedBox.shrink());

    var closed = 0;
    await tester.pumpWidget(
      _app(
        boundary,
        StreakFlameIconConcept(
          presentation: presentation,
          xpAwarded: 20,
          onClose: () => closed++,
        ),
      ),
    );
    await _images(tester);
    await tester.pumpAndSettle();
    await _nativeFallbackText(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('streak-flame-icon-hero')), findsOneWidget);
    expect(find.byKey(const Key('streak-flame-counter')), findsNothing);
    expect(find.byKey(const Key('streak-character')), findsNothing);
    for (final key in retainedKeys) {
      expect(
        tester.getRect(find.byKey(Key(key))),
        baselineGeometry[key],
        reason: '$key stays in its production position.',
      );
    }
    expect(
      find.byKey(const Key('streak-continue-button')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('streak-close-button')).hitTestable(),
      findsOneWidget,
    );
    await _png(tester, boundary, '${output.path}/streak-flame-icon-native.png');
    await tester.tap(find.byKey(const Key('streak-continue-button')));
    await tester.pump();
    expect(closed, 1);
    await tester.tap(find.byKey(const Key('streak-close-button')));
    await tester.pump();
    expect(closed, 2);
    await tester.runAsync(() async {
      await File('${output.path}/native-preview-metadata.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'source': 'Isolated Flutter copy of current StreakScreen',
          'logicalSize': [393, 852],
          'safeAreas': {'top': 59, 'bottom': 34},
          'pixelRatio': 3,
          'hero': {
            'icon': 'Icons.local_fire_department_rounded',
            'color': '#FF6B35',
            'circleOrHalo': false,
            'attachedDayBadge': false,
          },
          'background': '#F3F6FF',
          'changed': [
            'Light background',
            'Character/halo/attached badge replaced by one existing orange flame icon',
          ],
          'retained': retainedKeys,
          'retainedGeometryMatchesProduction': true,
          'fixture': {
            'childName': 'Maya',
            'avatar': 'dove',
            'days': 1,
            'xp': 20,
            'date': '2026-11-11',
          },
          'productionUiChanged': false,
          'streakClaimOrStorageWrites': false,
          'phoneInstalled': false,
          'fonts':
              'Current app Avenir Next, native SF default fallback and bundled icons',
        }),
      );
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

StreakPresentation _presentation() => StreakPresentation(
  profile: const KidProfile(
    id: 'streak-preview-child',
    parentId: 'preview-parent',
    displayName: 'Maya',
    avatarKey: 'dove',
  ),
  state: StreakPresentationState.firstStreak,
  currentDays: 1,
  longestDays: 1,
  localDate: DateTime(2026, 11, 11),
  recentDays: [
    for (var offset = 6; offset >= 0; offset--)
      StreakDay(
        date: DateTime(2026, 11, 11).subtract(Duration(days: offset)),
        active: offset == 0,
      ),
  ],
);

Widget _app(GlobalKey boundary, Widget screen) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildKingdomKidsTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: const EdgeInsets.only(top: 59, bottom: 34),
        viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: screen,
  ),
);

Future<void> _images(WidgetTester tester) async {
  final images = find.byType(Image).evaluate().toList();
  await tester.runAsync(() async {
    for (final element in images) {
      final widget = element.widget as Image;
      await precacheImage(widget.image, element);
    }
  });
  await tester.pump();
}

Future<void> _nativeFallbackText(WidgetTester tester) async {
  // flutter_tester hardwires unqualified paragraphs to square Ahem glyphs.
  // This one production CTA has no font family, so normalize that unresolved
  // default to the already-loaded native iOS system face for the PNG only.
  // The production widget, dimensions, font size/weight and all copy stay intact.
  final paragraph = tester.renderObject<RenderParagraph>(
    find.text('Keep exploring'),
  );
  final span = paragraph.text as TextSpan;
  paragraph.text = TextSpan(
    text: span.text,
    children: span.children,
    style: (span.style ?? const TextStyle()).copyWith(
      fontFamily: 'SF Pro Display',
    ),
    semanticsLabel: span.semanticsLabel,
  );
  await tester.pump();
}

Future<void> _png(WidgetTester tester, GlobalKey boundary, String path) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 3);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
