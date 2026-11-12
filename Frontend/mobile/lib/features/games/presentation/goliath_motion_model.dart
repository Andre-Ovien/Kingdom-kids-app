import 'dart:math' as math;

import 'goliath_blender_fall_track.dart';

/// Source-image coordinates: top-left origin, positive Y down. X remains in
/// image-width units; dynamics and rotations account for the 3:4 image aspect.
class GoliathPoint {
  const GoliathPoint(this.x, this.y);

  final double x;
  final double y;

  GoliathPoint operator +(GoliathPoint other) =>
      GoliathPoint(x + other.x, y + other.y);
  GoliathPoint operator -(GoliathPoint other) =>
      GoliathPoint(x - other.x, y - other.y);
  GoliathPoint operator *(double factor) =>
      GoliathPoint(x * factor, y * factor);

  @override
  bool operator ==(Object other) =>
      other is GoliathPoint && x == other.x && y == other.y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'GoliathPoint($x, $y)';
}

enum GoliathJoint {
  forehead,
  head,
  neck,
  chest,
  lumbar,
  pelvis,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftPalm,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
  leftToe,
  rightToe,
  shield,
}

enum GoliathMotionPhase {
  standing,
  reacting,
  buckling,
  falling,
  settling,
  settled,
}

/// A rigid segment transform in physical image coordinates, suitable for
/// blending several bones when skinning the original illustration's mesh.
class GoliathBoneTransform {
  GoliathBoneTransform({
    required this.restFrom,
    required this.restTo,
    required this.from,
    required this.to,
    required this.aspectRatio,
  });

  final GoliathPoint restFrom;
  final GoliathPoint restTo;
  final GoliathPoint from;
  final GoliathPoint to;
  final double aspectRatio;

  double get rotationRadians =>
      math.atan2(to.y - from.y, (to.x - from.x) * aspectRatio) -
      math.atan2(restTo.y - restFrom.y, (restTo.x - restFrom.x) * aspectRatio);

  double get scale {
    final restLength = _length(restTo - restFrom);
    return restLength < 1e-9 ? 1 : _length(to - from) / restLength;
  }

  double _length(GoliathPoint point) => math.sqrt(
    point.x * point.x * aspectRatio * aspectRatio + point.y * point.y,
  );

  GoliathPoint transformPoint(GoliathPoint source) {
    final dx = (source.x - restFrom.x) * aspectRatio;
    final dy = source.y - restFrom.y;
    final angle = rotationRadians;
    final cosine = math.cos(angle) * scale;
    final sine = math.sin(angle) * scale;
    return GoliathPoint(
      from.x + (dx * cosine - dy * sine) / aspectRatio,
      from.y + dx * sine + dy * cosine,
    );
  }
}

class GoliathPose {
  GoliathPose._({
    required Map<GoliathJoint, GoliathPoint> joints,
    required Map<GoliathJoint, double> groundExtents,
    required Set<GoliathJoint> groundContacts,
    required this.phase,
    required this.elapsedSeconds,
    required this.maximumSpeed,
    required this.isGrounded,
    required this.isSettled,
  }) : joints = Map.unmodifiable(joints),
       groundExtents = Map.unmodifiable(groundExtents),
       groundContacts = Set.unmodifiable(groundContacts);

  final Map<GoliathJoint, GoliathPoint> joints;

  /// Downward floor support from each joint, in physical image-height units.
  /// Rigid armor/head/shield use orientation-aware source outline envelopes.
  final Map<GoliathJoint, double> groundExtents;
  final Set<GoliathJoint> groundContacts;
  final GoliathMotionPhase phase;
  final double elapsedSeconds;
  final double maximumSpeed;
  final bool isGrounded;
  final bool isSettled;

  Map<GoliathJoint, GoliathPoint> get restJoints =>
      GoliathMotionModel.restJoints;
  GoliathPoint operator [](GoliathJoint joint) => joints[joint]!;

  GoliathBoneTransform boneTransform(GoliathJoint from, GoliathJoint to) =>
      GoliathBoneTransform(
        restFrom: restJoints[from]!,
        restTo: restJoints[to]!,
        from: joints[from]!,
        to: joints[to]!,
        aspectRatio: GoliathMotionModel.aspectRatio,
      );
}

/// A controlled fall authored and evaluated in Blender on the exact native
/// artwork rig. Hip, thigh, knee and ankle motion comes from one parented
/// skeleton; viewport and floor corrections translate the complete body.
///
/// Playback has no Flutter, asset, timer or platform dependency. Active frame
/// time advances the fixed-step track; paused intervals add no motion time.
/// Landing completes only after real body support and a quiet settling hold.
class GoliathMotionModel {
  GoliathMotionModel({
    this.minimumX = -.15,
    this.maximumX = 1.25,
    this.idleMotion = true,
  }) {
    if (!minimumX.isFinite || !maximumX.isFinite || maximumX - minimumX < 1.4) {
      throw ArgumentError(
        'The body needs finite horizontal bounds at least 1.4 image widths apart for a bounded articulated landing',
      );
    }
    reset();
  }

