import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/presentation/auth_screen.dart';
import 'package:mobile/features/onboarding/presentation/onboarding_screen.dart';
import 'package:mobile/features/onboarding/presentation/family_onboarding_page.dart';
import 'package:mobile/features/onboarding/presentation/onboarding_navigation.dart';
import 'package:mobile/shared/audio/app_audio_controller.dart';
import 'package:mobile/shared/audio/app_audio_scope.dart';
import 'package:mobile/shared/audio/app_sound_cue.dart';

const _familyNext = Key('onboarding-family-next');
const _firstContinue = Key('onboarding-photo-first-continue');
const _secondNext = Key('onboarding-photo-second-next');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Use the bundled fonts for meaningful text wrapping and native renders.
    final fonts =
        jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>;
    for (final entry in fonts.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font in (entry['fonts'] as List<dynamic>)) {
        loader.addFont(rootBundle.load((font as Map)['asset'] as String));
      }
      await loader.load();
    }
    final avenir = File('/System/Library/Fonts/Avenir Next.ttc');
    if (avenir.existsSync()) {
      await (FontLoader('Avenir Next')..addFont(
            Future.value(ByteData.sublistView(await avenir.readAsBytes())),
          ))
          .load();
    }
  });

  for (final reduceMotion in [true, false]) {
    testWidgets(
      'onboarding stays silent through real controls, reduced motion=$reduceMotion',
      (tester) async {
        _usePhone(tester);
        final audio = _OnboardingAudioProbe();
        addTearDown(audio.dispose);
        await tester.pumpWidget(
          AppAudioScope(
            controller: audio,
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduceMotion),
                child: child!,
              ),
              home: const OnboardingScreen(),
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Parent account')),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await _tapAdvance(tester, _familyNext);
        await _tapAdvance(tester, _secondNext);
        await tester.tap(find.byKey(_firstContinue));
        await tester.pumpAndSettle();
        expect(find.text('Parent account'), findsOneWidget);
        expect(audio.requestedEffects, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'family opening, existing middle and photographic finale retain navigation',
    (tester) async {
      _usePhone(tester);
      final semantics = tester.ensureSemantics();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: const KingdomKidsApp(initialRoute: AppRoutes.onboarding),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('cinematic-splash-screen')), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
      expect(find.textContaining('Big discoveries.'), findsOneWidget);
      for (var index = 1; index <= 6; index++) {
        expect(
          find.byKey(ValueKey('onboarding-family-portrait-$index')),
          findsOneWidget,
        );
      }
      expect(find.byKey(_familyNext).hitTestable(), findsOneWidget);
      expect(find.text('Next').hitTestable(), findsNothing);
      expect(find.bySemanticsLabel('Page 1 of 3'), findsOneWidget);
      final firstArrowRect = tester.getRect(find.byKey(_familyNext));
      final firstDotsRect = tester.getRect(
        find.byKey(const Key('onboarding-family-progress')),
      );
      expect(find.text('Privacy policy'), findsNothing);
      await _captureIfRequested(tester, boundary, 1);

      await _tapAdvance(tester, _familyNext);
      expect(find.textContaining('Big smiles.').hitTestable(), findsOneWidget);
      final sharpPhoto = find.byKey(const Key('onboarding-discovery-photo'));
      final photo = tester.widget<Image>(sharpPhoto);
      expect(
        (photo.image as AssetImage).assetName,
        'assets/images/onboarding/photos/second-screen-expanded-scene-v7.png',
      );
      expect(photo.fit, BoxFit.fill);
      expect(photo.alignment, Alignment.center);
      final photoHeader = tester.getRect(
        find.byKey(const Key('onboarding-discovery-photo-header')),
      );
      expect(photoHeader.top, 0);
      expect(photoHeader.height, 500);
      final header = find.byKey(const Key('onboarding-discovery-photo-header'));
      expect(
        find.descendant(of: header, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.byType(ImageFiltered)),
        findsNothing,
      );
      expect(
        find.descendant(of: header, matching: find.byType(ShaderMask)),
        findsNothing,
      );
      final fade = tester.widget<DecoratedBox>(
        find.byKey(const Key('onboarding-discovery-photo-fade')),
      );
      final gradient =
          (fade.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      final heading = tester.getRect(
        find.textContaining('Big smiles.').hitTestable(),
      );
      expect(heading.top, 506);
      expect(
        find.textContaining('and enjoy little moments of wonder'),
        findsOneWidget,
      );
      expect(find.text('Continue').hitTestable(), findsNothing);
      expect(find.byKey(_secondNext).hitTestable(), findsOneWidget);
      expect(find.bySemanticsLabel('Page 2 of 3'), findsOneWidget);
      final secondArrowRect = tester.getRect(find.byKey(_secondNext));
      final secondDotsRect = tester.getRect(
        find.byKey(const Key('onboarding-discovery-progress')),
      );
      expect(secondArrowRect, firstArrowRect);
      expect(secondDotsRect, firstDotsRect);
      await _captureIfRequested(tester, boundary, 2);

      await _tapAdvance(tester, _secondNext);
      expect(
        find.textContaining('Big Stories, For Little').hitTestable(),
        findsOneWidget,
      );
      for (final name in [
        'boy-twists',
        'girl-puffs',
        'boy-curls',
        'girl-braids',
      ]) {
        expect(_assetEnding('/$name.png'), findsOneWidget);
      }
      expect(find.byKey(_firstContinue).hitTestable(), findsOneWidget);
      expect(find.bySemanticsLabel('Page 3 of 3'), findsNothing);
      expect(find.text('SKIP'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('onboarding-photo-first-page')),
          matching: find.byType(OnboardingProgressDots),
        ),
        findsNothing,
      );
      expect(_assetEnding('/story-celebration-v2.png'), findsNothing);
      await _captureIfRequested(tester, boundary, 3);

      await tester.tap(find.byKey(_firstContinue));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final auth = find.byType(AuthScreen);
      expect(auth, findsOneWidget);
      expect(
        tester.widget<AuthScreen>(auth).initialMode,
        AuthScreenMode.register,
      );
      expect(find.text('Hey, welcome!'), findsOneWidget);
      semantics.dispose();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('page swipe blends scenes without a joined panel edge', (
    tester,
  ) async {
    _usePhone(tester);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: const KingdomKidsApp(initialRoute: AppRoutes.onboarding),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final view = tester.widget<PageView>(find.byType(PageView));
    view.controller!.jumpTo(393 * 0.45);
    await tester.pump();
    // Both full-screen scenes share the viewport and fade, rather than meeting
    // at a rigid vertical panel seam. Controls are locked during the gesture.
    final familyRect = tester.getRect(
      find.byKey(const Key('onboarding-family-page')),
    );
    final discoveryRect = tester.getRect(
      find.byKey(const Key('onboarding-photo-second-page')),
    );
    expect(familyRect.left.abs(), lessThan(0.01));
    expect(discoveryRect.left.abs(), lessThan(0.01));
    expect(find.byKey(_familyNext).hitTestable(), findsNothing);
    expect(find.byKey(_secondNext).hitTestable(), findsNothing);
    await _captureIfRequested(tester, boundary, 4);
    view.controller!.jumpToPage(1);
    await tester.pump();
    expect(find.byKey(_secondNext).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('swiping back restores first-page navigation without audio', (
    tester,
  ) async {
    _usePhone(tester);
    await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await _tapAdvance(tester, _familyNext);
    expect(find.byKey(_secondNext).hitTestable(), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(650, 0), 1200);
    await _settlePage(tester);
    expect(find.byKey(_familyNext).hitTestable(), findsOneWidget);
    expect(
      find.textContaining('Big discoveries.').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'both photo pages keep controls reachable on small large-text phones',
    (tester) async {
      _usePhone(tester, size: const Size(360, 640));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: const OnboardingScreen(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Big discoveries.'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsWidgets);
      await tester.ensureVisible(find.byKey(_familyNext));
      await _tapAdvance(tester, _familyNext);
      expect(find.textContaining('Big smiles.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(_secondNext));
      await _tapAdvance(tester, _secondNext);
      expect(find.textContaining('Big Stories, For Little'), findsOneWidget);
      await tester.ensureVisible(find.byKey(_firstContinue));
      expect(find.text('SKIP'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('onboarding-photo-first-page')),
          matching: find.byType(OnboardingProgressDots),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Finder _assetEnding(String suffix) => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is AssetImage &&
      (widget.image as AssetImage).assetName.endsWith(suffix),
);

void _usePhone(WidgetTester tester, {Size size = const Size(393, 852)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
}

Future<void> _tapAdvance(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key).hitTestable());
  await _settlePage(tester);
}

Future<void> _settlePage(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump();
}

Future<void> _captureIfRequested(
  WidgetTester tester,
  GlobalKey key,
  int page,
) async {
  if (!const bool.fromEnvironment('CAPTURE_NATIVE_ONBOARDING')) return;
  await tester.runAsync(() async {
    final context = key.currentContext!;
    for (final asset in [
      ...FamilyOnboardingPage.portraitAssets,
      'assets/images/onboarding/photos/boy-twists.png',
      'assets/images/onboarding/photos/girl-puffs.png',
      'assets/images/onboarding/photos/boy-curls.png',
      'assets/images/onboarding/photos/girl-braids.png',
      'assets/images/onboarding/photos/second-screen-expanded-scene-v7.png',
    ]) {
      await precacheImage(
        asset.contains('family-20261111')
            ? ResizeImage(AssetImage(asset), width: 384)
            : AssetImage(asset),
        context,
      );
    }
  });
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = Directory(
      '${Directory.current.parent.parent.path}/output/release-review-20261111/family-onboarding',
    )..createSync(recursive: true);
    await File(
      '${output.path}/native-second-v7-page-$page.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _OnboardingAudioProbe extends AppAudioController {
  final requestedEffects = <AppSoundCue>[];

  @override
  void playEffect(AppSoundCue cue) => requestedEffects.add(cue);
}
