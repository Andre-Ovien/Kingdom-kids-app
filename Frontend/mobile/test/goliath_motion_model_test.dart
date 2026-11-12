import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/presentation/goliath_motion_model.dart';

void main() {
  test(
    'initial rest preserves every original landmark and target forehead',
    () {
      final model = GoliathMotionModel();
      expect(model.pose.phase, GoliathMotionPhase.standing);
      expect(model.pose.isGrounded, isFalse);
      expect(model.pose.isSettled, isFalse);
      for (final joint in GoliathJoint.values) {
        _expectPoint(model.pose[joint], GoliathMotionModel.restJoints[joint]!);
      }
      _expectPoint(
        model.pose[GoliathJoint.forehead],
        const GoliathPoint(.451, .115),
      );
    },
  );

  test('idle has subtle joint motion with head, neck and soles anchored', () {
    final model = GoliathMotionModel();
    _advance(model, .75);
    for (final joint in [
      GoliathJoint.forehead,
      GoliathJoint.head,
      GoliathJoint.neck,
      GoliathJoint.leftToe,
      GoliathJoint.rightToe,
    ]) {
      _expectPoint(model.pose[joint], GoliathMotionModel.restJoints[joint]!);
    }
    expect(
      _distance(
        model.pose[GoliathJoint.leftWrist],
        GoliathMotionModel.restJoints[GoliathJoint.leftWrist]!,
      ),
      inExclusiveRange(.001, .012),
    );
    expect(
      _distance(
        model.pose[GoliathJoint.chest],
        GoliathMotionModel.restJoints[GoliathJoint.chest]!,
      ),
      lessThan(.001),
    );
    expect(
      model.pose
          .boneTransform(GoliathJoint.neck, GoliathJoint.head)
          .rotationRadians,
      0,
    );
    expect(model.pose.elapsedSeconds, 0);
    expect(model.pose.phase, GoliathMotionPhase.standing);
  });

  test('reduced motion can retain exact standing art before impact', () {
    final model = GoliathMotionModel(idleMotion: false);
    final pose = model.pose;
    _advance(model, 3);
    expect(identical(model.pose, pose), isTrue);
    model.strikeHead();
    _advance(model, 4);
    expect(model.isSettled, isTrue);
  });

  test('pause freezes idle, impact reaction and remaining fixed-step time', () {
    final model = GoliathMotionModel();
    _advance(model, .2);
    model.setPaused(true);
    final idle = model.pose;
    model.advance(12);
    model.strikeHead();
    expect(identical(model.pose, idle), isTrue);
    model.setPaused(false);
    model.strikeHead();
    _advance(model, .63);
    final moving = model.pose;
    model.setPaused(true);
    model.advance(20);
    expect(identical(model.pose, moving), isTrue);
    model.setPaused(false);
    model.advance(1 / 60);
    expect(
      model.pose.elapsedSeconds - moving.elapsedSeconds,
      closeTo(1 / 60, 1e-9),
    );
    expect(model.isSettled, isFalse);
  });

  test('confirmed head impulse leads torso reaction, then knees buckle', () {
    final model = GoliathMotionModel()..strikeHead();
    _advance(model, .05);
    final headTravel = _distance(
      model.pose[GoliathJoint.head],
      GoliathMotionModel.restJoints[GoliathJoint.head]!,
    );
    final hipTravel = _distance(
      model.pose[GoliathJoint.pelvis],
      GoliathMotionModel.restJoints[GoliathJoint.pelvis]!,
    );
    expect(headTravel, greaterThan(hipTravel * 4));
    expect(model.pose.phase, GoliathMotionPhase.reacting);
    _advance(model, .35);
    expect(model.pose.phase, GoliathMotionPhase.buckling);
    expect(
      _hingeChange(
        model.pose,
        GoliathJoint.leftHip,
        GoliathJoint.leftKnee,
        GoliathJoint.leftAnkle,
      ).abs(),
      greaterThan(.12),
    );
    expect(model.pose.isSettled, isFalse);
  });

  test(
    'head, trunk and limbs articulate while thighs stay in a moderate pelvis range',
    () {
      final model = GoliathMotionModel()..strikeHead();
      _advance(model, .7);
      final head = model.pose
          .boneTransform(GoliathJoint.neck, GoliathJoint.head)
          .rotationRadians;
      final torso = model.pose
          .boneTransform(GoliathJoint.chest, GoliathJoint.neck)
          .rotationRadians;
      final arm = model.pose
          .boneTransform(GoliathJoint.leftShoulder, GoliathJoint.leftElbow)
          .rotationRadians;
      final leg = model.pose
          .boneTransform(GoliathJoint.leftHip, GoliathJoint.leftKnee)
          .rotationRadians;
      expect(
        _wrap(head - torso).abs(),
        inExclusiveRange(.02, .20),
        reason:
            'The controlled neck reaction stays visible without a head whip.',
      );
      expect(_wrap(arm - torso).abs(), greaterThan(.08));
      expect(_wrap(leg - torso).abs(), lessThan(.85));
    },
  );

  test(
    'both upper thighs stay aligned with the pelvis during buckle and touchdown',
    () {
      for (final direction in [-1.0, 1.0]) {
        for (final strength in [.6, 1.0, 1.4]) {
          final model = GoliathMotionModel(idleMotion: false)
            ..strikeHead(direction: direction, strength: strength);
          var sawTorsoFlex = false;
          var sawKneeBend = false;
          for (var frame = 0; frame < 540 && !model.isSettled; frame++) {
            final pose = model.advance(1 / 120);
            final pelvis = pose.boneTransform(
              GoliathJoint.leftHip,
              GoliathJoint.rightHip,
            );
            for (final leg in [
              (
                GoliathJoint.leftHip,
                GoliathJoint.leftKnee,
                GoliathJoint.leftAnkle,
              ),
              (
                GoliathJoint.rightHip,
                GoliathJoint.rightKnee,
                GoliathJoint.rightAnkle,
              ),
            ]) {
              final thigh = pose.boneTransform(leg.$1, leg.$2);
              final relative = _wrap(
                thigh.rotationRadians - pelvis.rotationRadians,
              ).abs();
              expect(
                relative,
                lessThan(.72),
                reason:
                    'broad hip attachment ${leg.$1} direction$direction frame$frame',
              );
              final shin = pose.boneTransform(leg.$2, leg.$3);
              if (_wrap(shin.rotationRadians - thigh.rotationRadians).abs() >
                  .15) {
                sawKneeBend = true;
              }
            }
            final chest = pose.boneTransform(
              GoliathJoint.leftShoulder,
              GoliathJoint.rightShoulder,
            );
            if (_wrap(chest.rotationRadians - pelvis.rotationRadians).abs() >
                .08) {
              sawTorsoFlex = true;
            }
          }
          expect(
            sawTorsoFlex,
            isTrue,
            reason: 'retain torso flex instead of a rigid flip',
          );
          expect(
            sawKneeBend,
            isTrue,
            reason: 'retain the independent knee buckle',
          );
          expect(
            model.isSettled,
            isTrue,
            reason: 'direction$direction strength$strength',
          );
        }
      }
    },
  );

  test(
    'authored viewports keep articulated landings bounded on both requested sides',
    () {
      for (final target in const [
        GoliathPoint(160, 180),
        GoliathPoint(225, 145),
        GoliathPoint(148, 92),
      ]) {
        final tx = target.x / 320 * 390;
        final width = math.min(
          390 * .78 * .75,
          math.min((tx - 8) / .451, (382 - tx) / .549),
        );
        final left = tx - width * .451;
        for (final direction in [-1.0, 1.0]) {
          for (final strength in [.6, 1.0, 1.4]) {
            final model = GoliathMotionModel(
              minimumX: (8 - left) / width,
              maximumX: (382 - left) / width,
              idleMotion: false,
            )..strikeHead(direction: direction, strength: strength);
            for (var frame = 0; frame < 720 && !model.isSettled; frame++) {
              final pose = model.advance(1 / 120);
              final pelvis = pose.boneTransform(
                GoliathJoint.leftHip,
                GoliathJoint.rightHip,
              );
              for (final pair in [
                (GoliathJoint.leftHip, GoliathJoint.leftKnee),
                (GoliathJoint.rightHip, GoliathJoint.rightKnee),
              ]) {
                expect(
                  _wrap(
                    pose.boneTransform(pair.$1, pair.$2).rotationRadians -
                        pelvis.rotationRadians,
                  ).abs(),
                  lessThan(.72),
                );
              }
              final chest = pose.boneTransform(
                GoliathJoint.leftShoulder,
                GoliathJoint.rightShoulder,
              );
              final shieldArm = pose.boneTransform(
                GoliathJoint.rightShoulder,
                GoliathJoint.rightElbow,
              );
              expect(
                _wrap(shieldArm.rotationRadians - chest.rotationRadians).abs(),
                lessThan(.52),
                reason: 'shield upper arm remains close to its chest frame',
              );
              for (final point in pose.joints.values) {
                expect(
                  point.x,
                  inInclusiveRange(model.minimumX, model.maximumX),
                );
                expect(point.x.isFinite && point.y.isFinite, isTrue);
              }
            }
            expect(
              model.isSettled,
              isTrue,
              reason: 'target$target direction$direction strength$strength',
            );
            expect(model.pose.isGrounded, isTrue);
            expect(model.pose.elapsedSeconds, lessThan(5.5));
          }
        }
      }
    },
  );

  test('settled knees fold into a compact pair of feet on both fall sides', () {
    for (final direction in [-1.0, 1.0]) {
      final model = GoliathMotionModel(idleMotion: false)
        ..strikeHead(direction: direction);
      _advance(model, 4);
      expect(model.pose.isSettled, isTrue);
      expect(
        _distance(
          model.pose[GoliathJoint.leftToe],
          model.pose[GoliathJoint.rightToe],
        ),
        lessThan(.10),
        reason:
            'A side landing folds the shins instead of keeping the wide standing stance.',
      );
    }
  });

  test('frame rate does not change the fixed-timestep collapse', () {
    final at30 = GoliathMotionModel()..strikeHead();
    final at120 = GoliathMotionModel()..strikeHead();
    _advance(at30, 1.5, fps: 30);
    _advance(at120, 1.5, fps: 120);
    expect(at30.pose.elapsedSeconds, closeTo(at120.pose.elapsedSeconds, 1e-12));
    for (final joint in GoliathJoint.values) {
      _expectPoint(at30.pose[joint], at120.pose[joint], tolerance: 1e-9);
    }
  });

  test(
    'a long foreground hitch is bounded rather than replaying seconds at once',
    () {
      final model = GoliathMotionModel()..strikeHead();
      model.advance(8);
      expect(model.pose.elapsedSeconds, closeTo(.25, 1e-9));
      expect(model.pose.phase, GoliathMotionPhase.buckling);
      expect(model.isSettled, isFalse);
    },
  );

  test(
    'bone lengths and neck/spine limits survive both directions of collapse',
    () {
      final bones = [
        [GoliathJoint.neck, GoliathJoint.head],
        [GoliathJoint.head, GoliathJoint.forehead],
        [GoliathJoint.chest, GoliathJoint.neck],
        [GoliathJoint.chest, GoliathJoint.lumbar],
        [GoliathJoint.lumbar, GoliathJoint.pelvis],
        [GoliathJoint.leftShoulder, GoliathJoint.leftElbow],
        [GoliathJoint.leftElbow, GoliathJoint.leftWrist],
        [GoliathJoint.rightShoulder, GoliathJoint.rightElbow],
        [GoliathJoint.rightElbow, GoliathJoint.rightWrist],
        [GoliathJoint.leftHip, GoliathJoint.leftKnee],
        [GoliathJoint.leftKnee, GoliathJoint.leftAnkle],
        [GoliathJoint.rightHip, GoliathJoint.rightKnee],
        [GoliathJoint.rightKnee, GoliathJoint.rightAnkle],
        [GoliathJoint.leftAnkle, GoliathJoint.leftToe],
        [GoliathJoint.rightAnkle, GoliathJoint.rightToe],
      ];
      for (final direction in [-1.0, 1.0]) {
        final model = GoliathMotionModel()..strikeHead(direction: direction);
        for (var frame = 0; frame < 360; frame++) {
          final pose = model.advance(1 / 120);
          for (final bone in bones) {
            final restLength = _distance(
              pose.restJoints[bone[0]]!,
              pose.restJoints[bone[1]]!,
            );
            expect(
              _distance(pose[bone[0]], pose[bone[1]]),
              closeTo(restLength, .004),
              reason: '$direction ${bone[0]}→${bone[1]} frame$frame',
            );
          }
          expect(
            _hingeChange(
              pose,
              GoliathJoint.chest,
              GoliathJoint.neck,
              GoliathJoint.head,
            ).abs(),
            lessThan(.44),
          );
          expect(
            _hingeChange(
              pose,
              GoliathJoint.chest,
              GoliathJoint.lumbar,
              GoliathJoint.pelvis,
            ).abs(),
            lessThan(.35),
          );
          for (final ankle in [
            GoliathJoint.leftAnkle,
            GoliathJoint.rightAnkle,
          ]) {
            expect(
              _hingeChange(
                pose,
                ankle == GoliathJoint.leftAnkle
                    ? GoliathJoint.leftKnee
                    : GoliathJoint.rightKnee,
                ankle,
                ankle == GoliathJoint.leftAnkle
                    ? GoliathJoint.leftToe
                    : GoliathJoint.rightToe,
              ).abs(),
              lessThan(.70),
              reason: '$direction ${ankle.name} frame$frame',
            );
          }
        }
      }
    },
  );

  test(
    'rigid source silhouettes stay above the floor in their rendered frames',
    () {
      for (final direction in [-1.0, 1.0]) {
        final model = GoliathMotionModel()..strikeHead(direction: direction);
        for (var frame = 0; frame < 360; frame++) {
          final pose = model.advance(1 / 120);
          for (final joint in GoliathJoint.values) {
            expect(
              pose[joint].y + pose.groundExtents[joint]!,
              lessThanOrEqualTo(GoliathMotionModel.groundY + .002),
              reason: '${joint.name} frame$frame',
            );
          }
          for (final ankle in [
            GoliathJoint.leftAnkle,
            GoliathJoint.rightAnkle,
          ]) {
            final toe = ankle == GoliathJoint.leftAnkle
                ? GoliathJoint.leftToe
                : GoliathJoint.rightToe;
            final transform = pose.boneTransform(ankle, toe);
            for (final point in GoliathMotionModel.footOutlines[ankle]!) {
              expect(
                transform.transformPoint(point).y,
                lessThanOrEqualTo(GoliathMotionModel.groundY + .003),
              );
            }
          }
          final rigidSurfaces = [
            (
              GoliathJoint.leftElbow,
              GoliathJoint.leftWrist,
              GoliathMotionModel.leftForearmOutline,
            ),
            (
              GoliathJoint.leftKnee,
              GoliathJoint.leftAnkle,
              GoliathMotionModel.leftShinOutline,
            ),
            (
              GoliathJoint.rightKnee,
              GoliathJoint.rightAnkle,
              GoliathMotionModel.rightShinOutline,
            ),
            (
              GoliathJoint.neck,
              GoliathJoint.head,
              GoliathMotionModel.headOutline,
            ),
            (
              GoliathJoint.rightElbow,
              GoliathJoint.rightWrist,
              GoliathMotionModel.shieldOutline,
            ),
            (
              GoliathJoint.leftHip,
              GoliathJoint.rightHip,
              GoliathMotionModel.apronOutline,
            ),
            (
              GoliathJoint.leftWrist,
              GoliathJoint.leftPalm,
              GoliathMotionModel.palmOutline,
            ),
            (
              GoliathJoint.leftShoulder,
              GoliathJoint.rightShoulder,
              GoliathMotionModel.chestOutline,
            ),
          ];
          for (final surface in rigidSurfaces) {
            final transform = pose.boneTransform(surface.$1, surface.$2);
            for (final point in surface.$3) {
              expect(
                transform.transformPoint(point).y,
                lessThanOrEqualTo(GoliathMotionModel.groundY + .003),
                reason: '$direction ${surface.$1}→${surface.$2} frame$frame',
              );
            }
          }
        }
      }
    },
  );

  test('configured viewport bounds constrain the fall continuously', () {
    final model = GoliathMotionModel(minimumX: -.15, maximumX: 1.25)
      ..strikeHead();
    for (var frame = 0; frame < 360; frame++) {
      final pose = model.advance(1 / 120);
      for (final point in pose.joints.values) {
        expect(point.x, inInclusiveRange(model.minimumX, model.maximumX));
        expect(point.x.isFinite && point.y.isFinite, isTrue);
      }
    }
    expect(model.isSettled, isTrue);
  });

  test(
    'success readiness requires real body contact and a quiet settling interval',
    () {
      for (final direction in [-1.0, 1.0]) {
        for (final strength in [.6, 1.0, 1.4]) {
          final model = GoliathMotionModel()
            ..strikeHead(direction: direction, strength: strength);
          var sawMovingContact = false;
          for (var frame = 0; frame < 480 && !model.isSettled; frame++) {
            final pose = model.advance(1 / 120);
            if (pose.isGrounded && !pose.isSettled) sawMovingContact = true;
            if (pose.isSettled) {
              expect(pose.isGrounded, isTrue);
              expect(pose.elapsedSeconds, greaterThan(1.9));
              expect(pose.maximumSpeed, 0);
              expect(
                pose.groundContacts.any(
                  (joint) => const {
                    GoliathJoint.head,
                    GoliathJoint.chest,
                    GoliathJoint.pelvis,
                    GoliathJoint.leftPalm,
                    GoliathJoint.leftElbow,
                  }.contains(joint),
                ),
                isTrue,
              );
            }
          }
          expect(sawMovingContact, isTrue);
          expect(
            model.isSettled,
            isTrue,
            reason: 'direction$direction strength$strength',
          );
          expect(model.pose.phase, GoliathMotionPhase.settled);
        }
      }
    },
  );

  test(
    'settled joints remain stable and a repeated hit cannot restart the collapse',
    () {
      final model = GoliathMotionModel()..strikeHead();
      _advance(model, 4);
      final settled = model.pose;
      expect(settled.isSettled, isTrue);
      model.strikeHead(direction: -1, strength: 1.4);
      _advance(model, 8);
      expect(identical(model.pose, settled), isTrue);
      model.reset();
      expect(model.pose.phase, GoliathMotionPhase.standing);
      expect(model.pose.elapsedSeconds, 0);
      _expectPoint(
        model.pose[GoliathJoint.forehead],
        const GoliathPoint(.451, .115),
      );
    },
  );

  test(
    'bone transform maps endpoints using physical 3:4 aspect without diagonal stretching',
    () {
      final transform = GoliathBoneTransform(
        restFrom: const GoliathPoint(.2, .2),
        restTo: const GoliathPoint(.6, .2),
        from: const GoliathPoint(.4, .3),
        to: const GoliathPoint(.4, .6),
        aspectRatio: .75,
      );
      expect(transform.rotationRadians, closeTo(math.pi / 2, 1e-12));
      expect(transform.scale, closeTo(1, 1e-12));
      _expectPoint(
        transform.transformPoint(const GoliathPoint(.6, .2)),
        const GoliathPoint(.4, .6),
      );
      _expectPoint(
        transform.transformPoint(const GoliathPoint(.2, .3)),
        const GoliathPoint(.4 - .1 / .75, .3),
      );
    },
  );

  test(
    'unsupported narrow cage is rejected before the actor can be launched',
    () {
      expect(
        () => GoliathMotionModel(minimumX: -.1, maximumX: 1.2),
        throwsArgumentError,
      );
    },
  );

  test(
    'invalid time/impact/window values are rejected without corrupting the pose',
    () {
      final model = GoliathMotionModel();
      expect(() => model.advance(-1), throwsArgumentError);
      expect(() => model.advance(double.nan), throwsArgumentError);
      expect(
        () => model.strikeHead(direction: double.infinity),
        throwsArgumentError,
      );
      expect(() => model.strikeHead(strength: double.nan), throwsArgumentError);
      expect(
        () => GoliathMotionModel(minimumX: .2, maximumX: .5),
        throwsArgumentError,
      );
      expect(model.pose.phase, GoliathMotionPhase.standing);
    },
  );
}

