import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';

import '../tool/replay_streak.dart';

const _kid = KidProfile(
  id: 'selected-kid',
  parentId: 'parent',
  displayName: 'Saved child',
  avatarKey: 'lion',
);

void main() {
  test(
    'replays the selected child once, then resumes normal saved startup',
    () async {
      final markers = <String, String>{};
      final normal = _NormalStartup();
      final snapshots = {
        _kid.id: _snapshot(_kid),
        'another-kid': _snapshot(_kid.copyWith(id: 'another-kid')),
      };
      StreakReviewDestinationResolver resolver() =>
          StreakReviewDestinationResolver(
            reviewId: 'test-review',
            snapshots: snapshots,
            currentKid: () async => _kid,
            normalStartup: normal,
            readMarker: (key) async => markers[key],
            writeMarker: (key) async => markers[key] = 'shown',
          );

      final first = await resolver().resolve();
      expect(first.route, AppRoutes.streak);
      final presentation = first.arguments! as StreakPresentation;
      expect(presentation.profile, same(_kid));
      expect(presentation.currentDays, 3);
      expect(presentation.recentDays.where((day) => day.active).length, 3);
      expect(markers, {'kingdom_kids_dev_streak_review_test-review': 'shown'});
      expect(normal.calls, 0);
      expect((await resolver().resolve()).route, AppRoutes.home);
      expect(normal.calls, 1);
    },
  );

  for (final scenario in [
    'missing child',
    'wrong parent',
    'malformed snapshot',
  ]) {
    test(
      '$scenario falls back without consuming review or writing session',
      () async {
        final normal = _NormalStartup();
        var writes = 0;
        final snapshot = scenario == 'malformed snapshot'
            ? <String, dynamic>{}
            : _snapshot(
                scenario == 'wrong parent'
                    ? _kid.copyWith(parentId: 'another-parent')
                    : _kid,
              );
        final resolver = StreakReviewDestinationResolver(
          reviewId: 'test-review',
          snapshots: {_kid.id: snapshot},
          currentKid: () async => scenario == 'missing child' ? null : _kid,
          normalStartup: normal,
          readMarker: (_) async => null,
          writeMarker: (_) async => writes++,
        );
        expect((await resolver.resolve()).route, AppRoutes.home);
        expect(writes, 0);
        expect(normal.calls, 1);
      },
    );
  }
}

Map<String, dynamic> _snapshot(KidProfile kid) => {
  'profile': kid.toJson(),
  'state': 'continued',
  'current_days': 3,
  'longest_days': 4,
  'local_date': '2026-11-11',
  'recent_days': [
    for (var day = 5; day <= 11; day++)
      {'date': '2026-11-${day.toString().padLeft(2, '0')}', 'active': day >= 9},
  ],
};

class _NormalStartup implements SplashDestinationResolver {
  int calls = 0;

  @override
  Future<StartupDestination> resolve() async {
    calls++;
    return const StartupDestination(AppRoutes.home);
  }
}
