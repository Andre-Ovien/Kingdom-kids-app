import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/kid_profile.dart';
import 'kid_profile_avatar.dart';

/// The character artwork variants currently available to child-facing screens.
enum KidCharacterPose {
  standing,
  wave,
  celebrate,
  starCelebrate,
  jump,
  read,
  clap,
}

const _poseAssets = <String, Map<KidCharacterPose, String>>{
  'lion': {
    KidCharacterPose.wave: 'assets/images/mascot/mascot_wave.png',
    KidCharacterPose.celebrate: 'assets/images/mascot/mascot_badge.png',
    KidCharacterPose.jump: 'assets/images/mascot/mascot_jump.png',
  },
  'dove': {
    KidCharacterPose.standing:
        'assets/images/characters/poses/nia-standing.png',
    KidCharacterPose.wave: 'assets/images/characters/poses/nia-wave.png',
    KidCharacterPose.celebrate: 'assets/images/characters/poses/nia-medal.png',
    KidCharacterPose.starCelebrate:
        'assets/images/characters/poses/nia-star-celebrate-v2.png',
    KidCharacterPose.jump: 'assets/images/characters/poses/nia-jump.png',
    KidCharacterPose.read: 'assets/images/characters/poses/nia-reading.png',
    KidCharacterPose.clap: 'assets/images/characters/poses/nia-clap.png',
  },
  'rainbow': {
    KidCharacterPose.standing:
        'assets/images/characters/poses/zuri-standing.png',
    KidCharacterPose.wave: 'assets/images/characters/poses/zuri-wave.png',
    KidCharacterPose.celebrate: 'assets/images/characters/poses/zuri-medal.png',
    KidCharacterPose.starCelebrate:
        'assets/images/characters/poses/zuri-star-celebrate-v2.png',
    KidCharacterPose.jump: 'assets/images/characters/poses/zuri-jump.png',
    KidCharacterPose.read: 'assets/images/characters/poses/zuri-reading.png',
    KidCharacterPose.clap: 'assets/images/characters/poses/zuri-clap.png',
  },
};

/// Resolves a backend avatar key and pose to real character artwork.
///
/// A null result means that exact character/pose combination has no exported
/// artwork. Callers should retain the same avatar rather than borrowing a pose
/// from another character. [KidCharacterPoseImage] handles that fallback.
String? kidCharacterPoseAssetFor(String avatarKey, KidCharacterPose pose) {
  return _poseAssets[avatarKey.trim().toLowerCase()]?[pose];
}

/// Displays full character artwork when it exists, with a compact avatar as a
/// safe fallback for missing poses and profiles created with legacy keys.
class KidCharacterPoseImage extends StatelessWidget {
  const KidCharacterPoseImage({
    required this.avatarKey,
    required this.pose,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.semanticLabel,
    this.fallbackSize,
    super.key,
  });

  final String avatarKey;
  final KidCharacterPose pose;
  final double? width;
  final double? height;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final String? semanticLabel;

  /// Diameter of the compact avatar shown when pose artwork is unavailable.
  /// Defaults to the available space, capped at 96 logical pixels.
  final double? fallbackSize;

  @override
  Widget build(BuildContext context) {
    final normalizedAvatarKey = avatarKey.trim().toLowerCase();
    final assetPath = kidCharacterPoseAssetFor(normalizedAvatarKey, pose);
    if (assetPath == null) {
      return _AvatarFallback(
        avatarKey: normalizedAvatarKey,
        width: width,
        height: height,
        size: fallbackSize,
      );
    }

    final option = kidAvatarOptionFor(normalizedAvatarKey);
    return Semantics(
      image: true,
      label: semanticLabel ?? '${option.label} ${pose._semanticAction}',
      child: Image.asset(
        assetPath,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        excludeFromSemantics: true,
      ),
    );
  }
}

/// Convenience wrapper for screens that already have the active profile.
class KidProfileCharacterPose extends StatelessWidget {
  const KidProfileCharacterPose({
    required this.profile,
    required this.pose,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.semanticLabel,
    this.fallbackSize,
    super.key,
  });

  final KidProfile profile;
  final KidCharacterPose pose;
  final double? width;
  final double? height;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final String? semanticLabel;
  final double? fallbackSize;

  @override
  Widget build(BuildContext context) {
    return KidCharacterPoseImage(
      avatarKey: profile.avatarKey,
      pose: pose,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      semanticLabel: semanticLabel,
      fallbackSize: fallbackSize,
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({
    required this.avatarKey,
    required this.width,
    required this.height,
    required this.size,
  });

  final String avatarKey;
  final double? width;
  final double? height;
  final double? size;

  @override
  Widget build(BuildContext context) {
    var resolvedSize = size ?? 96.0;
    if (width != null && width!.isFinite) {
      resolvedSize = math.min(resolvedSize, width!);
    }
    if (height != null && height!.isFinite) {
      resolvedSize = math.min(resolvedSize, height!);
    }

    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: KidAvatarBadge(avatarKey: avatarKey, size: resolvedSize),
      ),
    );
  }
}

extension on KidCharacterPose {
  String get _semanticAction => switch (this) {
    KidCharacterPose.standing => 'standing',
    KidCharacterPose.wave => 'waving',
    KidCharacterPose.celebrate => 'celebrating',
    KidCharacterPose.starCelebrate => 'celebrating with a star',
    KidCharacterPose.jump => 'jumping',
    KidCharacterPose.read => 'reading',
    KidCharacterPose.clap => 'clapping',
  };
}
