import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/presentation/profile_picker_carousel.dart';

const _capture = bool.fromEnvironment('CAPTURE_PROFILE_PRODUCTION');
const _profiles = [
  KidProfile(
    id: 'king',
    parentId: 'fixture',
    displayName: 'King',
    avatarKey: 'lion',
  ),
  KidProfile(
    id: 'maya',
    parentId: 'fixture',
    displayName: 'Maya',
    avatarKey: 'dove',
  ),
  KidProfile(
    id: 'zoe',
    parentId: 'fixture',
    displayName: 'Zoe',
    avatarKey: 'rainbow',
  ),
];

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

  testWidgets('native child-name and canonical-subtitle capture', (
    tester,
  ) async {
    _phone(tester, const Size(393, 852));
    final boundary = GlobalKey();
    await tester.pumpWidget(_app(boundary, profiles: _profiles));
    await _loadImages(tester);
    await tester.pumpAndSettle();
    for (var i = 0; i < _profiles.length; i++) {
      if (i > 0) {
        await tester.tap(
          find.byKey(Key('profile-picker-dot-${_profiles[i].id}')),
        );
        await tester.pumpAndSettle();
      }
      _expectLabelsAndControls(tester, _profiles[i]);
      if (_capture) {
        await _png(
          tester,
          boundary,
          '${_output().path}/${_profiles[i].id}-native.png',
        );
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in [
    (
      name: 'compact-long-name',
      size: Size(320, 568),
      scale: 1.0,
      avatar: 'lion',
    ),
    (
      name: 'large-text-long-name',
      size: Size(393, 852),
      scale: 1.6,
      avatar: 'rainbow',
    ),
    (name: 'legacy-avatar', size: Size(393, 852), scale: 1.0, avatar: 'star'),
  ]) {
    testWidgets('profile name layout: ${scenario.name}', (tester) async {
      _phone(tester, scenario.size);
      final profile = KidProfile(
        id: scenario.name,
        parentId: 'fixture',
        displayName: 'Alexandria-Rose Montgomery',
        avatarKey: scenario.avatar,
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        _app(boundary, profiles: [profile], scale: scenario.scale),
      );
      await _loadImages(tester);
      await tester.pumpAndSettle();
      _expectLabelsAndControls(tester, profile);
      if (_capture) {
        await _png(tester, boundary, '${_output().path}/${scenario.name}.png');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('fresh profile lists retain the visible child by ID', (
    tester,
  ) async {
    _phone(tester, const Size(393, 852));
    final first = _profiles[0];
    final second = _profiles[1].copyWith(avatarKey: 'lion');
    final third = _profiles[2].copyWith(avatarKey: 'lion');
    final profiles = ValueNotifier<List<KidProfile>>([first, second, third]);
    addTearDown(profiles.dispose);
    String? selectedId;
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<List<KidProfile>>(
          valueListenable: profiles,
          builder: (_, values, _) => ProfilePickerCarousel(
            profiles: values,
            onAddProfile: () {},
            onSelectProfile: (profile) => selectedId = profile.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('profile-picker-dot-${second.id}')));
    await tester.pumpAndSettle();
    profiles.value = [second, third, first];
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('profile-picker-select-${second.id}')));
    expect(selectedId, second.id);
    profiles.value = [third, first];
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('profile-picker-select-${third.id}')));
    expect(selectedId, third.id);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

void _expectLabelsAndControls(WidgetTester tester, KidProfile profile) {
  expect(tester.takeException(), isNull);
  final name = find.byKey(Key('profile-picker-display-name-${profile.id}'));
  final subtitle = find.byKey(
    Key('profile-picker-character-name-${profile.id}'),
  );
  final arrow = find.byKey(Key('profile-picker-select-${profile.id}'));
  expect(name, findsOneWidget);
  expect(subtitle, findsOneWidget);
  expect(arrow.hitTestable(), findsOneWidget);
  expect(
    find.byKey(const Key('profile-picker-add-child')).hitTestable(),
    findsOneWidget,
  );
  expect(tester.getRect(name).right, lessThan(tester.getRect(arrow).left));
  expect(
    tester.getRect(subtitle).top,
    greaterThanOrEqualTo(tester.getRect(name).bottom),
  );
  expect(
    tester.getRect(subtitle).bottom,
    lessThan(tester.view.physicalSize.height - 34),
  );
  expect(tester.widget<Text>(name).data, profile.displayName);
}

Widget _app(
  GlobalKey boundary, {
  required List<KidProfile> profiles,
  double scale = 1,
}) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'OnboardingPoppins', useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: const EdgeInsets.only(top: 59, bottom: 34),
        viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
        textScaler: TextScaler.linear(scale),
      ),
      child: child!,
    ),
    home: ProfilePickerCarousel(
      profiles: profiles,
      onAddProfile: () {},
      onSelectProfile: (_) {},
    ),
  ),
);

void _phone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _loadImages(WidgetTester tester) async {
  final context = tester.element(find.byType(ProfilePickerCarousel));
  await tester.runAsync(() async {
    for (final asset in [
      'assets/images/mascot/mascot_wave.png',
      'assets/images/characters/poses/nia-standing.png',
      'assets/images/characters/poses/zuri-standing.png',
    ]) {
      await precacheImage(AssetImage(asset), context);
    }
  });
  await tester.pump();
}

Directory _output() => Directory(
  '${Directory.current.parent.parent.path}/output/profile-picker-installed-ui-20261111',
);

Future<void> _png(WidgetTester tester, GlobalKey boundary, String path) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 3);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
