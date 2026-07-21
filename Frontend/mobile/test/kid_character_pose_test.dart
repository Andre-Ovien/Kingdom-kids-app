import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/presentation/kid_character_pose.dart';
import 'package:mobile/features/auth/presentation/kid_profile_avatar.dart';

void main() {
  group('kidCharacterPoseAssetFor', () {
    test('maps the immediate Kai, Nia, and Zuri poses', () {
      expect(
        kidCharacterPoseAssetFor('lion', KidCharacterPose.wave),
        'assets/images/mascot/mascot_wave.png',
      );
      expect(
        kidCharacterPoseAssetFor('lion', KidCharacterPose.celebrate),
        'assets/images/mascot/mascot_badge.png',
      );
      expect(
        kidCharacterPoseAssetFor('dove', KidCharacterPose.standing),
        'assets/images/characters/poses/nia-standing.png',
      );
      expect(
        kidCharacterPoseAssetFor('dove', KidCharacterPose.wave),
        'assets/images/characters/poses/nia-wave.png',
      );
      expect(
        kidCharacterPoseAssetFor('dove', KidCharacterPose.celebrate),
        'assets/images/characters/poses/nia-medal.png',
      );
      expect(
        kidCharacterPoseAssetFor('rainbow', KidCharacterPose.standing),
        'assets/images/characters/poses/zuri-standing.png',
      );
      expect(
        kidCharacterPoseAssetFor('rainbow', KidCharacterPose.wave),
        'assets/images/characters/poses/zuri-wave.png',
      );
      expect(
        kidCharacterPoseAssetFor('rainbow', KidCharacterPose.celebrate),
        'assets/images/characters/poses/zuri-medal.png',
      );
    });

    test('maps additional exported pose artwork', () {
      expect(
        kidCharacterPoseAssetFor('lion', KidCharacterPose.jump),
        'assets/images/mascot/mascot_jump.png',
      );
      expect(
        kidCharacterPoseAssetFor('dove', KidCharacterPose.read),
        'assets/images/characters/poses/nia-reading.png',
      );
      expect(
        kidCharacterPoseAssetFor('dove', KidCharacterPose.clap),
        'assets/images/characters/poses/nia-clap.png',
      );
      expect(
        kidCharacterPoseAssetFor('rainbow', KidCharacterPose.jump),
        'assets/images/characters/poses/zuri-jump.png',
      );
      expect(
        kidCharacterPoseAssetFor('rainbow', KidCharacterPose.read),
        'assets/images/characters/poses/zuri-reading.png',
      );
      expect(
        kidCharacterPoseAssetFor('rainbow', KidCharacterPose.clap),
        'assets/images/characters/poses/zuri-clap.png',
      );
    });

    test('keeps redesigned star celebrations separate from medal poses', () {
      expect(
        kidCharacterPoseAssetFor('dove', KidCharacterPose.starCelebrate),
        'assets/images/characters/poses/nia-star-celebrate-v2.png',
      );
      expect(
        kidCharacterPoseAssetFor('rainbow', KidCharacterPose.starCelebrate),
        'assets/images/characters/poses/zuri-star-celebrate-v2.png',
      );
    });

    test('normalizes backend keys and leaves missing poses unresolved', () {
      expect(
        kidCharacterPoseAssetFor(' DOVE ', KidCharacterPose.wave),
        'assets/images/characters/poses/nia-wave.png',
      );
      expect(kidCharacterPoseAssetFor('lion', KidCharacterPose.read), isNull);
      expect(
        kidCharacterPoseAssetFor('lion', KidCharacterPose.starCelebrate),
        isNull,
      );
      expect(kidCharacterPoseAssetFor('star', KidCharacterPose.wave), isNull);
    });
  });

  testWidgets('renders the resolved pose asset', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: KidCharacterPoseImage(
          avatarKey: 'dove',
          pose: KidCharacterPose.wave,
          width: 120,
          height: 180,
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as AssetImage;
    expect(provider.assetName, 'assets/images/characters/poses/nia-wave.png');
    expect(image.width, 120);
    expect(image.height, 180);
  });

  testWidgets('uses Kai compact avatar when Kai pose artwork is missing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: KidCharacterPoseImage(
          avatarKey: 'lion',
          pose: KidCharacterPose.read,
          width: 180,
          height: 220,
        ),
      ),
    );

    final badge = tester.widget<KidAvatarBadge>(find.byType(KidAvatarBadge));
    expect(badge.avatarKey, 'lion');
    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/characters/kai-avatar.png',
    );
  });

  testWidgets('uses compact badge fallback for a legacy avatar key', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: KidCharacterPoseImage(
          avatarKey: 'star',
          pose: KidCharacterPose.wave,
          width: 180,
          height: 220,
        ),
      ),
    );

    final badge = tester.widget<KidAvatarBadge>(find.byType(KidAvatarBadge));
    expect(badge.avatarKey, 'star');
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
  });

  testWidgets('profile wrapper resolves from the backend avatar key', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: KidProfileCharacterPose(
          profile: KidProfile(
            id: 'kid-1',
            parentId: 'parent-1',
            displayName: 'Ada',
            avatarKey: 'rainbow',
          ),
          pose: KidCharacterPose.clap,
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/characters/poses/zuri-clap.png',
    );
  });
}
