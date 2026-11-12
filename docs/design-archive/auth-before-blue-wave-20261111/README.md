# Auth before the blue wave — 11 November 2026

This is the purple Create Account / pink Sign In design with the animated eye mascot, compact registration page, privacy link and parent-only notice. It preserves the latest compact implementation installed on the iPhone before the blue-wave redesign.

The archived `auth_screen.dart.txt` is **byte-for-byte identical** to the source recorded in that installed build: SHA-256 `0a1b8ee103265bb606818835114ad3ce85de89f5ae644773f3e9c4187c366ad5`. Recovery used captured source reads and recorded edits in an isolated folder, then verified the final hash against the device-build provenance. It is not the older Git HEAD version.

## Contents

- `auth_screen.dart.txt`: exact installed auth source, including its self-contained mascot, palettes, fields and network/navigation hooks.
- `auth_screen_test.dart.txt`: recovered original auth tests. Its captured sections are exact; the short unchanged gap comes from Git and is not independently device-hash attested.
- `auth_compact_layout_test.dart.txt`: the compact-screen regression fixture, unchanged during the blue-wave task.
- `pubspec.yaml.txt`, `pubspec.lock.txt`: dependency references at archive time. The old auth UI needs no extra asset or package.
- `installed-build-source-provenance.json`, `provenance.json`, `dependency-hashes.json`, `recovery-steps.json`: verification and recovery evidence.

## Restore the UI

From the repository root, first preserve the currently active auth files in a new dated folder. Then copy:

```sh
cp docs/design-archive/auth-before-blue-wave-20261111/auth_screen.dart.txt Frontend/mobile/lib/features/auth/presentation/auth_screen.dart
cp docs/design-archive/auth-before-blue-wave-20261111/auth_screen_test.dart.txt Frontend/mobile/test/auth_screen_test.dart
cp docs/design-archive/auth-before-blue-wave-20261111/auth_compact_layout_test.dart.txt Frontend/mobile/test/auth_compact_layout_test.dart
```

The blue header file can stay on disk, unreferenced. The blue-specific preview test is tied to the new design; keep its archived copy and exclude that test when validating the old design. Use the current router, auth repository/API, storage, constants and shared audio files at their existing paths; their archive-time hashes are recorded. Treat the archived pubspec files as references rather than replacing unrelated dependency changes.

Validate from `Frontend/mobile`:

```sh
flutter test --no-pub test/auth_screen_test.dart test/auth_compact_layout_test.dart
flutter analyze --no-pub lib/features/auth/presentation/auth_screen.dart
```

Build with the normal `lib/main.dart` entrypoint and a reachable API configuration when a new device install is requested. This restores the authentication UI; onboarding, backend records and saved account data are independent.

A separately checksum-verified signed app rollback copy is preserved under `output/release-review-20261111/device/auth-before-blue-wave/Runner.app`. Development signing expires, so rebuilding the source may be required later. The approved replacement is separately archived in `../auth-blue-wave-v2-20261111/`.
