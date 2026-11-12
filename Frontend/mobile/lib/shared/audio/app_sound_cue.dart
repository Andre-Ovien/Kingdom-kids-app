enum AppSoundCue { splash, streak, levelUp, tap, select, success }

extension AppSoundCueAsset on AppSoundCue {
  String get assetPath =>
      'assets/audio/app/${switch (this) {
        AppSoundCue.levelUp => 'level_up',
        _ => name,
      }}.wav';

  Duration get duration => switch (this) {
    AppSoundCue.splash => const Duration(milliseconds: 1800),
    AppSoundCue.streak => const Duration(seconds: 5),
    AppSoundCue.levelUp => const Duration(milliseconds: 2000),
    AppSoundCue.tap => const Duration(milliseconds: 80),
    AppSoundCue.select => const Duration(milliseconds: 240),
    AppSoundCue.success => const Duration(milliseconds: 940),
  };
}