  /// Viewport bounds expressed in the original actor's image-width units.
  /// Choose them before impact; contacts keep the fall inside these bounds
  /// continuously, rather than snapping or shrinking a completed pose.
  /// The coupled hip/leg body needs at least 1.4 original-image widths of
  /// space. Size the actor before play; narrow cages are rejected rather than
  /// letting the body stabilize upright or shrink after impact.
  final double minimumX;
  final double maximumX;
  final bool idleMotion;

  static const aspectRatio = .75;
  static const groundY = .9952;
  static const fixedStepSeconds = 1 / 120;
  // Bound foreground hitch work. Background elapsed time must never be
  // supplied as a catch-up delta when the ticker resumes.
  static const maximumFrameSeconds = .25;

  static const Map<GoliathJoint, GoliathPoint> restJoints = {
    GoliathJoint.forehead: GoliathPoint(.451, .115),
    GoliathJoint.head: GoliathPoint(.455, .195),
    GoliathJoint.neck: GoliathPoint(.4788, .2555),
    GoliathJoint.chest: GoliathPoint(.4678, .3522),
    GoliathJoint.lumbar: GoliathPoint(.4586, .4662),
    GoliathJoint.pelvis: GoliathPoint(.4512, .5974),
    GoliathJoint.leftShoulder: GoliathPoint(.3241, .2970),
    GoliathJoint.rightShoulder: GoliathPoint(.6519, .2901),
    GoliathJoint.leftElbow: GoliathPoint(.2210, .4392),
    GoliathJoint.rightElbow: GoliathPoint(.7274, .4006),
    GoliathJoint.leftWrist: GoliathPoint(.1621, .5635),
    GoliathJoint.rightWrist: GoliathPoint(.7413, .5214),
    GoliathJoint.leftPalm: GoliathPoint(.1593, .6160),
    GoliathJoint.leftHip: GoliathPoint(.3628, .6409),
    GoliathJoint.rightHip: GoliathPoint(.5414, .6492),
    GoliathJoint.leftKnee: GoliathPoint(.3315, .7486),
    GoliathJoint.rightKnee: GoliathPoint(.6096, .7528),
    GoliathJoint.leftAnkle: GoliathPoint(.3103, .8909),
    GoliathJoint.rightAnkle: GoliathPoint(.6575, .8992),
    GoliathJoint.leftToe: GoliathPoint(.2753, .9724),
    GoliathJoint.rightToe: GoliathPoint(.6832, .9945),
    GoliathJoint.shield: GoliathPoint(.73204420, .53176796),
  };

  static const Map<GoliathJoint, double> collisionRadii = {
    GoliathJoint.forehead: .025,
    GoliathJoint.head: .140,
    GoliathJoint.neck: .031,
    GoliathJoint.chest: .085,
    GoliathJoint.lumbar: .071,
    GoliathJoint.pelvis: .065,
    GoliathJoint.leftShoulder: .043,
    GoliathJoint.rightShoulder: .043,
    GoliathJoint.leftElbow: .030,
    GoliathJoint.rightElbow: .030,
    GoliathJoint.leftWrist: .025,
    GoliathJoint.rightWrist: .025,
    GoliathJoint.leftPalm: .032,
    GoliathJoint.leftHip: .038,
    GoliathJoint.rightHip: .038,
    GoliathJoint.leftKnee: .033,
    GoliathJoint.rightKnee: .033,
    GoliathJoint.leftAnkle: .025,
    GoliathJoint.rightAnkle: .025,
    GoliathJoint.leftToe: .0228,
    GoliathJoint.rightToe: .0007,
    GoliathJoint.shield: .185,
  };

  /// Simplified original-alpha sandal silhouettes, expressed as source UVs.
  /// Their corners rotate with the foot, so a flat sandal cannot cut through
  /// the floor merely because its ankle/sole center remained above it.
  static const Map<GoliathJoint, List<GoliathPoint>> footOutlines = {
    GoliathJoint.leftAnkle: [
      GoliathPoint(280 / 1086, 1280 / 1448),
      GoliathPoint(424 / 1086, 1280 / 1448),
      GoliathPoint(423 / 1086, 1295 / 1448),
      GoliathPoint(429 / 1086, 1310 / 1448),
      GoliathPoint(433 / 1086, 1325 / 1448),
      GoliathPoint(439 / 1086, 1345 / 1448),
      GoliathPoint(442 / 1086, 1365 / 1448),
      GoliathPoint(376 / 1086, 1385 / 1448),
      GoliathPoint(315 / 1086, 1400 / 1448),
      GoliathPoint(264 / 1086, 1408 / 1448),
      GoliathPoint(222 / 1086, 1408 / 1448),
      GoliathPoint(182 / 1086, 1400 / 1448),
      GoliathPoint(169 / 1086, 1385 / 1448),
      GoliathPoint(173 / 1086, 1365 / 1448),
      GoliathPoint(182 / 1086, 1345 / 1448),
      GoliathPoint(205 / 1086, 1325 / 1448),
      GoliathPoint(230 / 1086, 1310 / 1448),
      GoliathPoint(258 / 1086, 1295 / 1448),
    ],
    GoliathJoint.rightAnkle: [
      GoliathPoint(646 / 1086, 1296 / 1448),
      GoliathPoint(775 / 1086, 1296 / 1448),
      GoliathPoint(782 / 1086, 1310 / 1448),
      GoliathPoint(791 / 1086, 1325 / 1448),
      GoliathPoint(811 / 1086, 1345 / 1448),
      GoliathPoint(829 / 1086, 1365 / 1448),
      GoliathPoint(839 / 1086, 1385 / 1448),
      GoliathPoint(844 / 1086, 1405 / 1448),
      GoliathPoint(839 / 1086, 1420 / 1448),
      GoliathPoint(799 / 1086, 1435 / 1448),
      GoliathPoint(759 / 1086, 1440 / 1448),
      GoliathPoint(719 / 1086, 1440 / 1448),
      GoliathPoint(686 / 1086, 1435 / 1448),
      GoliathPoint(661 / 1086, 1420 / 1448),
      GoliathPoint(654 / 1086, 1405 / 1448),
      GoliathPoint(641 / 1086, 1385 / 1448),
      GoliathPoint(641 / 1086, 1365 / 1448),
      GoliathPoint(645 / 1086, 1345 / 1448),
      GoliathPoint(649 / 1086, 1325 / 1448),
      GoliathPoint(653 / 1086, 1310 / 1448),
    ],
  };

