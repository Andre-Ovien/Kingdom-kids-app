import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../domain/ark_traffic_model.dart';
import 'ark_traffic_graphics.dart';

/// All characters, environments and gate states come from Blender renders.
/// Flutter paints only the child's path, functional selection and status marks.
class ArkTrafficPainter extends CustomPainter {
  ArkTrafficPainter({
    required this.run,
    required this.graphics,
    required this.selectedId,
    required this.draft,
    required this.reducedMotion,
    this.onAnimalTap,
    this.onGateTap,
    this.positionFor,
    super.repaint,
  });
  final ArkTrafficRun run;
  final ArkTrafficGraphics graphics;
  final String? selectedId;
  final List<String> draft;
  final bool reducedMotion;
  final void Function(String)? onAnimalTap;
  final void Function(String)? onGateTap;
  final ArkTrafficPoint Function(ArkTrafficAnimalState)? positionFor;

  static Rect boardRect(Size size) =>
      Rect.fromLTWH(0, 56, size.width, math.max(1, size.height - 122));
  static Offset point(ArkTrafficPoint point, Size size) {
    final board = boardRect(size);
    return Offset(
      board.left + point.x * board.width,
      board.top + point.y * board.height,
    );
  }

  static ArkTrafficPoint normalized(Offset point, Size size) {
    final board = boardRect(size);
    return ArkTrafficPoint(
      (point.dx - board.left) / board.width,
      (point.dy - board.top) / board.height,
    );
  }

  static Offset animalPosition(
    ArkTrafficAnimalState state,
    ArkTrafficCourse course,
    Size size, {
    ArkTrafficPoint? pointOverride,
  }) {
    var position = pointOverride ?? state.position(course);
    if (state.waiting) {
      final heading = state.heading(course);
      final shoulder = ArkTrafficAnimal.radiusFor(state.animal.species) * 1.6;
      position = ArkTrafficPoint(
        position.x - math.sin(heading) * shoulder,
        position.y + math.cos(heading) * shoulder,
      );
    }
    return point(position, size);
  }

  Offset _animal(ArkTrafficAnimalState state, Size size) => animalPosition(
    state,
    run.course,
    size,
    pointOverride: positionFor?.call(state),
  );
  static double hitRadius(Size size, String species) =>
      math.max(22.0, ArkTrafficAnimal.radiusFor(species) * size.width * 2);

