# Blue wave auth V2 — 11 November 2026

Direct source snapshot of the approved vivid-blue auth redesign before phone installation. The previous installed design is independently preserved in `../auth-before-blue-wave-20261111/`.

This version uses #1457FF, a deeper Sign In header, the reference-traced asymmetric two-drop curve, thin underlined fields, and one 680 ms controller for the wave, anchored Sign title, flipping In/Up suffix and form motion. Password reset and onboarding are separate.

## Restore

Preserve the current active files in a new dated folder, then copy `auth_screen.dart.txt` and `auth_wave_header.dart.txt` into `Frontend/mobile/lib/features/auth/presentation/` under their `.dart` names. Copy the three archived test files into `Frontend/mobile/test/` under their `.dart` names. The current project already supplies the bundled OnboardingPoppins font and dependencies; the pubspec snapshots are references.

Run the auth functional/layout tests and the preview test before a requested rebuild. Source hashes and preview evidence are in `provenance.json`; `preview-comparison.png` and `preview-motion.mp4` preserve the reviewed visual treatment. No restore was executed when this archive was created.