  static const List<GoliathPoint> headOutline = [
    GoliathPoint(497 / 1086, 6 / 1448),
    GoliathPoint(532 / 1086, 13 / 1448),
    GoliathPoint(564 / 1086, 39 / 1448),
    GoliathPoint(596 / 1086, 124 / 1448),
    GoliathPoint(599 / 1086, 185 / 1448),
    GoliathPoint(615 / 1086, 225 / 1448),
    GoliathPoint(629 / 1086, 259 / 1448),
    GoliathPoint(657 / 1086, 286 / 1448),
    GoliathPoint(660 / 1086, 315 / 1448),
    GoliathPoint(619 / 1086, 326 / 1448),
    GoliathPoint(596 / 1086, 331 / 1448),
    GoliathPoint(578 / 1086, 377 / 1448),
    GoliathPoint(550 / 1086, 401 / 1448),
    GoliathPoint(495 / 1086, 416 / 1448),
    GoliathPoint(428 / 1086, 408 / 1448),
    GoliathPoint(393 / 1086, 378 / 1448),
    GoliathPoint(378 / 1086, 343 / 1448),
    GoliathPoint(354 / 1086, 322 / 1448),
    GoliathPoint(359 / 1086, 295 / 1448),
    GoliathPoint(378 / 1086, 261 / 1448),
    GoliathPoint(394 / 1086, 222 / 1448),
    GoliathPoint(420 / 1086, 202 / 1448),
    GoliathPoint(414 / 1086, 151 / 1448),
    GoliathPoint(442 / 1086, 80 / 1448),
    GoliathPoint(433 / 1086, 36 / 1448),
  ];

  /// This includes the same four-source-pixel rim allowance as the mesh.
  static const List<GoliathPoint> shieldOutline = [
    GoliathPoint(.73204420, .34185083),
    GoliathPoint(.80684393, .35855982),
    GoliathPoint(.86219674, .39693367),
    GoliathPoint(.89432166, .44312506),
    GoliathPoint(.91142226, .48809738),
    GoliathPoint(.91804788, .53176796),
    GoliathPoint(.91510707, .57612550),
    GoliathPoint(.89893082, .62247740),
    GoliathPoint(.86404392, .66798043),
    GoliathPoint(.80777338, .70566459),
    GoliathPoint(.73204420, .71823204),
    GoliathPoint(.65816142, .70221272),
    GoliathPoint(.60280786, .66521852),
    GoliathPoint(.56792142, .62109764),
    GoliathPoint(.54806407, .57682431),
    GoliathPoint(.54235727, .53176796),
    GoliathPoint(.54806407, .48671160),
    GoliathPoint(.56423894, .44036565),
    GoliathPoint(.59912819, .39417180),
    GoliathPoint(.65631502, .35787132),
  ];

  static const List<GoliathPoint> apronOutline = [
    GoliathPoint(323 / 1086, 646 / 1448),
    GoliathPoint(385 / 1086, 629 / 1448),
    GoliathPoint(451 / 1086, 625 / 1448),
    GoliathPoint(583 / 1086, 637 / 1448),
    GoliathPoint(653 / 1086, 648 / 1448),
    GoliathPoint(663 / 1086, 674 / 1448),
    GoliathPoint(662 / 1086, 695 / 1448),
    GoliathPoint(668 / 1086, 724 / 1448),
    GoliathPoint(704 / 1086, 816 / 1448),
    GoliathPoint(742 / 1086, 913 / 1448),
    GoliathPoint(747 / 1086, 931 / 1448),
    GoliathPoint(736 / 1086, 949 / 1448),
    GoliathPoint(712 / 1086, 960 / 1448),
    GoliathPoint(707 / 1086, 980 / 1448),
    GoliathPoint(695 / 1086, 982 / 1448),
    GoliathPoint(693 / 1086, 951 / 1448),
    GoliathPoint(650 / 1086, 964 / 1448),
    GoliathPoint(548 / 1086, 979 / 1448),
    GoliathPoint(559 / 1086, 1016 / 1448),
    GoliathPoint(451 / 1086, 1017 / 1448),
    GoliathPoint(462 / 1086, 981 / 1448),
    GoliathPoint(379 / 1086, 971 / 1448),
    GoliathPoint(310 / 1086, 957 / 1448),
    GoliathPoint(314 / 1086, 983 / 1448),
    GoliathPoint(290 / 1086, 991 / 1448),
    GoliathPoint(285 / 1086, 977 / 1448),
    GoliathPoint(251 / 1086, 958 / 1448),
    GoliathPoint(240 / 1086, 940 / 1448),
    GoliathPoint(242 / 1086, 923 / 1448),
    GoliathPoint(274 / 1086, 819 / 1448),
    GoliathPoint(309 / 1086, 720 / 1448),
    GoliathPoint(315 / 1086, 697 / 1448),
    GoliathPoint(316 / 1086, 670 / 1448),
  ];

