# Rejected frosted navigation, before persistent native glass

Saved exact navigation and app host source before introducing the persistent native-navigation host. `liquid_glass.dart` and screen source files were not altered for the saved design.

Verify this directory with `shasum -a 256 -c SHA256SUMS`.

To restore this prior design from the repository root:

```sh
cp docs/design-archive/navigation-before-native-liquid-glass-v2-20261111/floating_liquid_nav.dart.txt Frontend/mobile/lib/shared/widgets/floating_liquid_nav.dart
cp docs/design-archive/navigation-before-native-liquid-glass-v2-20261111/app.dart.txt Frontend/mobile/lib/app/app.dart
```

New host and bridge files are unused after restoring these two files. Native registration may remain inert, or be restored using its separate native-source archive. Restoring this UI does not clear session, profile, streak, or reward data.
