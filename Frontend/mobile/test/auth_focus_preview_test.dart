import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/presentation/auth_screen.dart';
import 'package:mobile/features/auth/presentation/auth_wave_header.dart';

const _capture = bool.fromEnvironment('CAPTURE_AUTH_FOCUS');
const _baseline = bool.fromEnvironment('AUTH_FOCUS_BASELINE');
final _output = Directory(
  '${Directory.current.parent.parent.path}/output/auth-focus-fix-20261111',
);

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

  for (final scenario in [
    (
      name: 'normal',
      size: const Size(393, 852),
      top: 59.0,
      bottom: 34.0,
      scale: 1.0,
      keyboard: 346.0,
    ),
    if (!_baseline)
      (
        name: 'small',
        size: const Size(375, 667),
        top: 20.0,
        bottom: 0.0,
        scale: 1.0,
        keyboard: 300.0,
      ),
    if (!_baseline)
      (
        name: 'large-text',
        size: const Size(393, 852),
        top: 59.0,
        bottom: 34.0,
        scale: 1.6,
        keyboard: 346.0,
      ),
  ]) {
    for (final mode in AuthScreenMode.values) {
      testWidgets(
        'real iOS focus survives keyboard metrics: ${scenario.name} ${mode.name}',
        (tester) async {
          tester.view.physicalSize = scenario.size;
          tester.view.devicePixelRatio = 1;
          tester.view.viewPadding = FakeViewPadding(
            top: scenario.top,
            bottom: scenario.bottom,
          );
          tester.view.padding = FakeViewPadding(
            top: scenario.top,
            bottom: scenario.bottom,
          );
          tester.view.viewInsets = FakeViewPadding.zero;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewInsets);
          final boundary = GlobalKey();
          final steps = <Map<String, dynamic>>[];
          final stem = '${scenario.name}-${mode.name}';
          addTearDown(() {
            _output.createSync(recursive: true);
            File(
              '${_output.path}/${_baseline ? 'baseline-' : ''}$stem-lifecycle.json',
            ).writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert({
                'platform': 'iOS',
                'scenario': scenario.name,
                'mode': mode.name,
                'actualViewMetrics': true,
                'networkRequests': 0,
                'steps': steps,
              }),
            );
          });
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                theme: buildKingdomKidsTheme().copyWith(
                  platform: TargetPlatform.iOS,
                ),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scenario.scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: AuthScreen(
                  initialMode: mode,
                  repository: AuthRepository(
                    api: _OfflineApi(),
                    sessionStore: MemoryAuthSessionStore(),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final original = _Identity.capture(tester, mode);
          final header = tester.widget<AuthWaveHeader>(
            find.byType(AuthWaveHeader),
          );
          final initialHeader = header.height;
          final initialHeaderCompact = header.compact;
          final initialSign = tester
              .widget<Text>(find.byKey(const Key('auth-sign-label')))
              .style!
              .fontSize;
          if (scenario.name == 'normal') {
            expect(initialHeader, mode == AuthScreenMode.login ? 328 : 210);
            _expectNoClosedScrolling(tester);
          }
          steps.add(_snapshot(tester, mode, 'closed-initial'));
          await _capturePng(tester, boundary, '$stem-closed.png');

          final email = _editable('auth-email-field');
          await tester.tap(email);
          await tester.pump();
          final emailFocus = tester.widget<EditableText>(email).focusNode;
          expect(emailFocus.hasFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          steps.add(_snapshot(tester, mode, 'email-focus-before-insets'));
          final focusLosses = <String>[];
          void watchEmailFocus() {
            if (!emailFocus.hasFocus) {
              focusLosses.add('email lost focus during metrics');
            }
          }

          emailFocus.addListener(watchEmailFocus);
          const composingValue = TextEditingValue(
            text: 'parent@example.com',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange(start: 0, end: 6),
          );
          tester.testTextInput.updateEditingValue(composingValue);
          await tester.pump();
          expect(
            tester.widget<EditableText>(email).controller.value,
            composingValue,
          );
          tester.testTextInput.log.clear();
          for (final inset in [80.0, 220.0, scenario.keyboard]) {
            await _setInset(tester, inset, scenario.top, scenario.bottom);
            steps.add(_snapshot(tester, mode, 'email-inset-${inset.round()}'));
            _assertIdentity(tester, original, mode);
            expect(
              emailFocus.hasFocus,
              isTrue,
              reason:
                  'Opening keyboard must keep the original email input focused.',
            );
            expect(focusLosses, isEmpty);
            _assertLiveInput(tester);
            expect(
              tester.widget<EditableText>(email).controller.value,
              composingValue,
              reason:
                  'Keyboard animation must preserve text, selection and IME composition.',
            );
            _assertHeader(
              tester,
              initialHeader,
              initialHeaderCompact,
              initialSign,
            );
            _assertNoInputTeardown(tester);
          }
          tester.testTextInput.enterText('parent@example.com');
          await tester.pump();
          expect(
            tester.widget<EditableText>(email).controller.text,
            'parent@example.com',
          );
          await _capturePng(tester, boundary, '$stem-email-keyboard.png');
          emailFocus.removeListener(watchEmailFocus);

          // Send the real IME action; tester.enterText would silently request
          // focus again and could conceal the device's keyboard bounce.
          await tester.testTextInput.receiveAction(TextInputAction.next);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          final password = _editable('auth-password-field');
          expect(
            tester.widget<EditableText>(password).focusNode.hasFocus,
            isTrue,
          );
          _assertIdentity(tester, original, mode);
          _assertLiveInput(tester);
          tester.testTextInput.enterText('focus-password-2026');
          await tester.pump();
          expect(
            tester.widget<EditableText>(password).controller.text,
            'focus-password-2026',
          );
          _expectEditableVisible(
            tester,
            password,
            scenario.size.height - scenario.keyboard,
          );
          steps.add(_snapshot(tester, mode, 'password-focused-and-typed'));
          await _capturePng(tester, boundary, '$stem-password-keyboard.png');
          if (mode == AuthScreenMode.register) {
            expect(
              tester.widget<EditableText>(password).textInputAction,
              TextInputAction.next,
            );
            await tester.testTextInput.receiveAction(TextInputAction.next);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            final confirm = _editable('auth-confirm-password-field');
            expect(
              tester.widget<EditableText>(confirm).focusNode.hasFocus,
              isTrue,
            );
            _assertIdentity(tester, original, mode);
            _assertLiveInput(tester);
            tester.testTextInput.enterText('focus-password-2026');
            await tester.pump();
            expect(
              tester.widget<EditableText>(confirm).controller.text,
              'focus-password-2026',
            );
            _expectEditableVisible(
              tester,
              confirm,
              scenario.size.height - scenario.keyboard,
            );
            steps.add(_snapshot(tester, mode, 'confirm-focused-and-typed'));
            await _capturePng(tester, boundary, '$stem-confirm-keyboard.png');
          }

          final activeFieldKey = mode == AuthScreenMode.register
              ? 'auth-confirm-password-field'
              : 'auth-password-field';
          final activeFocus = FocusManager.instance.primaryFocus;
          tester.testTextInput.log.clear();
          final bodyScroll = find.byType(SingleChildScrollView).first;
          await tester.drag(bodyScroll, const Offset(0, -48));
          await tester.pump(const Duration(milliseconds: 300));
          for (final key in [
            'auth-submit-button',
            'auth-privacy-policy',
            'auth-mode-link',
            'auth-parent-safety-note',
          ]) {
            final control = find.byKey(Key(key));
            await tester.ensureVisible(control);
            await tester.pump();
            expect(control.hitTestable(), findsOneWidget);
            expect(
              tester.getRect(control).bottom,
              lessThanOrEqualTo(scenario.size.height - scenario.keyboard + 0.5),
            );
            expect(FocusManager.instance.primaryFocus, same(activeFocus));
            _assertLiveInput(tester);
            _assertNoInputTeardown(tester);
          }
          await tester.ensureVisible(_editable(activeFieldKey));
          await tester.pump();
          _expectEditableVisible(
            tester,
            _editable(activeFieldKey),
            scenario.size.height - scenario.keyboard,
          );
          steps.add(_snapshot(tester, mode, 'body-panned-with-live-keyboard'));

          // Metrics can reverse and animate repeatedly without rebuilding the
          // input connection or finishing the active autofill context.
          tester.testTextInput.log.clear();
          final focused = FocusManager.instance.primaryFocus;
          for (final inset in [
            220.0,
            80.0,
            0.0,
            160.0,
            scenario.keyboard,
            0.0,
          ]) {
            await _setInset(tester, inset, scenario.top, scenario.bottom);
            steps.add(_snapshot(tester, mode, 'cycle-inset-${inset.round()}'));
            _assertIdentity(tester, original, mode);
            expect(FocusManager.instance.primaryFocus, same(focused));
            _assertLiveInput(tester);
            _assertHeader(
              tester,
              initialHeader,
              initialHeaderCompact,
              initialSign,
            );
            _assertNoInputTeardown(tester);
          }
          tester.testTextInput.enterText('retained-after-metrics');
          await tester.pump();
          final lastKey = mode == AuthScreenMode.register
              ? 'auth-confirm-password-field'
              : 'auth-password-field';
          expect(
            tester.widget<EditableText>(_editable(lastKey)).controller.text,
            'retained-after-metrics',
          );
          if (scenario.name == 'normal') _expectNoClosedScrolling(tester);
          steps.add(_snapshot(tester, mode, 'closed-restored-and-typed'));
          await _capturePng(tester, boundary, '$stem-restored.png');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
  }
}

Finder _editable(String key) => find.descendant(
  of: find.byKey(Key(key)),
  matching: find.byType(EditableText),
);
List<String> _keys(AuthScreenMode mode) => [
  'auth-email-field',
  'auth-password-field',
  if (mode == AuthScreenMode.register) 'auth-confirm-password-field',
];

class _Identity {
  _Identity(this.form, this.autofill, this.editables, this.focusNodes);
  final FormState form;
  final AutofillGroupState autofill;
  final Map<String, EditableTextState> editables;
  final Map<String, FocusNode> focusNodes;
  factory _Identity.capture(WidgetTester tester, AuthScreenMode mode) =>
      _Identity(
        tester.state<FormState>(find.byType(Form)),
        tester.state<AutofillGroupState>(find.byType(AutofillGroup)),
        {
          for (final key in _keys(mode))
            key: tester.state<EditableTextState>(_editable(key)),
        },
        {
          for (final key in _keys(mode))
            key: tester.widget<EditableText>(_editable(key)).focusNode,
        },
      );
}

void _assertIdentity(
  WidgetTester tester,
  _Identity original,
  AuthScreenMode mode,
) {
  expect(tester.state<FormState>(find.byType(Form)), same(original.form));
  expect(
    tester.state<AutofillGroupState>(find.byType(AutofillGroup)),
    same(original.autofill),
    reason:
        'Keyboard metrics must not dispose AutofillGroup and finish iOS autofill.',
  );
  for (final key in _keys(mode)) {
    expect(
      tester.state<EditableTextState>(_editable(key)),
      same(original.editables[key]),
    );
    expect(
      tester.widget<EditableText>(_editable(key)).focusNode,
      same(original.focusNodes[key]),
    );
  }
}

Future<void> _setInset(
  WidgetTester tester,
  double inset,
  double top,
  double bottom,
) async {
  tester.view.viewInsets = FakeViewPadding(bottom: inset);
  tester.view.padding = FakeViewPadding(
    top: top,
    bottom: inset > 0 ? 0 : bottom,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(tester.takeException(), isNull);
}

void _assertLiveInput(WidgetTester tester) {
  expect(tester.testTextInput.hasAnyClients, isTrue);
  expect(tester.testTextInput.isVisible, isTrue);
}

void _assertNoInputTeardown(WidgetTester tester) {
  expect(
    tester.testTextInput.log.where(
      (call) => [
        'TextInput.finishAutofillContext',
        'TextInput.hide',
        'TextInput.clearClient',
        'TextInput.setClient',
      ].contains(call.method),
    ),
    isEmpty,
    reason:
        'Keyboard metrics alone must not dismiss or recreate the input connection.',
  );
}

void _assertHeader(
  WidgetTester tester,
  double height,
  bool compact,
  double? fontSize,
) {
  final header = tester.widget<AuthWaveHeader>(find.byType(AuthWaveHeader));
  expect(
    header.height,
    height,
    reason: 'Keyboard focus must not globally shrink the header.',
  );
  expect(header.compact, compact);
  expect(
    tester
        .widget<Text>(find.byKey(const Key('auth-sign-label')))
        .style!
        .fontSize,
    fontSize,
  );
}

void _expectNoClosedScrolling(WidgetTester tester) {
  for (final element in find.byType(Scrollable).evaluate()) {
    final scroll = tester.state<ScrollableState>(
      find.byElementPredicate((candidate) => identical(candidate, element)),
    );
    if (scroll.position.axis == Axis.vertical) {
      expect(scroll.position.maxScrollExtent, lessThanOrEqualTo(0.5));
    }
  }
}

void _expectEditableVisible(WidgetTester tester, Finder finder, double bottom) {
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(
    rect.bottom,
    lessThanOrEqualTo(bottom + 0.5),
    reason: 'The focused input must remain above the keyboard.',
  );
}

Map<String, dynamic> _snapshot(
  WidgetTester tester,
  AuthScreenMode mode,
  String stage,
) {
  final header = tester.widget<AuthWaveHeader>(find.byType(AuthWaveHeader));
  return {
    'stage': stage,
    'inset': MediaQuery.of(
      tester.element(find.byType(AuthScreen)),
    ).viewInsets.bottom,
    'headerHeight': header.height,
    'headerCompact': header.compact,
    'formIdentity': identityHashCode(
      tester.state<FormState>(find.byType(Form)),
    ),
    'autofillIdentity': identityHashCode(
      tester.state<AutofillGroupState>(find.byType(AutofillGroup)),
    ),
    'fields': {
      for (final key in _keys(mode))
        key: {
          'editableIdentity': identityHashCode(
            tester.state<EditableTextState>(_editable(key)),
          ),
          'focusNodeIdentity': identityHashCode(
            tester.widget<EditableText>(_editable(key)).focusNode,
          ),
          'hasFocus': tester
              .widget<EditableText>(_editable(key))
              .focusNode
              .hasFocus,
          'textLength': tester
              .widget<EditableText>(_editable(key))
              .controller
              .text
              .length,
        },
    },
    'inputVisible': tester.testTextInput.isVisible,
    'hasInputClient': tester.testTextInput.hasAnyClients,
    'inputMethods': tester.testTextInput.log
        .map((call) => call.method)
        .toList(),
  };
}

Future<void> _capturePng(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  if (!_capture) return;
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 3);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await _output.create(recursive: true);
      await File(
        '${_output.path}/$name',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

class _OfflineApi implements AuthApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Focus review has no network API.');
}
