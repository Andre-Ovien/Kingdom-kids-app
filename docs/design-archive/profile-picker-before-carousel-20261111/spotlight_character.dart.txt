import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'kid_character_pose.dart';
import 'kid_profile_avatar.dart';

/// Presents the original, intact character illustration on the spotlight stage.
/// Selection moves the whole artwork closer without deforming its body or face.
class SpotlightCharacter extends StatelessWidget {
  const SpotlightCharacter({
    super.key,
    required this.avatarKey,
    required this.approach,
  });

  final String avatarKey;
  final Animation<double> approach;

  @override
  Widget build(BuildContext context) {
    final option = kidAvatarOptionFor(avatarKey);
    return RepaintBoundary(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = math.min(
              constraints.maxHeight * 0.94,
              constraints.maxWidth * 1.55,
            );
            final width = constraints.maxWidth * 0.9;
            final top = math.max(8.0, (constraints.maxHeight - height) / 2);
            return AnimatedBuilder(
              animation: approach,
              builder: (context, child) {
                final progress = Curves.easeInOutCubic.transform(
                  approach.value,
                );
                return Stack(
                  children: [
                    Positioned(
                      top: top * (1 - progress) + 8 * progress,
                      left: (constraints.maxWidth - width) / 2,
                      width: width,
                      height: height,
                      child: Transform.scale(
                        scale: 1 + progress * 0.65,
                        alignment: Alignment.topCenter,
                        child: child,
                      ),
                    ),
                  ],
                );
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _FootShadowPainter(avatarKey: avatarKey),
                    ),
                  ),
                  KidCharacterPoseImage(
                    avatarKey: avatarKey,
                    pose: KidCharacterPose.wave,
                    semanticLabel: '${option.label}, story buddy',
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FootShadowPainter extends CustomPainter {
  const _FootShadowPainter({required this.avatarKey});

  final String avatarKey;

  @override
  void paint(Canvas canvas, Size size) {
    // Sole bounds measured in the original wave PNGs. Match Image.asset's
    // contain fit, including transparent padding, so shadows touch the shoes.
    final (sourceSize, feet) = switch (avatarKey) {
      'dove' => (
        const Size(1024, 1536),
        const [
          Rect.fromLTRB(363, 1340, 472, 1417),
          Rect.fromLTRB(590, 1340, 684, 1420),
        ],
      ),
      'rainbow' => (
        const Size(1086, 1448),
        const [
          Rect.fromLTRB(395, 1270, 510, 1350),
          Rect.fromLTRB(581, 1270, 708, 1348),
        ],
      ),
      _ => (
        const Size(1024, 1536),
        const [
          Rect.fromLTRB(313, 1277, 485, 1357),
          Rect.fromLTRB(556, 1277, 748, 1354),
        ],
      ),
    };
    final fitted = applyBoxFit(BoxFit.contain, sourceSize, size);
    final imageRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final scale = fitted.destination.width / sourceSize.width;
    final ground = math.max(feet.first.bottom, feet.last.bottom);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          imageRect.left + (feet.first.left + feet.last.right) / 2 * scale,
          imageRect.top + ground * scale + 2,
        ),
        width: (feet.last.right - feet.first.left) * scale * 1.1,
        height: fitted.destination.width * 0.045,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.16)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          fitted.destination.width * 0.012,
        ),
    );
    for (final foot in feet) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(
            imageRect.left + foot.center.dx * scale,
            imageRect.top + foot.bottom * scale + 1,
          ),
          width: foot.width * scale * 1.04,
          height: math.max(2.5, fitted.destination.height * 0.008),
        ),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.max(1, fitted.destination.width * 0.0045),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_FootShadowPainter oldDelegate) =>
      oldDelegate.avatarKey != avatarKey;
}