  static const List<GoliathPoint> palmOutline = [
    GoliathPoint(143 / 1086, 800 / 1448),
    GoliathPoint(174 / 1086, 797 / 1448),
    GoliathPoint(193 / 1086, 810 / 1448),
    GoliathPoint(211 / 1086, 833 / 1448),
    GoliathPoint(231 / 1086, 878 / 1448),
    GoliathPoint(239 / 1086, 909 / 1448),
    GoliathPoint(229 / 1086, 923 / 1448),
    GoliathPoint(211 / 1086, 921 / 1448),
    GoliathPoint(198 / 1086, 908 / 1448),
    GoliathPoint(185 / 1086, 880 / 1448),
    GoliathPoint(177 / 1086, 898 / 1448),
    GoliathPoint(183 / 1086, 927 / 1448),
    GoliathPoint(209 / 1086, 951 / 1448),
    GoliathPoint(213 / 1086, 964 / 1448),
    GoliathPoint(202 / 1086, 975 / 1448),
    GoliathPoint(185 / 1086, 973 / 1448),
    GoliathPoint(154 / 1086, 959 / 1448),
    GoliathPoint(128 / 1086, 939 / 1448),
    GoliathPoint(115 / 1086, 917 / 1448),
    GoliathPoint(113 / 1086, 895 / 1448),
    GoliathPoint(119 / 1086, 854 / 1448),
    GoliathPoint(132 / 1086, 818 / 1448),
  ];

  static const List<GoliathPoint> chestOutline = [
    GoliathPoint(294 / 1086, 380 / 1448),
    GoliathPoint(339 / 1086, 354 / 1448),
    GoliathPoint(382 / 1086, 343 / 1448),
    GoliathPoint(374 / 1086, 373 / 1448),
    GoliathPoint(369 / 1086, 409 / 1448),
    GoliathPoint(366 / 1086, 440 / 1448),
    GoliathPoint(357 / 1086, 455 / 1448),
    GoliathPoint(305 / 1086, 469 / 1448),
    GoliathPoint(292 / 1086, 465 / 1448),
    GoliathPoint(286 / 1086, 448 / 1448),
    GoliathPoint(285 / 1086, 409 / 1448),
    GoliathPoint(568 / 1086, 414 / 1448),
    GoliathPoint(586 / 1086, 368 / 1448),
    GoliathPoint(615 / 1086, 333 / 1448),
    GoliathPoint(653 / 1086, 315 / 1448),
    GoliathPoint(682 / 1086, 319 / 1448),
    GoliathPoint(716 / 1086, 327 / 1448),
    GoliathPoint(749 / 1086, 339 / 1448),
    GoliathPoint(756 / 1086, 351 / 1448),
    GoliathPoint(755 / 1086, 362 / 1448),
    GoliathPoint(735 / 1086, 367 / 1448),
    GoliathPoint(710 / 1086, 390 / 1448),
    GoliathPoint(681 / 1086, 432 / 1448),
    GoliathPoint(658 / 1086, 451 / 1448),
    GoliathPoint(575 / 1086, 444 / 1448),
    GoliathPoint(557 / 1086, 437 / 1448),
    GoliathPoint(332 / 1086, 415 / 1448),
    GoliathPoint(649 / 1086, 415 / 1448),
    GoliathPoint(649 / 1086, 654 / 1448),
    GoliathPoint(332 / 1086, 654 / 1448),
    // Opaque blue sleeves belonging to the same chest island. These native
    // mesh extrema extend beyond the metallic shoulder-pad contours.
    GoliathPoint(828.08 / 1086, 448.88 / 1448),
    GoliathPoint(826.18 / 1086, 455.96 / 1448),
    GoliathPoint(821.82 / 1086, 472.28 / 1448),
    GoliathPoint(821.06 / 1086, 475.11 / 1448),
    GoliathPoint(819.93 / 1086, 470.60 / 1448),
    GoliathPoint(823.87 / 1086, 438.02 / 1448),
    GoliathPoint(814.50 / 1086, 448.88 / 1448),
    GoliathPoint(811.55 / 1086, 433.50 / 1448),
    GoliathPoint(238.92 / 1086, 470.60 / 1448),
    GoliathPoint(252.66 / 1086, 452.89 / 1448),
  ];

