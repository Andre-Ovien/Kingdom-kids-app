import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/features/splash/presentation/splash_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native launches use the sampled periwinkle without old artwork', () {
    final storyboard = File(
      'ios/Runner/Base.lproj/LaunchScreen.storyboard',
    ).readAsStringSync();
    expect(storyboard, isNot(contains('<imageView')));
    expect(storyboard, contains('red="0.6588235294"'));
    expect(storyboard, contains('green="0.7529411765"'));
    expect(storyboard, contains('blue="0.9411764706"'));
    for (final folder in ['drawable', 'drawable-v21']) {
      final launch = File(
        'android/app/src/main/res/$folder/launch_background.xml',
      ).readAsStringSync();
      expect(launch, contains('#A8C0F0'));
      expect(launch, isNot(contains('<bitmap')));
    }
    for (final folder in [
      'values',
      'values-night',
      'values-v31',
      'values-night-v31',
    ]) {
      final styles = File(
        'android/app/src/main/res/$folder/styles.xml',
      ).readAsStringSync();
      expect(styles, contains('#A8C0F0'));
      expect(styles, isNot(contains('#3F61D6')));
    }
    expect(kingdomKidsSplashBackgroundColor, const Color(0xFFA8C0F0));
  });

  testWidgets('static wordmark stays centered and unchanged on portrait sizes', (
    tester,
  ) async {
    final output = Directory(
      '${Directory.current.parent.parent.path}/output/splash-title-preview-20261108/native',
    )..createSync(recursive: true);
    final measurements = <Map<String, Object>>[];
    for (final viewport in [
      (width: 402.0, height: 874.0, top: 59.0),
      (width: 393.0, height: 852.0, top: 59.0),
      (width: 320.0, height: 568.0, top: 20.0),
      (width: 320.0, height: 480.0, top: 20.0),
      (width: 430.0, height: 932.0, top: 59.0),
    ]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(viewport.width, viewport.height);
      tester.view.padding = FakeViewPadding(top: viewport.top, bottom: 34);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundaryKey,
            child: const SplashScreen(
              destinationResolver: _ReadyResolver(),
              returningDisplayDuration: Duration(seconds: 60),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage(kingdomKidsSplashPosterAsset),
          tester.element(find.byKey(const Key('splash-poster-image'))),
        );
      });
      await tester.pump();
      final firstFrame = await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final pixels = Uint8List.fromList(rgba!.buffer.asUint8List());
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${output.path}/static-splash-${viewport.width.toInt()}x${viewport.height.toInt()}.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        final bounds = _wordmarkBounds(pixels, image.width, image.height);
        measurements.add({
          'viewport': [viewport.width, viewport.height],
          'wordmark_bounds': [
            bounds.left,
            bounds.top,
            bounds.right,
            bounds.bottom,
          ],
          'wordmark_center': [bounds.center.dx, bounds.center.dy],
        });
        expect(bounds.center.dx, closeTo(viewport.width / 2, 3));
        expect(bounds.center.dy, closeTo(viewport.height / 2, 8));
        expect(bounds.left, greaterThan(0));
        expect(bounds.right, lessThan(viewport.width));
        expect(bounds.top, greaterThan(viewport.top));
        expect(bounds.bottom, lessThan(viewport.height - 34));
        image.dispose();
        return pixels;
      });
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(listEquals(firstFrame, bytes!.buffer.asUint8List()), isTrue);
        image.dispose();
      });
      expect(find.byKey(const Key('splash-brand-lockup')), findsNothing);
      expect(find.byKey(const Key('splash-script-title')), findsNothing);
      expect(find.byKey(const Key('splash-bold-caption')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    File('${output.path}/wordmark-layout-measurements.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(measurements),
    );
  });
}

Rect _wordmarkBounds(Uint8List rgba, int width, int height) {
  var left = width;
  var right = 0;
  var top = height;
  var bottom = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 4;
      if (rgba[index] < 100 && rgba[index + 1] < 100 && rgba[index + 2] < 120) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  expect(left, lessThan(right));
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

class _ReadyResolver implements SplashDestinationResolver {
  const _ReadyResolver();

  @override
  Future<StartupDestination> resolve() async =>
      const StartupDestination(AppRoutes.login);
}
