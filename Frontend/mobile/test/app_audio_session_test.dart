import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/shared/audio/app_audio_session.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ryanheise.audio_session');
  final configurations = <AudioSessionConfiguration>[];
  Completer<void>? holdAmbientConfiguration;

  setUp(() {
    configurations.clear();
    holdAmbientConfiguration = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setConfiguration') {
        final arguments = call.arguments as List;
        final configuration = AudioSessionConfiguration.fromJson(
          Map<String, dynamic>.from(arguments.single as Map),
        );
        configurations.add(configuration);
        if (configuration.avAudioSessionCategory ==
            AVAudioSessionCategory.ambient) {
          await holdAmbientConfiguration?.future;
        }
      }
      return null;
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test(
    'UI ambience uses silent-switch-respecting mode then restores narration mode',
    () async {
      final session = await AudioSession.instance;
      const original = AudioSessionConfiguration.speech();
      await session.configure(original);
      configurations.clear();
      final gateway = AmbientAppAudioSession();
      expect(await gateway.activate(() => true), isTrue);
      expect(
        configurations.single.avAudioSessionCategory,
        AVAudioSessionCategory.ambient,
      );
      expect(configurations.single.androidWillPauseWhenDucked, isTrue);
      await gateway.release();
      expect(configurations.last.toJson(), original.toJson());
      expect(session.configuration!.toJson(), original.toJson());
      await gateway.dispose();
    },
  );

  test('a cancelled request never configures or activates ambience', () async {
    final gateway = AmbientAppAudioSession();
    var allowed = true;
    final activation = gateway.activate(() => allowed);
    allowed = false;
    expect(await activation, isFalse);
    expect(configurations, isEmpty);
    await gateway.dispose();
  });

  test(
    'late ambient setup cannot take ownership after playback handoff',
    () async {
      final session = await AudioSession.instance;
      const original = AudioSessionConfiguration.music();
      await session.configure(original);
      configurations.clear();
      final gateway = AmbientAppAudioSession();
      final pending = Completer<void>();
      holdAmbientConfiguration = pending;
      final activation = gateway.activate(() => true);
      for (var count = 0; count < 20 && configurations.isEmpty; count++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        configurations.single.avAudioSessionCategory,
        AVAudioSessionCategory.ambient,
      );
      await gateway.release();
      pending.complete();
      expect(await activation, isFalse);
      expect(session.configuration!.toJson(), original.toJson());
      await gateway.dispose();
      await gateway.dispose();
    },
  );
}
