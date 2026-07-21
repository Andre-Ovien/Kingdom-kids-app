import 'package:flutter/material.dart';

import '../domain/kid_profile.dart';

class KidAvatarOption {
  const KidAvatarOption({
    required this.key,
    required this.label,
    required this.tagline,
    required this.icon,
    required this.color,
    this.assetPath,
  });

  final String key;
  final String label;
  final String tagline;
  final IconData icon;
  final Color color;
  final String? assetPath;

  bool get isCharacter => assetPath != null;
}

const kidAvatarOptions = [
  KidAvatarOption(
    key: 'lion',
    label: 'Kai',
    tagline: 'Brave & curious',
    icon: Icons.pets_rounded,
    color: Color(0xFF46A994),
    assetPath: 'assets/images/characters/kai-avatar.png',
  ),
  KidAvatarOption(
    key: 'dove',
    label: 'Nia',
    tagline: 'Kind & creative',
    icon: Icons.flutter_dash_rounded,
    color: Color(0xFF9870C7),
    assetPath: 'assets/images/characters/nia-avatar.png',
  ),
  KidAvatarOption(
    key: 'rainbow',
    label: 'Zuri',
    tagline: 'Bright & joyful',
    icon: Icons.brightness_7_rounded,
    color: Color(0xFFE77772),
    assetPath: 'assets/images/characters/zuri-avatar.png',
  ),
  // Keep the original badge values available so profiles created by older
  // builds continue to render safely.
  KidAvatarOption(
    key: 'star',
    label: 'Star',
    tagline: 'Shines brightly',
    icon: Icons.star_rounded,
    color: Color(0xFFF4C430),
  ),
  KidAvatarOption(
    key: 'crown',
    label: 'Crown',
    tagline: 'Leads kindly',
    icon: Icons.workspace_premium_rounded,
    color: Color(0xFF9A78D7),
  ),
  KidAvatarOption(
    key: 'sheep',
    label: 'Sheep',
    tagline: 'Gentle friend',
    icon: Icons.cloud_rounded,
    color: Color(0xFF63AD9C),
  ),
];

final kidProfileCharacterOptions = kidAvatarOptions
    .where((option) => option.isCharacter)
    .toList(growable: false);

KidAvatarOption kidAvatarOptionFor(String avatarKey) {
  return kidAvatarOptions.firstWhere(
    (item) => item.key == avatarKey,
    orElse: () => kidAvatarOptions.first,
  );
}

class KidProfileAvatar extends StatelessWidget {
  const KidProfileAvatar({super.key, required this.profile, this.size = 64});

  final KidProfile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    return KidAvatarBadge(avatarKey: profile.avatarKey, size: size);
  }
}

class KidAvatarBadge extends StatelessWidget {
  const KidAvatarBadge({super.key, required this.avatarKey, this.size = 64});

  final String avatarKey;
  final double size;

  @override
  Widget build(BuildContext context) {
    final option = kidAvatarOptionFor(avatarKey);
    final imagePath = option.assetPath;

    return Semantics(
      image: true,
      label: '${option.label} character avatar',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: option.color.withValues(alpha: 0.2),
          shape: BoxShape.circle,
          border: Border.all(
            color: option.color.withValues(alpha: 0.48),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: option.color.withValues(alpha: 0.18),
              blurRadius: size * 0.18,
              offset: Offset(0, size * 0.07),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: imagePath == null
            ? Icon(option.icon, color: option.color, size: size * 0.48)
            : Image.asset(
                imagePath,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
              ),
      ),
    );
  }
}