void _advance(GoliathMotionModel model, double seconds, {int fps = 60}) {
  final frames = (seconds * fps).floor();
  for (var frame = 0; frame < frames; frame++) {
    model.advance(1 / fps);
  }
  final remaining = seconds - frames / fps;
  if (remaining > 1e-10) model.advance(remaining);
}

double _distance(GoliathPoint a, GoliathPoint b) {
  final dx = (a.x - b.x) * GoliathMotionModel.aspectRatio;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

double _hingeChange(
  GoliathPose pose,
  GoliathJoint a,
  GoliathJoint pivot,
  GoliathJoint c,
) {
  double angle(Map<GoliathJoint, GoliathPoint> points) {
    final first = points[a]!;
    final middle = points[pivot]!;
    final last = points[c]!;
    return _wrap(
      math.atan2(last.y - middle.y, (last.x - middle.x) * .75) -
          math.atan2(middle.y - first.y, (middle.x - first.x) * .75),
    );
  }

  return _wrap(angle(pose.joints) - angle(pose.restJoints));
}

double _wrap(double angle) {
  while (angle > math.pi) {
    angle -= 2 * math.pi;
  }
  while (angle < -math.pi) {
    angle += 2 * math.pi;
  }
  return angle;
}

void _expectPoint(
  GoliathPoint actual,
  GoliathPoint expected, {
  double tolerance = 1e-10,
}) {
  expect(actual.x, closeTo(expected.x, tolerance));
  expect(actual.y, closeTo(expected.y, tolerance));
}
