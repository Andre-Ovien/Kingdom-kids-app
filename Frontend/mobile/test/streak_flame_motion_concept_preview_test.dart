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

import 'support/streak_flame_icon_concept.dart';
import 'support/streak_flame_motion_concept.dart';

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

  testWidgets('capture the approved flame with anchored gentle motion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    final output = Directory(
      '${Directory.current.parent.parent.path}/output/streak-fire-preview-20261111-v3',
    )..createSync(recursive: true);
    final frames = Directory('${output.path}/frames')..createSync();
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
        StreakFlameIconConcept(
          presentation: presentation,
          xpAwarded: 20,
          onClose: () {},
        ),
      ),
    );
    await _images(tester);
    await tester.pumpAndSettle();
    await _nativeFallbackText(tester);
    for (final key in retainedKeys) {
      baselineGeometry[key] = tester.getRect(find.byKey(Key(key)));
    }
    await tester.pumpWidget(const SizedBox.shrink());

    var closed = 0;
    await tester.pumpWidget(
      _app(
        boundary,
        StreakFlameMotionConcept(
          presentation: presentation,
          xpAwarded: 20,
          onClose: () => closed++,
        ),
      ),
    );
    await _images(tester);
    await tester.pumpAndSettle();
    await _nativeFallbackText(tester);
    final stillBefore = await _frameBytes(tester, boundary);
    await tester.pump(const Duration(milliseconds: 1900));
    final stillAfter = await _frameBytes(tester, boundary);
    expect(
      stillAfter,
      orderedEquals(stillBefore),
      reason: 'Reduce Motion freezes flame and embers.',
    );
    for (final key in retainedKeys) {
      expect(tester.getRect(find.byKey(Key(key))), baselineGeometry[key]);
    }
    await tester.tap(find.byKey(const Key('streak-continue-button')));
    await tester.pump();
    expect(closed, 1);
    await tester.tap(find.byKey(const Key('streak-close-button')));
    await tester.pump();
    expect(closed, 2);
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.pumpWidget(
      _app(
        boundary,
        StreakFlameMotionConcept(
          presentation: presentation,
          xpAwarded: 20,
          onClose: () {},
        ),
        animations: true,
      ),
    );
    await _images(tester);
    await _nativeFallbackText(tester);
    expect(find.byKey(const Key('streak-flame-counter')), findsNothing);
    await _png(
      tester,
      boundary,
      '${output.path}/streak-flame-motion-native.png',
    );
    List<int>? initialFrame;
    var flameChanged = false;
    for (var frame = 0; frame < 144; frame++) {
      if (frame > 0) await tester.pump(const Duration(microseconds: 33333));
      final bytes = await _frameBytes(tester, boundary);
      initialFrame ??= bytes;
      if (frame == 36) {
        flameChanged =
            bytes.length != initialFrame.length ||
            List.generate(
              bytes.length,
              (i) => bytes[i] != initialFrame![i],
            ).any((changed) => changed);
      }
      await tester.runAsync(() async {
        await File(
          '${frames.path}/frame-${frame.toString().padLeft(3, '0')}.png',
        ).writeAsBytes(bytes);
      });
      if (frame % 30 == 0) {
        for (final key in retainedKeys) {
          expect(
            tester.getRect(find.byKey(Key(key))),
            baselineGeometry[key],
            reason: '$key stays stationary through the flame loop.',
          );
        }
      }
    }
    expect(flameChanged, isTrue);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await File('${output.path}/native-preview-metadata.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'source': 'Isolated native Flutter V3 flame motion concept',
          'logicalSize': [393, 852],
          'pixelRatio': 3,
          'durationSeconds': 4.8,
          'fps': 30,
          'frames': 144,
          'motion':
              'Anchored flame; +/-1.5% width and +/-2.2% height flicker, less than one degree sway, small local shear; three faint ascending warm embers.',
          'bodyAndBackdropStationary': true,
          'reducedMotionExactPixelFreezeVerified': true,
          'retainedGeometryMatchesV2': true,
          'continueAndCloseVerified': true,
          'productionUiChanged': false,
          'streakClaimOrStorageWrites': false,
          'phoneInstalled': false,
          'sound': false,
          'hero':
              'Existing Icons.local_fire_department_rounded in #FF6B35; no halo or attached badge',
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

Widget _app(GlobalKey boundary, Widget screen, {bool animations = false}) =>
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildKingdomKidsTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 59, bottom: 34),
            viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
            disableAnimations: !animations,
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

Future<List<int>> _frameBytes(WidgetTester tester, GlobalKey boundary) async {
  List<int> bytes = [];
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 3);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      bytes = data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  });
  return bytes;
}

Future<void> _png(WidgetTester tester, GlobalKey boundary, String path) async {
  final bytes = await _frameBytes(tester, boundary);
  await tester.runAsync(() async => File(path).writeAsBytes(bytes));
}