  /// Exact source gold-guard contours in the renderer's knee→ankle frames.
  /// Full side rims must support the floor as the articulated shins rotate.
  static const List<GoliathPoint> leftShinOutline = [
    GoliathPoint(317 / 1086, 1012 / 1448),
    GoliathPoint(343 / 1086, 1014 / 1448),
    GoliathPoint(367 / 1086, 1026 / 1448),
    GoliathPoint(385 / 1086, 1050 / 1448),
    GoliathPoint(396 / 1086, 1081 / 1448),
    GoliathPoint(398 / 1086, 1110 / 1448),
    GoliathPoint(391 / 1086, 1152 / 1448),
    GoliathPoint(382 / 1086, 1191 / 1448),
    GoliathPoint(374 / 1086, 1230 / 1448),
    GoliathPoint(372 / 1086, 1263 / 1448),
    GoliathPoint(361 / 1086, 1273 / 1448),
    GoliathPoint(338 / 1086, 1267 / 1448),
    GoliathPoint(309 / 1086, 1263 / 1448),
    GoliathPoint(293 / 1086, 1270 / 1448),
    GoliathPoint(289 / 1086, 1255 / 1448),
    GoliathPoint(295 / 1086, 1235 / 1448),
    GoliathPoint(291 / 1086, 1195 / 1448),
    GoliathPoint(287 / 1086, 1150 / 1448),
    GoliathPoint(282 / 1086, 1111 / 1448),
    GoliathPoint(284 / 1086, 1070 / 1448),
    GoliathPoint(293 / 1086, 1041 / 1448),
    GoliathPoint(304 / 1086, 1021 / 1448),
  ];

  static const List<GoliathPoint> rightShinOutline = [
    GoliathPoint(633 / 1086, 1018 / 1448),
    GoliathPoint(659 / 1086, 1021 / 1448),
    GoliathPoint(683 / 1086, 1036 / 1448),
    GoliathPoint(705 / 1086, 1059 / 1448),
    GoliathPoint(718 / 1086, 1091 / 1448),
    GoliathPoint(723 / 1086, 1125 / 1448),
    GoliathPoint(727 / 1086, 1165 / 1448),
    GoliathPoint(734 / 1086, 1205 / 1448),
    GoliathPoint(737 / 1086, 1231 / 1448),
    GoliathPoint(736 / 1086, 1248 / 1448),
    GoliathPoint(737 / 1086, 1256 / 1448),
    GoliathPoint(734 / 1086, 1264 / 1448),
    GoliathPoint(723 / 1086, 1263 / 1448),
    GoliathPoint(705 / 1086, 1263 / 1448),
    GoliathPoint(686 / 1086, 1270 / 1448),
    GoliathPoint(673 / 1086, 1278 / 1448),
    GoliathPoint(665 / 1086, 1284 / 1448),
    GoliathPoint(660 / 1086, 1281 / 1448),
    GoliathPoint(657 / 1086, 1274 / 1448),
    GoliathPoint(657 / 1086, 1261 / 1448),
    GoliathPoint(650 / 1086, 1250 / 1448),
    GoliathPoint(642 / 1086, 1228 / 1448),
    GoliathPoint(626 / 1086, 1191 / 1448),
    GoliathPoint(607 / 1086, 1151 / 1448),
    GoliathPoint(599 / 1086, 1111 / 1448),
    GoliathPoint(600 / 1086, 1071 / 1448),
    GoliathPoint(611 / 1086, 1041 / 1448),
    GoliathPoint(622 / 1086, 1026 / 1448),
  ];

  /// Source gold bracer/leather silhouette, including opaque rim pixels
  /// between mesh vertices, in the renderer's left-forearm rigid frame.
  static const List<GoliathPoint> leftForearmOutline = [
    GoliathPoint(160 / 1086, 636 / 1448),
    GoliathPoint(175 / 1086, 630 / 1448),
    GoliathPoint(200 / 1086, 633 / 1448),
    GoliathPoint(229 / 1086, 644 / 1448),
    GoliathPoint(244 / 1086, 659 / 1448),
    GoliathPoint(247 / 1086, 670 / 1448),
    GoliathPoint(276 / 1086, 684 / 1448),
    GoliathPoint(292 / 1086, 698 / 1448),
    GoliathPoint(286 / 1086, 720 / 1448),
    GoliathPoint(269 / 1086, 739 / 1448),
    GoliathPoint(262 / 1086, 750 / 1448),
    GoliathPoint(271 / 1086, 766 / 1448),
    GoliathPoint(264 / 1086, 789 / 1448),
    GoliathPoint(242 / 1086, 811 / 1448),
    GoliathPoint(215 / 1086, 821 / 1448),
    GoliathPoint(194 / 1086, 806 / 1448),
    GoliathPoint(169 / 1086, 799 / 1448),
    GoliathPoint(144 / 1086, 804 / 1448),
    GoliathPoint(129 / 1086, 818 / 1448),
    GoliathPoint(121 / 1086, 806 / 1448),
    GoliathPoint(123 / 1086, 787 / 1448),
    GoliathPoint(134 / 1086, 770 / 1448),
    GoliathPoint(144 / 1086, 724 / 1448),
    GoliathPoint(151 / 1086, 681 / 1448),
  ];

  final List<_Particle> _particles = [];
  final Set<GoliathJoint> _contacts = {};
  final Map<GoliathJoint, GoliathPoint> _impactOffsets = {};
  late GoliathPose _pose;
  bool _paused = false;
  bool _struck = false;
  bool _settled = false;
  bool _grounded = false;
  double _elapsed = 0;
  double _accumulator = 0;
  double _quietSeconds = 0;
  double _direction = 1;
  double _idleSeconds = 0;
  double _trackSpeed = 1;

