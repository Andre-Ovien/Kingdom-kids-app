# Streak design before the flame update

This folder preserves the exact streak screen and its matching screen tests before the approved light-background animated-flame design. The character artwork and shared character widgets were not deleted.

Verify the saved files from this folder with `shasum -a 256 -c SHA256SUMS`.

To restore the previous screen and its matching tests, run these commands from the repository root:

```sh
cp docs/design-archive/streak-before-flame-20261111/streak_screen.dart.txt Frontend/mobile/lib/features/streak/presentation/streak_screen.dart
cp docs/design-archive/streak-before-flame-20261111/streak_screen_test.dart.txt Frontend/mobile/test/streak_screen_test.dart
cd Frontend/mobile
flutter test --no-pub test/streak_screen_test.dart
```

Restoring these files affects the streak presentation only. It does not reset a session, change streak/reward data, or replay a daily claim. Any separate development-only review entry point should be disabled when returning to ordinary startup.
