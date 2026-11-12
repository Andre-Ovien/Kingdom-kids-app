import 'package:flutter/widgets.dart';

import 'app_audio_controller.dart';

/// Device-wide audio controls. Standalone screen previews can omit this host.
class AppAudioScope extends InheritedNotifier<AppAudioController> {
  const AppAudioScope({
    super.key,
    required AppAudioController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppAudioController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppAudioScope>()?.notifier;
}
