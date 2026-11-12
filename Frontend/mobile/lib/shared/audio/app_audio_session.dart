import 'dart:async';

import 'package:audio_session/audio_session.dart';

enum AppAudioFocusEvent { interrupted, resumed, headphonesRemoved }

abstract interface class AppAudioSessionGateway {
  Stream<AppAudioFocusEvent> get events;
  Future<bool> activate(bool Function() stillAllowed);
  Future<void> release({bool deactivate = false});
  Future<void> dispose();
}

/// Ambient UI sound respects the iOS silent switch and mixes with other apps.
/// Playback screens keep ownership of their own session configuration.
class AmbientAppAudioSession implements AppAudioSessionGateway {
  final _events = StreamController<AppAudioFocusEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  AudioSession? _session;
  AudioSessionConfiguration? _previousConfiguration;
  Future<bool>? _activation;
  bool _ownsConfiguration = false;
  bool _disposed = false;
  int _generation = 0;

  @override
  Stream<AppAudioFocusEvent> get events => _events.stream;

  @override
  Future<bool> activate(bool Function() stillAllowed) {
    if (_disposed || !stillAllowed()) return Future.value(false);
    final pending = _activation;
    if (pending != null) return pending;
    final request = _performActivation(stillAllowed);
    _activation = request;
    unawaited(
      request
          .whenComplete(() {
            if (identical(_activation, request)) _activation = null;
          })
          .catchError((Object _) => false),
    );
    return request;
  }

  Future<bool> _performActivation(bool Function() stillAllowed) async {
    final generation = _generation;
    bool valid() => !_disposed && generation == _generation && stillAllowed();
    try {
      final session = _session ??= await AudioSession.instance;
      if (!valid()) return false;
      if (_subscriptions.isEmpty) {
        _subscriptions.add(
          session.interruptionEventStream.listen((event) {
            if (_disposed || !_ownsConfiguration) return;
            if (event.begin) {
              _events.add(AppAudioFocusEvent.interrupted);
            } else if (event.type != AudioInterruptionType.unknown) {
              _events.add(AppAudioFocusEvent.resumed);
            }
          }),
        );
        _subscriptions.add(
          session.becomingNoisyEventStream.listen((_) {
            if (!_disposed && _ownsConfiguration) {
              _events.add(AppAudioFocusEvent.headphonesRemoved);
            }
          }),
        );
      }
      if (!_ownsConfiguration) {
        _previousConfiguration = session.configuration;
        _ownsConfiguration = true;
        await session.configure(
          const AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.ambient,
            avAudioSessionMode: AVAudioSessionMode.defaultMode,
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.music,
              usage: AndroidAudioUsage.game,
            ),
            androidAudioFocusGainType:
                AndroidAudioFocusGainType.gainTransientMayDuck,
            androidWillPauseWhenDucked: true,
          ),
        );
      }
      if (!valid()) return false;
      return await session.setActive(true) && valid();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> release({bool deactivate = false}) async {
    ++_generation;
    // Prevent an old activation from being reused when quickly changing routes.
    _activation = null;
    if (!_ownsConfiguration) return;
    _ownsConfiguration = false;
    final session = _session;
    final previous = _previousConfiguration;
    _previousConfiguration = null;
    if (session == null) return;
    try {
      // Restore the pre-existing mode before a reader/game creates its player.
      // Never deactivate here: that could stop a newly opened narration track.
      await session.configure(
        previous ?? const AudioSessionConfiguration.music(),
      );
      if (deactivate && !_ownsConfiguration) {
        await session.setActive(false);
      }
    } catch (_) {
      // Unavailable platform audio cannot interfere with navigation.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await release(deactivate: true);
    ++_generation;
    // Only dispose subscriptions; another feature may already own the session.
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _events.close();
  }
}
