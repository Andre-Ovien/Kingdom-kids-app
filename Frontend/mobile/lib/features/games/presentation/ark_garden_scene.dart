import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../domain/ark_garden_model.dart';
import '../domain/ark_garden_projection.dart';

/// Implemented only by reviewed Blender art. No fallback animals or scenery
/// ship with the staged engine. The adapter owns its images and their disposal.
abstract class ArkGardenScene {
  bool get reviewed;
  Set<String> get species;
  void paintWorld(Canvas canvas, ArkGardenViewport viewport, int sceneTick);
  void paintAnimal(Canvas canvas, ArkGardenAnimalFrame animal);
  void paintDoorForeground(Canvas canvas, ArkGardenViewport viewport);
  void paintForeground(
    Canvas canvas,
    ArkGardenViewport viewport,
    int sceneTick,
  );
}

class ArkGardenAnimalFrame {
  const ArkGardenAnimalFrame({
    required this.animal,
    required this.phase,
    required this.position,
    required this.feet,
    required this.groundFeet,
    required this.heading,
    required this.walkTicks,
    required this.sceneTick,
    required this.bodyLengthPixels,
    required this.reducedMotion,
  });
  final ArkGardenAnimal animal;
  final ArkGardenAnimalPhase phase;
  final ArkGardenPoint position;
  final Offset feet;
  final Offset groundFeet;
  final double heading;
  final int walkTicks;
  final int sceneTick;
  final double bodyLengthPixels;
  final bool reducedMotion;
  bool get entering => phase == ArkGardenAnimalPhase.entering;
  bool get moving => phase != ArkGardenAnimalPhase.idle;
}

/// Keeps the entire sprite/shadow transform inside one shared viewport. The
/// doorway's opaque foreground hides entering animals, while animals outside
/// remain in front. Boarded animals never appear again on the Ark deck.
class ArkGardenPainter extends CustomPainter {
  ArkGardenPainter({
    required this.run,
    required this.scene,
    required this.viewport,
    required this.reducedMotion,
    this.positionFor,
    this.onAnimalTap,
    super.repaint,
  });
  final ArkGardenRun run;
  final ArkGardenScene scene;
  final ArkGardenViewport viewport;
  final bool reducedMotion;
  final ArkGardenPoint Function(ArkGardenAnimalState)? positionFor;
  final void Function(String)? onAnimalTap;

  List<ArkGardenAnimalFrame> get frames {
    final states = run.animals.where((state) => !state.boarded).toList()
      ..sort(
        (a, b) =>
            viewport.depth(a.position).compareTo(viewport.depth(b.position)),
      );
    return states.map((state) {
      final position = positionFor?.call(state) ?? state.position;
      final feet = viewport.project(position);
      final groundFeet = viewport.project(
        ArkGardenPoint(position.x, position.y, 0),
      );
      return ArkGardenAnimalFrame(
        animal: state.animal,
        phase: state.phase,
        position: position,
        feet: Offset(feet.x, feet.y),
        groundFeet: Offset(groundFeet.x, groundFeet.y),
        heading: state.heading,
        walkTicks: state.walkTicks,
        sceneTick: run.tick,
        bodyLengthPixels: state.animal.bodyLengthUnits * viewport.scale,
        reducedMotion: reducedMotion,
      );
    }).toList();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    scene.paintWorld(canvas, viewport, run.tick);
    final animals = frames;
    for (final animal in animals.where((animal) => animal.entering)) {
      scene.paintAnimal(canvas, animal);
    }
    scene.paintDoorForeground(canvas, viewport);
    for (final animal in animals.where((animal) => !animal.entering)) {
      scene.paintAnimal(canvas, animal);
    }
    scene.paintForeground(canvas, viewport, run.tick);
    canvas.restore();
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (final frame in frames)
          if (frame.phase == ArkGardenAnimalPhase.idle &&
              Rect.fromCircle(
                center: frame.feet,
                radius: hitRadius(frame),
              ).overlaps(Offset.zero & size))
            CustomPainterSemantics(
              rect: Rect.fromCenter(
                center: frame.feet,
                width: hitRadius(frame) * 2,
                height: hitRadius(frame) * 2,
              ).intersect(Offset.zero & size),
              properties: SemanticsProperties(
                label: '${frame.animal.label}. Tap to walk aboard.',
                button: true,
                enabled: run.canTap,
                textDirection: TextDirection.ltr,
                onTap: run.canTap
                    ? () => onAnimalTap?.call(frame.animal.id)
                    : null,
              ),
            ),
      ];

  static double hitRadius(ArkGardenAnimalFrame frame) =>
      (frame.bodyLengthPixels * .5).clamp(22.0, 90.0);

  @override
  bool shouldRepaint(covariant ArkGardenPainter oldDelegate) => true;
  @override
  bool shouldRebuildSemantics(covariant ArkGardenPainter oldDelegate) => true;
}
