import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/profile_picker_concept.dart';

const _capture = bool.fromEnvironment('CAPTURE_PROFILE_CONCEPT');
const _step = Duration(microseconds: 33333);

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
  });

  testWidgets('isolated profile concept renders all three original bodies', (
    tester,
  ) async {
    _phone(tester);
    final output = _output();
    for (var index = 0; index < profilePickerConceptEntries.length; index++) {
      final entry = profilePickerConceptEntries[index];
      final boundary = GlobalKey();
      await tester.pumpWidget(_app(boundary, initialPage: index));
      await _loadImages(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Who’s ready\nto explore?'), findsOneWidget);
      expect(
        find.byKey(Key('profile-concept-name-${entry.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('profile-concept-select-${entry.id}')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester
            .getRect(find.byKey(Key('profile-concept-name-${entry.id}')))
            .bottom,
        lessThan(780),
      );
      if (_capture) {
        await _png(
          tester,
          boundary,
          '${output.path}/${entry.name.toLowerCase()}-393x852.png',
          ratio: 3,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('dots/swipe change page and arrow selects the visible fixture', (
    tester,
  ) async {
    _phone(tester);
    var addCount = 0;
    String? selected;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      _app(
        boundary,
        onAdd: () => addCount++,
        onSelect: (entry) => selected = entry.id,
      ),
    );
    await _loadImages(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-concept-add')));
    expect(addCount, 1);
    await tester.tap(find.byKey(const Key('profile-concept-dot-1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('profile-concept-select-preview-nia')),
    );
    expect(selected, 'preview-nia');
    await tester.drag(
      find.byKey(const Key('profile-concept-pages')),
      const Offset(-330, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('profile-concept-select-preview-zuri')),
    );
    expect(selected, 'preview-zuri');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native carousel recording uses the actual isolated widget', (
    tester,
  ) async {
    _phone(tester);
    final boundary = GlobalKey();
    await tester.pumpWidget(_app(boundary));
    await _loadImages(tester);
    await tester.pumpAndSettle();
    var frame = 0;
    Future<void> record(int count) async {
      for (var index = 0; index < count; index++) {
        await tester.pump(_step);
        expect(tester.takeException(), isNull);
        if (_capture) {
          await _png(
            tester,
            boundary,
            '${_output().path}/frames/frame-${frame.toString().padLeft(4, '0')}.png',
            ratio: 2,
          );
        }
        frame++;
      }
    }

    await record(24);
    await tester.tap(find.byKey(const Key('profile-concept-dot-1')));
    await record(18);
    await record(24);
    await tester.tap(find.byKey(const Key('profile-concept-dot-2')));
    await record(18);
    await record(24);
    if (_capture) {
      await tester.runAsync(() async {
        await File('${_output().path}/capture-metadata.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'source': 'Actual isolated Flutter profile picker concept',
            'fixtureNames': ['Kai', 'Nia', 'Zuri'],
            'fixtureOnly': true,
            'installedOrRouterChanged': false,
            'logicalSize': [393, 852],
            'safeAreas': {'top': 59, 'bottom': 34},
            'endpointPixelRatio': 3,
            'motionPixelRatio': 2,
            'framesPerSecond': 30,
            'frames': frame,
            'colors': ['#009F6C', '#854AE4', '#F84D68'],
            'artwork': 'Original transparent full body exports, unchanged',
          }),
        );
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _app(
  GlobalKey boundary, {
  int initialPage = 0,
  VoidCallback? onAdd,
  ValueChanged<ProfilePickerConceptEntry>? onSelect,
}) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'OnboardingPoppins',
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF009F6C)),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: const EdgeInsets.only(top: 59, bottom: 34),
        viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
      ),
      child: child!,
    ),
    home: ProfilePickerConcept(
      initialPage: initialPage,
      onAddProfile: onAdd,
      onSelectProfile: onSelect,
    ),
  ),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
}

Future<void> _loadImages(WidgetTester tester) async {
  final context = tester.element(find.byType(ProfilePickerConcept));
  await tester.runAsync(() async {
    for (final entry in profilePickerConceptEntries) {
      await precacheImage(AssetImage(entry.asset), context);
    }
  });
  await tester.pump();
}

Directory _output() => Directory(
  '${Directory.current.parent.parent.path}/output/profile-picker-preview-20261111',
);

Future<void> _png(
  WidgetTester tester,
  GlobalKey boundary,
  String path, {
  required double ratio,
}) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: ratio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
