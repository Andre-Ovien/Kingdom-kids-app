# Navigation before the liquid glass restoration

This preserves the exact solid dark dock and separate profile control before restoring a translucent liquid glass skin. The three destinations (Home, Stories, Games), separate Profile placement, routes, profile identity, and audio behavior are retained by the replacement.

Verify this archive from this folder with `shasum -a 256 -c SHA256SUMS`.

To restore the former navigation appearance, run from the repository root:

```sh
cp docs/design-archive/navigation-before-liquid-glass-20261111/floating_liquid_nav.dart.txt Frontend/mobile/lib/shared/widgets/floating_liquid_nav.dart
```

No app data, saved profiles, sessions, or backend state is changed by restoring this file. The shared `liquid_glass.dart` component is unchanged.
