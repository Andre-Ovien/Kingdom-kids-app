import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/milestones/presentation/level_milestone_screen.dart';
import 'package:mobile/features/milestones/presentation/milestone_reveal_graphics.dart';

import 'support/staged_milestone_asset_bundle.dart';

// An opt-in, off-device recording harness for the held gift preview.
const _record = bool.fromEnvironment('RUN_MILESTONE_VISUAL_REVIEW');

void main() {
  testWidgets('record the level 14 reveal and level 15 maximum-rank poster', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final directory = Directory('../../Motion/milestone-ui-review-v1').absolute;
    final frames = Directory('${directory.path}/frames');
    await tester.runAsync(() => frames.create(recursive: true));
    await tester.runAsync(() async {
      final nativeFont = FontLoader('Avenir Next');
      nativeFont.addFont(
        File(
          '/System/Library/Fonts/Avenir Next.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
      await nativeFont.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final graphics = await tester.runAsync(
      () => MilestoneRevealGraphics.load(bundle: StagedMilestoneAssetBundle()),
    );
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKingdomKidsTheme(),
        home: RepaintBoundary(
          key: boundary,
          child: LevelMilestoneScreen(
            profile: _previewProfile,
            level: 14,
            levelTitle: 'Kingdom Hero',
            previewGiftReveal: true,
            graphicsLoader: () => Future.value(graphics!),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    for (var frame = 0; frame <= 140; frame++) {
      if (frame > 0) await tester.pump(const Duration(milliseconds: 50));
      await _capture(
        tester,
        boundary,
        '${frames.path}/frame_${frame.toString().padLeft(3, '0')}.png',
      );
      expect(tester.takeException(), isNull);
    }
    expect(find.text('14'), findsOneWidget);
    expect(find.text('Kingdom Hero'), findsOneWidget);
    await tester.runAsync(
      () => precacheImage(
        AssetImage(
          milestoneRevealPosterAsset,
          bundle: StagedMilestoneAssetBundle(),
        ),
        boundary.currentContext!,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKingdomKidsTheme(),
        builder: (context, child) => DefaultAssetBundle(
          bundle: StagedMilestoneAssetBundle(),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ),
        home: RepaintBoundary(
          key: boundary,
          child: const LevelMilestoneScreen(
            profile: _previewProfile,
            level: 15,
            levelTitle: 'Kingdom Champion',
            isMaxLevel: true,
            previewGiftReveal: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _capture(tester, boundary, '${directory.path}/level15_maximum.png');
    expect(find.text('15'), findsOneWidget);
    expect(find.text('MAXIMUM LEVEL ACHIEVED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !_record);
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(path).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

const _previewProfile = KidProfile(
  id: 'visual-preview-only',
  parentId: 'visual-preview-parent',
  displayName: 'Ada',
  avatarKey: 'kai',
);