  @override
  void paint(Canvas canvas, Size size) {
    final board = boardRect(size);
    canvas.drawColor(const Color(0xFF729957), BlendMode.src);
    canvas.drawImageRect(
      graphics.background,
      Rect.fromLTWH(
        0,
        0,
        graphics.background.width.toDouble(),
        graphics.background.height.toDouble(),
      ),
      board,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final selected = selectedId == null ? null : run.animal(selectedId!);
    if (selected != null) {
      // Functional trail guides appear while the child is drawing a route.
      for (final edge in run.course.edges) {
        if (!edge.accepts(selected.animal.species)) continue;
        canvas.drawLine(
          point(run.course.nodes[edge.a]!, size),
          point(run.course.nodes[edge.b]!, size),
          Paint()
            ..color = const Color(0x990C8290)
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
      }
      for (final node in run.course.nodes.values) {
        canvas.drawCircle(
          point(node, size),
          5,
          Paint()..color = const Color(0xEFFFF3BD),
        );
      }
    }
    for (final state in run.animals) {
      if (state.boarded || state.route.length < 2) continue;
      final route = Path()
        ..moveTo(_animal(state, size).dx, _animal(state, size).dy);
      for (var index = state.segment + 1; index < state.route.length; index++) {
        final target = point(run.course.nodes[state.route[index]]!, size);
        route.lineTo(target.dx, target.dy);
      }
      canvas.drawPath(
        route,
        Paint()
          ..color = state.waiting
              ? const Color(0x70F8CF61)
              : const Color(0x70138091)
          ..strokeWidth = 2.8
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    if (draft.isNotEmpty && selected != null) {
      final path = Path();
      final start = _animal(selected, size);
      path.moveTo(start.dx, start.dy);
      for (final id in draft) {
        final target = point(run.course.nodes[id]!, size);
        path.lineTo(target.dx, target.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFFFFCF58)
          ..strokeWidth = 6
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    for (final edge in run.course.edges.where((edge) => edge.gate != null)) {
      final a = run.course.nodes[edge.a]!;
      final b = run.course.nodes[edge.b]!;
      final anchor = point(
        ArkTrafficPoint((a.x + b.x) / 2, (a.y + b.y) / 2),
        size,
      );
      final atlas = graphics.gate;
      if (atlas != null) {
        final source = atlas.source(0, run.gates[edge.gate]! ? 1 : 0);
        final width = math.max(48.0, size.width * edge.width * 1.25);
        _sprite(canvas, atlas, source, anchor, width);
      }
      _status(
        canvas,
        anchor + const Offset(0, -23),
        run.gates[edge.gate]! ? 'OPEN' : 'TAP',
        run.gates[edge.gate]!
            ? const Color(0xFF157B76)
            : const Color(0xFF995A24),
      );
    }
    final states = run.animals.where((state) => !state.boarded).toList()
      ..sort((a, b) => _animal(a, size).dy.compareTo(_animal(b, size).dy));
    for (final state in states) {
      final anchor = _animal(state, size);
      final radius =
          ArkTrafficAnimal.radiusFor(state.animal.species) * size.width;
      if (state.animal.id == selectedId) {
        canvas.drawOval(
          Rect.fromCenter(
            center: anchor,
            width: radius * 3.0,
            height: radius * 1.2,
          ),
          Paint()
            ..color = const Color(0xBAFFEAB4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
      final atlas = graphics.animals[state.animal.species]!;
      var direction =
          ((state.heading(run.course) / (math.pi * 2 / 8)).round() % 8 + 8) % 8;
      var frame = state.movedLastTick && !reducedMotion
          ? 1 + state.walkTicks % (atlas.frames - 1)
          : 0;
      _sprite(
        canvas,
        atlas,
        atlas.source(direction, frame),
        anchor,
        radius * 5.4,
      );
      if (state.waiting) {
        _status(
          canvas,
          anchor + Offset(0, -radius * 3.6),
          'WAIT',
          const Color(0xFF88551D),
        );
      } else if (state.blocked) {
        _status(
          canvas,
          anchor + Offset(0, -radius * 3.6),
          'AFTER YOU!',
          const Color(0xFFBD6C40),
        );
      }
    }
    // Each rescued friend remains visible on the ark as the decks fill.
    final boarded = run.animals.where((state) => state.boarded).toList();
    for (var index = 0; index < boarded.length; index++) {
      final state = boarded[index];
      final atlas = graphics.animals[state.animal.species]!;
      final deck = point(
        ArkTrafficPoint(.65 + (index % 6) * .047, .15 - (index ~/ 6) * .032),
        size,
      );
      _sprite(canvas, atlas, atlas.source(0, 0), deck, size.width * .070);
    }
  }

  static void _sprite(
    Canvas canvas,
    ArkTrafficAtlas atlas,
    Rect source,
    Offset feet,
    double width,
  ) {
    final scale = width / atlas.cell;
    final dest = Rect.fromLTWH(
      feet.dx - atlas.footAnchor.dx * scale,
      feet.dy - atlas.footAnchor.dy * scale,
      width,
      width,
    );
    canvas.drawImageRect(
      atlas.image,
      source,
      dest,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  static void _status(Canvas canvas, Offset at, String text, Color color) {
    final label = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 10,
          fontFamily: 'Avenir Next',
          fontWeight: FontWeight.w900,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
      center: at,
      width: label.width + 12,
      height: label.height + 7,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(9)),
      Paint()..color = color,
    );
    label.paint(canvas, Offset(rect.left + 6, rect.top + 3.5));
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (Size size) => [
        for (final state in run.animals.where((state) => !state.boarded))
          CustomPainterSemantics(
            rect: Rect.fromCircle(
              center: _animal(state, size),
              radius: hitRadius(size, state.animal.species),
            ),
            properties: SemanticsProperties(
              label:
                  '${state.animal.id.replaceAll('-', ' ')}. '
                  '${state.waiting ? 'Waiting. Tap to go.' : 'Tap to wait at the side.'}',
              textDirection: TextDirection.ltr,
              button: true,
              onTap: () => onAnimalTap?.call(state.animal.id),
            ),
          ),
        for (final edge in run.course.edges.where((edge) => edge.gate != null))
          CustomPainterSemantics(
            rect: Rect.fromCircle(
              center: point(
                ArkTrafficPoint(
                  (run.course.nodes[edge.a]!.x + run.course.nodes[edge.b]!.x) /
                      2,
                  (run.course.nodes[edge.a]!.y + run.course.nodes[edge.b]!.y) /
                      2,
                ),
                size,
              ),
              radius: 25,
            ),
            properties: SemanticsProperties(
              label:
                  '${edge.gate}. ${run.gates[edge.gate]! ? 'Open' : 'Closed'}. Tap to switch.',
              textDirection: TextDirection.ltr,
              button: true,
              onTap: () => onGateTap?.call(edge.gate!),
            ),
          ),
      ];
  @override
  bool shouldRepaint(covariant ArkTrafficPainter oldDelegate) => true;
  @override
  bool shouldRebuildSemantics(covariant ArkTrafficPainter oldDelegate) => true;
}