  GoliathPose get pose => _pose;
  bool get isPaused => _paused;
  bool get isSettled => _settled;

  void setPaused(bool paused) {
    _paused = paused;
  }

  void reset() {
    _paused = _struck = _settled = _grounded = false;
    _elapsed = _accumulator = _quietSeconds = _idleSeconds = 0;
    _direction = _trackSpeed = 1;
    _particles.clear();
    _contacts.clear();
    _impactOffsets.clear();
    for (final joint in GoliathJoint.values) {
      final rest = restJoints[joint]!;
      _particles.add(_Particle(rest.x * aspectRatio, rest.y));
    }
    _capturePose();
  }

  /// A glancing head impact starts one collapse. Repeated calls cannot reset
  /// a fall or bypass its contact/settling checks. Direction is left/right in
  /// the front-facing image plane; strength is bounded for predictable play.
  /// If the requested side has too little viewport room, the body falls into
  /// the open side, as the game host normally selects before calling this.
  void strikeHead({double direction = 1, double strength = 1}) {
    if (!direction.isFinite || !strength.isFinite) {
      throw ArgumentError('Impact values must be finite');
    }
    if (_struck || _paused) return;
    // Fade the displayed breathing offsets into the authored reaction over
    // 120 ms, so a strike begins at the exact last visible pose.
    for (final joint in GoliathJoint.values) {
      final point = _pose[joint];
      _impactOffsets[joint] = point - restJoints[joint]!;
      _node(joint).x = point.x * aspectRatio;
      _node(joint).y = point.y;
    }
    _accumulator = 0;
    _struck = true;
    _direction = direction < 0 ? -1 : 1;
    final rootX = restJoints[GoliathJoint.pelvis]!.x;
    final preferredRoom = _direction > 0 ? maximumX - rootX : rootX - minimumX;
    final oppositeRoom = _direction > 0 ? rootX - minimumX : maximumX - rootX;
    if (preferredRoom < .65 && preferredRoom < oppositeRoom * .55) {
      _direction = -_direction;
    }
    _trackSpeed = .9 + .1 * strength.clamp(.6, 1.4);
    _capturePose();
  }

  GoliathPose advance(double deltaSeconds) {
    if (!deltaSeconds.isFinite || deltaSeconds < 0) {
      throw ArgumentError.value(
        deltaSeconds,
        'deltaSeconds',
        'Must be finite and nonnegative',
      );
    }
    if (_paused || _settled || deltaSeconds == 0) return _pose;
    if (!_struck) {
      if (!idleMotion) return _pose;
      _idleSeconds += math.min(deltaSeconds, maximumFrameSeconds);
      return _captureIdlePose();
    }
    _accumulator += math.min(deltaSeconds, maximumFrameSeconds);
    while (_accumulator + 1e-12 >= fixedStepSeconds && !_settled) {
      _stepAuthored(fixedStepSeconds);
      _accumulator -= fixedStepSeconds;
    }
    _capturePose();
    return _pose;
  }

  void _stepAuthored(double dt) {
    _elapsed += dt;
    final before = [for (final p in _particles) GoliathPoint(p.x, p.y)];
    final track = _direction > 0
        ? GoliathBlenderFallTrack.right
        : GoliathBlenderFallTrack.left;
    final trackTime = math.min(
      _elapsed * _trackSpeed,
      GoliathBlenderFallTrack.durationSeconds,
    );
    final frame = trackTime * GoliathBlenderFallTrack.framesPerSecond;
    final index = frame.floor().clamp(0, track.length - 1);
    final next = math.min(index + 1, track.length - 1);
    final fraction = frame - index;
    final idle = 1 - _smooth(_elapsed / .12);
    for (final joint in GoliathJoint.values) {
      final coordinate = joint.index * 2;
      final offset = _impactOffsets[joint]! * idle;
      final a = track[index];
      final b = track[next];
      final p = _node(joint);
      p.x =
          (a[coordinate] +
              (b[coordinate] - a[coordinate]) * fraction +
              offset.x) *
          aspectRatio;
      p.y =
          a[coordinate + 1] +
          (b[coordinate + 1] - a[coordinate + 1]) * fraction +
          offset.y;
    }
    // Correct tiny inter-frame interpolation penetration as one rigid root
    // translation. The authored hips and both complete leg chains stay intact.
    var penetration = 0.0;
    for (final joint in GoliathJoint.values) {
      penetration = math.max(
        penetration,
        _node(joint).y + _groundExtent(joint) - groundY,
      );
    }
    if (penetration > 0) {
      for (final p in _particles) {
        p.y -= penetration;
      }
    }
    _fitWholeBodyHorizontally();
    _contacts.clear();
    var maximumSpeed = 0.0;
    var squareSpeed = 0.0;
    for (final joint in GoliathJoint.values) {
      final p = _node(joint);
      p.vx = (p.x - before[joint.index].x) / dt;
      p.vy = (p.y - before[joint.index].y) / dt;
      final square = p.vx * p.vx + p.vy * p.vy;
      squareSpeed += square;
      maximumSpeed = math.max(maximumSpeed, math.sqrt(square));
      if (p.y + _groundExtent(joint) >= groundY - .0015) {
        _contacts.add(joint);
      }
    }
    final bodySupport = _contacts.any(
      (joint) => const {
        GoliathJoint.head,
        GoliathJoint.chest,
        GoliathJoint.pelvis,
        GoliathJoint.leftShoulder,
        GoliathJoint.rightShoulder,
        GoliathJoint.leftHip,
        GoliathJoint.rightHip,
        GoliathJoint.leftElbow,
        GoliathJoint.leftPalm,
        GoliathJoint.shield,
      }.contains(joint),
    );
    _grounded =
        bodySupport &&
        _boneRotation(
              GoliathJoint.leftShoulder,
              GoliathJoint.rightShoulder,
            ).abs() >
            1.10;
    final rmsSpeed = math.sqrt(squareSpeed / _particles.length);
    if (_grounded && rmsSpeed < .05 && maximumSpeed < .20 && _elapsed > 1.9) {
      _quietSeconds += dt;
      if (_quietSeconds >= .30 &&
          trackTime >= GoliathBlenderFallTrack.settledAtSeconds) {
        _settled = true;
        for (final p in _particles) {
          p.vx = p.vy = 0;
        }
      }
    } else {
      _quietSeconds = 0;
    }
  }

