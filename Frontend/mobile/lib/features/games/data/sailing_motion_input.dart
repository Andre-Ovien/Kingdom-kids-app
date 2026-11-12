import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Screen-relative gravity: leaning left is negative and right is positive.
abstract interface class SailingMotionInput {
  Stream<double> get tilt;
}

/// The native sensor runs only while this broadcast stream has listeners.
/// Callers cancel their subscription when the game pauses or closes.
class NativeSailingMotionInput implements SailingMotionInput {
  NativeSailingMotionInput({EventChannel? channel, TargetPlatform? platform})
    : _channel = channel ?? const EventChannel(channelName),
      _platform = platform ?? defaultTargetPlatform;

  static const channelName = 'kingdom_kids/sailing_motion';
  final EventChannel _channel;
  final TargetPlatform _platform;
  late final Stream<double> _tilt = _createStream();

  @override
  Stream<double> get tilt => _tilt;

  Stream<double> _createStream() {
    if (kIsWeb ||
        (_platform != TargetPlatform.iOS &&
            _platform != TargetPlatform.android)) {
      return Stream<double>.error(
        UnsupportedError('Device tilt is unavailable on this platform.'),
      ).asBroadcastStream();
    }

    final messenger = _channel.binaryMessenger;
    final methods = MethodChannel(_channel.name, _channel.codec, messenger);
    late final StreamController<double> controller;
    Future<void> operations = Future<void>.value();
    var generation = 0;
    var nativeListening = false;

    void enqueue(Future<void> Function() operation) {
      operations = operations.then((_) => operation());
    }

    controller = StreamController<double>.broadcast(
      onListen: () {
        final request = ++generation;
        enqueue(() async {
          if (request != generation || !controller.hasListener) return;
          messenger.setMessageHandler(_channel.name, (data) async {
            if (request != generation || !controller.hasListener) return null;
            if (data == null) {
              unawaited(controller.close());
              return null;
            }
            try {
              final value = _channel.codec.decodeEnvelope(data);
              if (value is num && value.isFinite) {
                controller.add(value.toDouble().clamp(-1.0, 1.0));
              }
            } catch (error, stack) {
              controller.addError(error, stack);
            }
            return null;
          });
          try {
            await methods.invokeMethod<void>('listen');
            nativeListening = true;
          } catch (error, stack) {
            messenger.setMessageHandler(_channel.name, null);
            if (request == generation && controller.hasListener) {
              // EventChannel's default activation reports a global Flutter
              // error. Deliver missing plugins through this stream instead,
              // so the game can offer its touch controls without crashing.
              controller.addError(error, stack);
            }
          }
        });
      },
      onCancel: () {
        ++generation;
        enqueue(() async {
          messenger.setMessageHandler(_channel.name, null);
          if (!nativeListening) return;
          nativeListening = false;
          try {
            await methods.invokeMethod<void>('cancel');
          } catch (_) {
            // A detached engine no longer owns a sensor subscription.
          }
        });
      },
    );
    return controller.stream;
  }
}
