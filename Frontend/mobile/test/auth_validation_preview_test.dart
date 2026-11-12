import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/email_verification.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/auth_screen.dart';
import 'package:mobile/features/auth/presentation/auth_wave_header.dart';

const _capture = bool.fromEnvironment('CAPTURE_AUTH_VALIDATION');
const _submit = Key('auth-submit-button');
const _modeLink = Key('auth-mode-link');
final _output = Directory(
  '${Directory.current.parent.parent.path}/output/auth-validation-fix-20261111',
);
final _results = <Map<String, dynamic>>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in fonts.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load((font as Map)['asset'] as String));
      }
      await loader.load();
    }
  });
  tearDownAll(() {
    if (!_capture) return;
    _output.createSync(recursive: true);
    File('${_output.path}/validation-metadata.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'source': 'Actual Flutter AuthScreen, bundled Poppins, inert API',
        'logicalSize': [393, 852],
        'pixelRatio': 3,
        'networkRequests': 0,
        'cases': _results,
      }),
    );
  });

  for (final scenario in [
    const _Scenario('normal', Size(393, 852), 59, 34),
    const _Scenario('small', Size(375, 667), 20, 0),
    const _Scenario('keyboard', Size(393, 852), 59, 34, keyboard: 346),
    const _Scenario('large-text', Size(393, 852), 59, 34, textScale: 1.6),
  ]) {
    for (final mode in AuthScreenMode.values) {
      testWidgets('empty ${mode.name} errors stay in place: ${scenario.name}', (
        tester,
      ) async {
        _usePhone(tester, scenario);
        final boundary = GlobalKey();
        final repository = _PreviewRepository();
        await tester.pumpWidget(_app(boundary, scenario, mode, repository));
        await tester.pump();
        final before = _geometry(tester, mode);
        if (scenario.name == 'normal') {
          expect(
            before['headerHeight'],
            mode == AuthScreenMode.login ? 328 : 210,
          );
        }
        final stem = '${scenario.name}-${mode.name}';
        final beforeRaster = await _raster(
          tester,
          boundary,
          '$stem-before.png',
        );
        await tester.ensureVisible(find.byKey(_submit));
        await tester.pump();
        if (scenario.name == 'normal') {
          final buttonRect = tester.getRect(find.byKey(_submit));
          final gesture = await tester.startGesture(buttonRect.center);
          await tester.pump(const Duration(milliseconds: 16));
          final down = await _raster(tester, boundary, '$stem-submit-down.png');
          expect(
            listEquals(
              beforeRaster.region(buttonRect),
              down.region(buttonRect),
            ),
            isTrue,
            reason: 'Primary touch must not add a gray overlay or ripple.',
          );
          await gesture.up();
        } else {
          await tester.tap(find.byKey(_submit));
        }
        await tester.pump();
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: 'Local validation must not start fake loading.',
        );
        final errors = <String, String>{};
        for (final key in _fieldKeys(mode)) {
          final field = find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(TextFormField),
          );
          final state = tester.state<FormFieldState<String>>(field);
          expect(
            state.hasError,
            isTrue,
            reason: '$key must reject an empty value immediately.',
          );
          expect(state.errorText, isNotEmpty);
          errors[key] = state.errorText!;
          expect(find.text(state.errorText!), findsOneWidget);
        }
        expect(repository.calls, 0);
        await tester.pump(const Duration(milliseconds: 300));
        await _scrollTop(tester);
        final after = _geometry(tester, mode);
        for (final key in [
          'headerHeight',
          'headerCompact',
          'signRect',
          'captionRect',
          'signFontSize',
          'captionFontSize',
          'fieldRects',
          'controlRects',
        ]) {
          expect(
            after[key],
            before[key],
            reason: '$key must not collapse or shift after validation.',
          );
        }
        var errorRaster = await _raster(tester, boundary, '$stem-errors.png');
        final redLines = <String, int>{};
        for (final key in _fieldKeys(mode)) {
          // The keyboard preserves the full header now; reveal fields through
          // the body viewport rather than requiring a globally shrunken form.
          if (!_withinViewport(
            tester.getRect(find.byKey(Key(key))),
            scenario,
          )) {
            await tester.ensureVisible(find.byKey(Key(key)));
            await tester.pump();
            errorRaster = await _raster(
              tester,
              boundary,
              '$stem-errors-$key.png',
            );
          }
          final rect = tester.getRect(find.byKey(Key(key)));
          final longestRedRow = errorRaster.longestRedRow(rect);
          expect(
            longestRedRow,
            greaterThan(rect.width * errorRaster.ratio * 0.75),
            reason: '$key must visibly render a red underline.',
          );
          redLines[key] = longestRedRow;
        }
        await _expectReachable(tester, scenario, mode, errors.values);
        expect(tester.takeException(), isNull);
        _results.add({
          'scenario': scenario.name,
          'mode': mode.name,
          'before': before,
          'after': after,
          'errors': errors,
          'longestRedUnderlinePixelRows': redLines,
          'repositoryCalls': repository.calls,
          'allControlsAndParentNoteReachable': true,
          'noRenderOverflow': true,
        });
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
    'native button wordmark flips without blue fading or touch overlay',
    (tester) async {
      const scenario = _Scenario('normal', Size(393, 852), 59, 34);
      _usePhone(tester, scenario);
      final boundary = GlobalKey();
      final repository = _PreviewRepository();
      await tester.pumpWidget(
        _app(
          boundary,
          scenario,
          AuthScreenMode.login,
          repository,
          reduceMotion: false,
        ),
      );
      await tester.pump();
      var frame = 0;
      Rect? anchoredButtonSign;
      List<int>? fixedHeaderSign;
      final blueChecks = <List<int>>[];
      Future<void> record(int count) async {
        for (var index = 0; index < count; index++) {
          await tester.pump(const Duration(microseconds: 33333));
          final button = tester.getRect(find.byKey(_submit));
          final sign = tester.getRect(
            find.byKey(const Key('auth-submit-sign-label')),
          );
          final localSign = sign.shift(-button.topLeft);
          anchoredButtonSign ??= localSign;
          expect(
            (localSign.left - anchoredButtonSign!.left).abs(),
            lessThan(0.01),
          );
          expect(
            (localSign.top - anchoredButtonSign!.top).abs(),
            lessThan(0.01),
          );
          final raster = await _raster(
            tester,
            boundary,
            'button-frames/frame-${frame.toString().padLeft(4, '0')}.png',
            ratio: 2,
          );
          expect(
            raster.whitePixels(sign),
            greaterThan(30),
            reason: 'Button Sign stays visible in frame $frame.',
          );
          final headerSign = raster.region(
            tester.getRect(find.byKey(const Key('auth-sign-label'))),
          );
          fixedHeaderSign ??= headerSign;
          expect(listEquals(headerSign, fixedHeaderSign), isTrue);
          final background = raster.colorAt(
            Offset(button.center.dx, button.top + 6),
          );
          expect(
            background.take(3).toList(),
            [20, 87, 255],
            reason: 'Primary stays solid blue in frame $frame.',
          );
          blueChecks.add(background);
          expect(tester.takeException(), isNull);
          frame++;
        }
      }

      await record(6);
      for (var direction = 0; direction < 2; direction++) {
        final link = tester.getRect(find.byKey(_modeLink));
        final idle = await _raster(
          tester,
          boundary,
          'mode-link-$direction-idle.png',
          ratio: 2,
        );
        final gesture = await tester.startGesture(link.center);
        await tester.pump(const Duration(milliseconds: 16));
        final down = await _raster(
          tester,
          boundary,
          'mode-link-$direction-down.png',
          ratio: 2,
        );
        expect(
          listEquals(idle.region(link), down.region(link)),
          isTrue,
          reason: 'Mode link touch must not show a gray overlay or ripple.',
        );
        await gesture.up();
        await tester.pump();
        await record(30);
        await record(6);
      }
      expect(repository.calls, 0);
      if (_capture) {
        File('${_output.path}/button-motion-metadata.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'source': 'Actual Flutter AuthScreen button wordmark',
            'logicalSize': [393, 852],
            'pixelRatio': 2,
            'framesPerSecond': 30,
            'frameCount': frame,
            'buttonSignAnchoredAndVisibleEveryFrame': true,
            'headerSignExactRgbaEveryFrame': true,
            'solidBlueEveryFrame': true,
            'backgroundRgbaPerFrame': blueChecks,
            'noGrayTouchOverlay': true,
          }),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in AuthScreenMode.values) {
    testWidgets('fast ${mode.name} request still displays 600ms spinner', (
      tester,
    ) async {
      const scenario = _Scenario('normal', Size(393, 852), 59, 34);
      _usePhone(tester, scenario);
      final boundary = GlobalKey();
      final repository = _PreviewRepository(succeed: true);
      await tester.pumpWidget(_app(boundary, scenario, mode, repository));
      await tester.pump();
      await tester.enterText(
        _editable('auth-email-field'),
        'parent@example.com',
      );
      await tester.enterText(
        _editable('auth-password-field'),
        'preview-password-2026',
      );
      if (mode == AuthScreenMode.register) {
        await tester.enterText(
          _editable('auth-confirm-password-field'),
          'preview-password-2026',
        );
      }
      await tester.ensureVisible(find.byKey(_submit));
      await tester.tap(find.byKey(_submit));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Offline preview next route'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await _raster(tester, boundary, 'normal-${mode.name}-busy-500ms.png');
      await tester.pump(const Duration(milliseconds: 99));
      expect(find.text('Offline preview next route'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Offline preview next route'), findsOneWidget);
      expect(repository.calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _Scenario {
  const _Scenario(
    this.name,
    this.size,
    this.top,
    this.bottom, {
    this.keyboard = 0,
    this.textScale = 1,
  });
  final String name;
  final Size size;
  final double top, bottom, keyboard, textScale;
}

void _usePhone(WidgetTester tester, _Scenario scenario) {
  tester.view.physicalSize = scenario.size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(
    top: scenario.top,
    bottom: scenario.bottom,
  );
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
}

Widget _app(
  GlobalKey boundary,
  _Scenario scenario,
  AuthScreenMode mode,
  AuthRepository repository, {
  bool reduceMotion = true,
}) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    theme: buildKingdomKidsTheme(),
    debugShowCheckedModeBanner: false,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: EdgeInsets.only(
          top: scenario.top,
          bottom: scenario.keyboard > 0 ? 0 : scenario.bottom,
        ),
        viewPadding: EdgeInsets.only(
          top: scenario.top,
          bottom: scenario.bottom,
        ),
        viewInsets: EdgeInsets.only(bottom: scenario.keyboard),
        textScaler: TextScaler.linear(scenario.textScale),
        disableAnimations: reduceMotion,
      ),
      child: child!,
    ),
    home: AuthScreen(
      initialMode: mode,
      repository: repository,
      externalUrlLauncher: (_) async => true,
    ),
    onGenerateRoute: (_) => MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Offline preview next route')),
    ),
  ),
);
List<String> _fieldKeys(AuthScreenMode mode) => [
  'auth-email-field',
  'auth-password-field',
  if (mode == AuthScreenMode.register) 'auth-confirm-password-field',
];
const _controlKeys = [
  'auth-submit-button',
  'auth-privacy-policy',
  'auth-mode-link',
  'auth-parent-safety-note',
];
Finder _editable(String key) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField));
Map<String, double> _rect(Rect rect) => {
  'left': rect.left,
  'top': rect.top,
  'right': rect.right,
  'bottom': rect.bottom,
};
Map<String, dynamic> _geometry(WidgetTester tester, AuthScreenMode mode) {
  final header = tester.widget<AuthWaveHeader>(find.byType(AuthWaveHeader));
  final caption = find.text(
    mode == AuthScreenMode.login ? 'Welcome back!' : 'Hey, welcome!',
  );
  final sign = find.byKey(const Key('auth-sign-label'));
  return {
    'headerHeight': header.height,
    'headerCompact': header.compact,
    'signRect': _rect(tester.getRect(sign)),
    'captionRect': caption.evaluate().isEmpty
        ? null
        : _rect(tester.getRect(caption)),
    'signFontSize': tester.widget<Text>(sign).style?.fontSize,
    'captionFontSize': caption.evaluate().isEmpty
        ? null
        : tester.widget<Text>(caption).style?.fontSize,
    'fieldRects': {
      for (final key in _fieldKeys(mode))
        key: _rect(tester.getRect(find.byKey(Key(key)))),
    },
    'controlRects': {
      for (final key in _controlKeys)
        key: _rect(tester.getRect(find.byKey(Key(key)))),
    },
  };
}

Future<void> _scrollTop(WidgetTester tester) async {
  final scroll = find.byType(SingleChildScrollView);
  if (scroll.evaluate().isNotEmpty) {
    final state = tester.state<ScrollableState>(
      find
          .descendant(of: scroll.first, matching: find.byType(Scrollable))
          .first,
    );
    state.position.jumpTo(state.position.minScrollExtent);
    await tester.pump();
  }
}

bool _withinViewport(Rect rect, _Scenario scenario) =>
    rect.top >= scenario.top - 0.5 &&
    rect.bottom <=
        scenario.size.height -
            (scenario.keyboard > 0 ? scenario.keyboard : scenario.bottom) +
            0.5;
Future<void> _expectReachable(
  WidgetTester tester,
  _Scenario scenario,
  AuthScreenMode mode,
  Iterable<String> errors,
) async {
  for (final finder in [
    ..._fieldKeys(mode).map((key) => find.byKey(Key(key))),
    ...errors.map(find.text),
    ..._controlKeys.map((key) => find.byKey(Key(key))),
  ]) {
    await tester.ensureVisible(finder);
    await tester.pump();
    expect(finder.hitTestable(), findsOneWidget);
    expect(_withinViewport(tester.getRect(finder), scenario), isTrue);
    expect(tester.takeException(), isNull);
  }
}

Future<_Raster> _raster(
  WidgetTester tester,
  GlobalKey boundary,
  String name, {
  double ratio = 3,
}) async => (await tester.runAsync(() async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage(pixelRatio: ratio);
  try {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (_capture) {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${_output.path}/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    }
    return _Raster(image.width, image.height, ratio, raw!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}))!;

class _Raster {
  _Raster(this.width, this.height, this.ratio, this.pixels);
  final int width, height;
  final double ratio;
  final List<int> pixels;
  List<int> region(Rect rect) {
    final result = <int>[];
    for (
      var y = (rect.top * ratio).floor();
      y < (rect.bottom * ratio).ceil();
      y++
    ) {
      result.addAll(
        pixels.sublist(
          (y * width + (rect.left * ratio).floor()) * 4,
          (y * width + (rect.right * ratio).ceil()) * 4,
        ),
      );
    }
    return result;
  }

  List<int> colorAt(Offset point) {
    final start =
        ((point.dy * ratio).floor() * width + (point.dx * ratio).floor()) * 4;
    return pixels.sublist(start, start + 4);
  }

  int whitePixels(Rect rect) {
    final data = region(rect);
    var count = 0;
    for (var index = 0; index < data.length; index += 4) {
      if (data[index] > 245 && data[index + 1] > 245 && data[index + 2] > 245) {
        count++;
      }
    }
    return count;
  }

  int longestRedRow(Rect rect) {
    var maximum = 0;
    for (
      var y = (rect.top * ratio).floor();
      y < (rect.bottom * ratio).ceil();
      y++
    ) {
      var count = 0;
      for (
        var x = (rect.left * ratio).floor();
        x < (rect.right * ratio).ceil();
        x++
      ) {
        final offset = (y * width + x) * 4;
        final r = pixels[offset],
            g = pixels[offset + 1],
            b = pixels[offset + 2];
        if (r > 120 && r > g + 35 && r > b + 25) count++;
      }
      if (count > maximum) maximum = count;
    }
    return maximum;
  }
}

class _PreviewRepository extends AuthRepository {
  _PreviewRepository({this.succeed = false})
    : super(api: _OfflineApi(), sessionStore: MemoryAuthSessionStore());
  final bool succeed;
  int calls = 0;
  @override
  Future<AuthSession> login(LoginRequest request) async {
    calls++;
    if (!succeed) {
      throw StateError('Empty validation must not request authentication.');
    }
    return const AuthSession(
      parent: ParentAccount(id: 'offline-preview', email: 'parent@example.com'),
      accessToken: 'offline-inert-token',
    );
  }

  @override
  Future<PendingEmailVerification> register(
    RegisterParentRequest request,
  ) async {
    calls++;
    if (!succeed) {
      throw StateError('Empty validation must not create an account.');
    }
    return const PendingEmailVerification(
      challengeId: 'offline-preview',
      email: 'parent@example.com',
      destinationHint: 'pa••••@example.com',
      expiresInSeconds: 600,
      resendAfterSeconds: 60,
    );
  }
}

class _OfflineApi implements AuthApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No network API exists in this preview.');
}