  void _fitWholeBodyHorizontally() {
    var left = double.infinity;
    var right = -double.infinity;
    void include(double x) {
      left = math.min(left, x);
      right = math.max(right, x);
    }

    for (final joint in GoliathJoint.values) {
      final p = _node(joint);
      final radius = collisionRadii[joint]!;
      include(p.x - radius);
      include(p.x + radius);
    }
    for (final surface in [
      (GoliathJoint.neck, GoliathJoint.head, headOutline),
      (GoliathJoint.leftShoulder, GoliathJoint.rightShoulder, chestOutline),
      (GoliathJoint.leftHip, GoliathJoint.rightHip, apronOutline),
      (GoliathJoint.rightElbow, GoliathJoint.rightWrist, shieldOutline),
      (GoliathJoint.leftElbow, GoliathJoint.leftWrist, leftForearmOutline),
      (GoliathJoint.leftWrist, GoliathJoint.leftPalm, palmOutline),
      (GoliathJoint.leftKnee, GoliathJoint.leftAnkle, leftShinOutline),
      (GoliathJoint.rightKnee, GoliathJoint.rightAnkle, rightShinOutline),
      (
        GoliathJoint.leftAnkle,
        GoliathJoint.leftToe,
        footOutlines[GoliathJoint.leftAnkle]!,
      ),
      (
        GoliathJoint.rightAnkle,
        GoliathJoint.rightToe,
        footOutlines[GoliathJoint.rightAnkle]!,
      ),
    ]) {
      final from = _node(surface.$1);
      final to = _node(surface.$2);
      final transform = GoliathBoneTransform(
        restFrom: restJoints[surface.$1]!,
        restTo: restJoints[surface.$2]!,
        from: GoliathPoint(from.x / aspectRatio, from.y),
        to: GoliathPoint(to.x / aspectRatio, to.y),
        aspectRatio: aspectRatio,
      );
      for (final point in surface.$3) {
        include(transform.transformPoint(point).x * aspectRatio);
      }
    }
    final low = minimumX * aspectRatio;
    final high = maximumX * aspectRatio;
    final correction = left < low
        ? low - left
        : right > high
        ? high - right
        : 0.0;
    if (correction != 0) {
      for (final p in _particles) {
        p.x += correction;
      }
    }
  }

  double _boneRotation(GoliathJoint from, GoliathJoint to) {
    final a = _node(from);
    final b = _node(to);
    final ra = restJoints[from]!;
    final rb = restJoints[to]!;
    return math.atan2(b.y - a.y, b.x - a.x) -
        math.atan2(rb.y - ra.y, (rb.x - ra.x) * aspectRatio);
  }

  double _groundExtent(GoliathJoint joint) {
    switch (joint) {
      case GoliathJoint.shield:
        return _outlineExtent(
          joint,
          GoliathJoint.rightElbow,
          GoliathJoint.rightWrist,
          shieldOutline,
        );
      case GoliathJoint.pelvis:
        return _outlineExtent(
          joint,
          GoliathJoint.leftHip,
          GoliathJoint.rightHip,
          apronOutline,
        );
      case GoliathJoint.chest:
        return _outlineExtent(
          joint,
          GoliathJoint.leftShoulder,
          GoliathJoint.rightShoulder,
          chestOutline,
        );
      case GoliathJoint.head:
        return _outlineExtent(joint, GoliathJoint.neck, joint, headOutline);
      case GoliathJoint.leftElbow:
        return math.max(
          collisionRadii[joint]!,
          _outlineExtent(
            joint,
            joint,
            GoliathJoint.leftWrist,
            leftForearmOutline,
          ),
        );
      case GoliathJoint.leftKnee:
        return math.max(
          collisionRadii[joint]!,
          _outlineExtent(joint, joint, GoliathJoint.leftAnkle, leftShinOutline),
        );
      case GoliathJoint.rightKnee:
        return math.max(
          collisionRadii[joint]!,
          _outlineExtent(
            joint,
            joint,
            GoliathJoint.rightAnkle,
            rightShinOutline,
          ),
        );
      case GoliathJoint.leftAnkle || GoliathJoint.rightAnkle:
        final toe = joint == GoliathJoint.leftAnkle
            ? GoliathJoint.leftToe
            : GoliathJoint.rightToe;
        return _outlineExtent(joint, joint, toe, footOutlines[joint]!);
      case GoliathJoint.leftPalm:
        return _outlineExtent(
          joint,
          GoliathJoint.leftWrist,
          joint,
          palmOutline,
        );
      default:
        return collisionRadii[joint]!;
    }
  }

