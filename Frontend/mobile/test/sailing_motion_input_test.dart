import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/data/sailing_motion_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = EventChannel(NativeSailingMotionInput.channelName);
  const methods = MethodChannel(NativeSailingMotionInput.channelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMessageHandler(channel.name, null);
  });

  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> emit(Object? value) async {
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeSuccessEnvelope(value),
      (_) {},
    );
    await flush();
  }

  test(
    'delivers finite right-positive values and clamps out-of-range samples',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return null;
      });
      final input = NativeSailingMotionInput(platform: TargetPlatform.iOS);
      final values = <double>[];
      final subscription = input.tilt.listen(values.add);
      await flush();
      for (final sample in [
        -3.0,
        -0.25,
        0,
        0.4,
        2.0,
        double.nan,
        double.infinity,
        'bad',
        null,
      ]) {
        await emit(sample);
      }
      expect(values, [-1.0, -0.25, 0.0, 0.4, 1.0]);
      await subscription.cancel();
      await flush();
      expect(calls, ['listen', 'cancel']);
    },
  );

  test(
    'missing native plugin is a stream error without global Flutter errors',
    () async {
      messenger.setMockMessageHandler(channel.name, (_) async => null);
      final errors = <Object>[];
      final globalErrors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = globalErrors.add;
      try {
        final subscription = NativeSailingMotionInput(
          platform: TargetPlatform.iOS,
        ).tilt.listen((_) {}, onError: errors.add);
        await flush();
        expect(errors, [isA<MissingPluginException>()]);
        expect(globalErrors, isEmpty);
        await subscription.cancel();
        await flush();
      } finally {
        FlutterError.onError = previous;
      }
    },
  );

  test(
    'unavailable sensor activation reaches the touch-fallback error handler',
    () async {
      final calls = <String>[];
      final errors = <Object>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        throw PlatformException(code: 'motion_unavailable');
      });
      final subscription = NativeSailingMotionInput(
        platform: TargetPlatform.android,
      ).tilt.listen((_) {}, onError: errors.add);
      await flush();
      expect(
        errors.single,
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'motion_unavailable',
        ),
      );
      await subscription.cancel();
      await flush();
      expect(calls, ['listen']);
    },
  );

  test('unsupported desktop never activates the native channel', () async {
    final calls = <String>[];
    final errors = <Object>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      return null;
    });
    final subscription = NativeSailingMotionInput(
      platform: TargetPlatform.macOS,
    ).tilt.listen((_) {}, onError: errors.add);
    await flush();
    expect(errors.single, isA<UnsupportedError>());
    expect(calls, isEmpty);
    await subscription.cancel();
  });

  test(
    'listeners share one sensor and only the final cancellation stops it',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return null;
      });
      final input = NativeSailingMotionInput(platform: TargetPlatform.iOS);
      final first = <double>[];
      final second = <double>[];
      final a = input.tilt.listen(first.add);
      final b = input.tilt.listen(second.add);
      await flush();
      expect(calls, ['listen']);
      await emit(0.3);
      expect(first, [0.3]);
      expect(second, [0.3]);
      await a.cancel();
      await flush();
      expect(calls, ['listen']);
      await b.cancel();
      await flush();
      expect(calls, ['listen', 'cancel']);
      final c = input.tilt.listen(second.add);
      await flush();
      expect(calls, ['listen', 'cancel', 'listen']);
      await c.cancel();
      await flush();
    },
  );

  test(
    'cancel during activation is serialized before a replacement listener',
    () async {
      final barrier = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (calls.length == 1) await barrier.future;
        return null;
      });
      final input = NativeSailingMotionInput(platform: TargetPlatform.android);
      final first = <double>[];
      final second = <double>[];
      final a = input.tilt.listen(first.add);
      await flush();
      await a.cancel();
      final b = input.tilt.listen(second.add);
      await emit(0.9);
      expect(first, isEmpty);
      expect(second, isEmpty);
      barrier.complete();
      await flush();
      expect(calls, ['listen', 'cancel', 'listen']);
      await emit(-0.6);
      expect(second, [-0.6]);
      await b.cancel();
      await flush();
    },
  );

  test(
    'native stream failures and endings propagate and release the channel',
    () async {
      final calls = <String>[];
      final errors = <Object>[];
      var ended = false;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return null;
      });
      final subscription = NativeSailingMotionInput(
        platform: TargetPlatform.iOS,
      ).tilt.listen((_) {}, onError: errors.add, onDone: () => ended = true);
      await flush();
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeErrorEnvelope(code: 'motion_unavailable'),
        (_) {},
      );
      await messenger.handlePlatformMessage(channel.name, null, (_) {});
      await flush();
      expect(errors.single, isA<PlatformException>());
      expect(ended, isTrue);
      expect(calls, ['listen', 'cancel']);
      await subscription.cancel();
    },
  );
}
