import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_renderer.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(320, 568)]) {
    for (final count in [10, 15, 20]) {
      test('$count-person crowd preserves visible faces and sizes on $size', () {
        final centers = <Offset>{};
        final feet = <Offset>{};
        final roles = <String>{};
        for (var index = 0; index < count; index++) {
          final foot = RedSeaCrossingPainter.queuePosition(index, count, size);
          final center = RedSeaCrossingPainter.queueHitCenter(
            index,
            count,
            size,
          );
          centers.add(center);
          feet.add(foot);
          roles.add(RedSeaCrossingPainter.travellerRole(index));
          expect((Offset.zero & size).contains(center), isTrue);
          expect((Offset.zero & size).contains(foot), isTrue);
          final semantics = RedSeaCrossingPainter.queueSemanticsBounds(
            index,
            count,
            size,
          );
          expect(semantics.width, closeTo(44, .000001));
          expect(semantics.height, closeTo(44, .000001));
          expect(semantics.contains(center), isTrue);
          // A foreground robe may cover the lower body, never the pickup face.
          for (var other = 0; other < count; other++) {
            if (RedSeaCrossingPainter.queuePosition(other, count, size).dy <=
                foot.dy) {
              continue;
            }
            expect(
              RedSeaCrossingPainter.queueBodyBounds(
                other,
                count,
                size,
              ).contains(center),
              isFalse,
              reason: 'person $other covers the face of person $index',
            );
          }
          final height = RedSeaCrossingPainter.travellerHeight(
            index,
            count,
            size,
          );
          final base = RedSeaCrossingPainter.travellerRadius(size) * 2;
          expect(height / base, inInclusiveRange(.65, 1.06));
          if (size.width == 390) {
            expect(
              height,
              index % 3 == 2
                  ? inInclusiveRange(55, 65)
                  : inInclusiveRange(77, 91),
            );
          }
        }
        expect(centers, hasLength(count));
        expect(feet, hasLength(count));
        expect(roles, {'man', 'woman', 'child'});
        // Deliberately uneven depth is part of the crowd instead of two lines.
        expect(
          feet.map((foot) => foot.dy).toSet().length,
          greaterThan(count ~/ 2),
        );
      });
    }
  }

  test('adding people does not shrink them relative to Moses', () {
    const size = Size(390, 844);
    final radii = [
      for (final count in [10, 15, 20])
        RedSeaCrossingPainter.crowdRadius(count, size),
    ];
    expect(radii.toSet(), hasLength(1));
    expect(
      RedSeaCrossingPainter.travellerRadius(size) * 2 * .92,
      closeTo(78.936, .001),
    );
  });
}
