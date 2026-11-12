import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/presentation/kid_profile_setup_screen.dart';

void main() {
  testWidgets('selection reveals the name form and back preserves the draft', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(const MaterialApp(home: KidProfileSetupScreen()));
    expect(find.byKey(const Key('kid-profile-name-field')), findsNothing);
    await _choosePage(tester, 2);
    expect(find.text('Meet Zuri'), findsOneWidget);
    await tester.tap(find.byKey(const Key('select-story-buddy')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('kid-profile-name-field')),
      'Ada',
    );
    await tester.tap(find.byKey(const Key('story-buddy-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kid-profile-name-field')), findsNothing);
    expect(find.text('Meet Zuri'), findsOneWidget);
    await _choosePage(tester, 0);
    await tester.tap(find.byKey(const Key('select-story-buddy')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('kid-profile-name-field')),
          )
          .controller!
          .text,
      'Ada',
    );
    expect(find.text('What should we call them?'), findsOneWidget);
    expect(find.text('Kai is their story buddy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('original artwork and the close-up fit an iPhone screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: const KidProfileSetupScreen(),
        ),
      ),
    );
    for (final entry in {
      'lion': 'kai',
      'dove': 'nia',
      'rainbow': 'zuri',
    }.entries) {
      await _choosePage(
        tester,
        entry.key == 'lion'
            ? 0
            : entry.key == 'dove'
            ? 1
            : 2,
      );
      for (var attempt = 0; attempt < 12; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, entry.value);
    }
    await tester.tap(find.byKey(const Key('select-story-buddy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kid-profile-name-field')), findsOneWidget);
    await _capture(tester, boundary, 'zuri-close-up');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'character selection and approach settle without layout overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: const KidProfileSetupScreen(),
          ),
        ),
      );
      for (final entry in {
        'lion': 'kai-original',
        'dove': 'nia-original',
        'rainbow': 'zuri-original',
      }.entries) {
        if (entry.key == 'dove') await _choosePage(tester, 1);
        if (entry.key == 'rainbow') {
          await tester.drag(
            find.byKey(const Key('story-buddy-cast')),
            const Offset(-320, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text('Meet Zuri'), findsOneWidget);
        }
        await _capture(tester, boundary, entry.value);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const Key('select-story-buddy')));
      await tester.pump(const Duration(milliseconds: 850));
      await tester.pump();
      expect(find.byKey(const Key('kid-profile-name-field')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<void> _choosePage(WidgetTester tester, int index) async {
  await tester.tap(find.byKey(ValueKey('story-buddy-page-$index')));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['SPOTLIGHT_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
