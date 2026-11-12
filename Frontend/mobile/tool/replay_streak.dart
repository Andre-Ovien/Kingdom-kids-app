// Explicit, one-time device review. Normal builds keep lib/main.dart.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile/app/app.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/storage/secure_storage.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';
import 'package:mobile/main.dart' as production;
import 'package:mobile/shared/widgets/app_error_fallback.dart';

void main() {
  if (kReleaseMode) {
    production.main();
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (_) => const AppErrorFallback();
  try {
    AppConfig.validateApiBaseUri();
    final decoded = jsonDecode(
      const String.fromEnvironment(
        'STREAK_REVIEW_SNAPSHOTS',
        defaultValue: '{}',
      ),
    );
    final auth = AuthRepository();
    runApp(
      KingdomKidsApp(
        splashDestinationResolver: StreakReviewDestinationResolver(
          reviewId: const String.fromEnvironment('STREAK_REVIEW_ID'),
          snapshots: decoded is Map ? decoded : const {},
          currentKid: auth.currentKid,
          normalStartup: StartupDestinationResolver(authRepository: auth),
          readMarker: (key) => kingdomKidsSecureStorage.read(key: key),
          writeMarker: (key) =>
              kingdomKidsSecureStorage.write(key: key, value: 'shown'),
        ),
      ),
    );
  } on AppConfigurationException {
    runApp(const MaterialApp(home: AppErrorFallback()));
  } on FormatException {
    production.main();
  }
}

/// Replays a saved server presentation without claiming a visit or awarding XP.
///
/// Only a dedicated development marker is written. Auth, active-child selection,
/// welcome flags, rewards, and server presentation receipts are never changed.
/// Subsequent launches of this same review build follow normal saved startup.
class StreakReviewDestinationResolver implements SplashDestinationResolver {
  const StreakReviewDestinationResolver({
    required this.reviewId,
    required this.snapshots,
    required this.currentKid,
    required this.normalStartup,
    required this.readMarker,
    required this.writeMarker,
  });

  final String reviewId;
  final Map<dynamic, dynamic> snapshots;
  final Future<KidProfile?> Function() currentKid;
  final SplashDestinationResolver normalStartup;
  final Future<String?> Function(String key) readMarker;
  final Future<void> Function(String key) writeMarker;

  @override
  Future<StartupDestination> resolve() async {
    if (reviewId.trim().isEmpty || snapshots.isEmpty) {
      return normalStartup.resolve();
    }
    final markerKey = 'kingdom_kids_dev_streak_review_$reviewId';
    try {
      if (await readMarker(markerKey) != null) {
        return normalStartup.resolve();
      }
      final kid = await currentKid();
      final raw = snapshots[kid?.id];
      if (kid == null || raw is! Map) return normalStartup.resolve();
      final saved = StreakPresentation.fromJson(Map<String, dynamic>.from(raw));
      if (saved.profile.id != kid.id ||
          saved.profile.parentId != kid.parentId) {
        return normalStartup.resolve();
      }
      final presentation = StreakPresentation(
        profile: kid,
        state: saved.state,
        currentDays: saved.currentDays,
        longestDays: saved.longestDays,
        localDate: saved.localDate,
        recentDays: saved.recentDays,
      );
      await writeMarker(markerKey);
      return StartupDestination(AppRoutes.streak, arguments: presentation);
    } catch (_) {
      // A review failure must never strand a family or change their session.
      return normalStartup.resolve();
    }
  }
}