  double _outlineExtent(
    GoliathJoint origin,
    GoliathJoint from,
    GoliathJoint to,
    List<GoliathPoint> outline,
  ) {
    final angle = _boneRotation(from, to);
    final a = _node(from);
    final restFrom = restJoints[from]!;
    final restTo = restJoints[to]!;
    final dx = (restTo.x - restFrom.x) * aspectRatio;
    final dy = restTo.y - restFrom.y;
    final restLength = math.sqrt(dx * dx + dy * dy);
    final scale = _distance(a, _node(to)) / restLength;
    final sine = math.sin(angle) * scale;
    final cosine = math.cos(angle) * scale;
    final maximum = outline.fold<double>(
      -double.infinity,
      (height, point) => math.max(
        height,
        a.y +
            (point.x - restFrom.x) * aspectRatio * sine +
            (point.y - restFrom.y) * cosine,
      ),
    );
    return maximum - _node(origin).y;
  }

  GoliathPose _captureIdlePose() {
    final points = Map<GoliathJoint, GoliathPoint>.of(restJoints);
    final phase = _idleSeconds * 2 * math.pi / 3.6;
    final chestAngle = .005 * math.sin(phase);
    final armAngle = .015 * math.sin(phase * .83);
    GoliathPoint rotate(GoliathPoint vector, double angle) => GoliathPoint(
      vector.x * math.cos(angle) - vector.y / aspectRatio * math.sin(angle),
      vector.x * aspectRatio * math.sin(angle) + vector.y * math.cos(angle),
    );
    final neck = restJoints[GoliathJoint.neck]!;
    for (final joint in [
      GoliathJoint.chest,
      GoliathJoint.lumbar,
      GoliathJoint.leftShoulder,
      GoliathJoint.rightShoulder,
    ]) {
      points[joint] = neck + rotate(restJoints[joint]! - neck, chestAngle);
    }
    for (final chain in [
      [
        GoliathJoint.leftShoulder,
        GoliathJoint.leftElbow,
        GoliathJoint.leftWrist,
      ],
      [
        GoliathJoint.rightShoulder,
        GoliathJoint.rightElbow,
        GoliathJoint.rightWrist,
      ],
    ]) {
      final extra = chain[0] == GoliathJoint.leftShoulder ? armAngle : 0.0;
      points[chain[1]] =
          points[chain[0]]! +
          rotate(
            restJoints[chain[1]]! - restJoints[chain[0]]!,
            chestAngle + extra,
          );
      points[chain[2]] =
          points[chain[1]]! +
          rotate(
            restJoints[chain[2]]! - restJoints[chain[1]]!,
            chestAngle + extra * .55,
          );
    }
    points[GoliathJoint.leftPalm] =
        points[GoliathJoint.leftWrist]! +
        rotate(
          restJoints[GoliathJoint.leftPalm]! -
              restJoints[GoliathJoint.leftWrist]!,
          chestAngle + armAngle * .55,
        );
    points[GoliathJoint.shield] =
        points[GoliathJoint.rightWrist]! +
        rotate(
          restJoints[GoliathJoint.shield]! -
              restJoints[GoliathJoint.rightWrist]!,
          chestAngle,
        );
    _pose = GoliathPose._(
      joints: points,
      groundExtents: _pose.groundExtents,
      groundContacts: {GoliathJoint.leftToe, GoliathJoint.rightToe},
      phase: GoliathMotionPhase.standing,
      elapsedSeconds: 0,
      maximumSpeed: 0,
      isGrounded: false,
      isSettled: false,
    );
    return _pose;
  }

  static double _smooth(double value) {
    final t = value.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  void _capturePose() {
    final maximumSpeed = _particles.fold<double>(
      0,
      (speed, p) => math.max(speed, math.sqrt(p.vx * p.vx + p.vy * p.vy)),
    );
    final phase = !_struck
        ? GoliathMotionPhase.standing
        : _settled
        ? GoliathMotionPhase.settled
        : _grounded
        ? GoliathMotionPhase.settling
        : _elapsed < .18
        ? GoliathMotionPhase.reacting
        : _elapsed < .60
        ? GoliathMotionPhase.buckling
        : GoliathMotionPhase.falling;
    _pose = GoliathPose._(
      joints: {
        for (final joint in GoliathJoint.values)
          joint: GoliathPoint(_node(joint).x / aspectRatio, _node(joint).y),
      },
      groundExtents: {
        for (final joint in GoliathJoint.values) joint: _groundExtent(joint),
      },
      groundContacts: _contacts,
      phase: phase,
      elapsedSeconds: _elapsed,
      maximumSpeed: maximumSpeed,
      isGrounded: _grounded,
      isSettled: _settled,
    );
  }

  _Particle _node(GoliathJoint joint) => _particles[joint.index];
  static double _distance(_Particle a, _Particle b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

class _Particle {
  _Particle(this.x, this.y);
  double x;
  double y;
  double vx = 0;
  double vy = 0;
}
