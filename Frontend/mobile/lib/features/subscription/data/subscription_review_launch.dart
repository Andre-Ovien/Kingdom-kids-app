import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/router.dart';
import '../../../core/storage/secure_storage.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/auth_session.dart';
import '../../splash/data/startup_destination_resolver.dart';

const subscriptionReviewBuildId = String.fromEnvironment(
  'SUBSCRIPTION_REVIEW_ID',
);

class SubscriptionReviewArguments {
  const SubscriptionReviewArguments({
    required this.reviewId,
    required this.parentId,
    required this.returnRoute,
    this.returnArguments,
  });
  final String reviewId;
  final String parentId;
  final String returnRoute;
  final Object? returnArguments;
}

abstract interface class SubscriptionReviewStore {
  Future<bool> claim(String reviewId);
}

class SecureSubscriptionReviewStore implements SubscriptionReviewStore {
  SecureSubscriptionReviewStore({FlutterSecureStorage? storage})
    : _storage = storage ?? kingdomKidsSecureStorage;
  static const markerKey = 'kingdom_kids.subscription_review_consumed';
  final FlutterSecureStorage _storage;
  @override
  Future<bool> claim(String reviewId) async {
    if (await _storage.read(key: markerKey) == reviewId) return false;
    await _storage.write(key: markerKey, value: reviewId);
    return true;
  }
}

class MemorySubscriptionReviewStore implements SubscriptionReviewStore {
  String? consumed;
  @override
  Future<bool> claim(String reviewId) async {
    if (consumed == reviewId) return false;
    consumed = reviewId;
    return true;
  }
}

/// A read-only review is local startup routing, never payment authorization.
bool hasSubscriptionReviewSession(AuthSession? session, DateTime now) {
  if (session == null ||
      session.parent.id.trim().isEmpty ||
      session.parent.email.trim().isEmpty ||
      session.accessToken.trim().isEmpty) {
    return false;
  }
  final pieces = session.accessToken.split('.');
  if (pieces.length == 3) {
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(pieces[1]))),
      );
      if (claims is! Map ||
          claims['exp'] is! num ||
          (claims['exp'] as num) * 1000 <= now.millisecondsSinceEpoch) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }
  return true;
}

/// The normal startup decision is preserved; a separate marker is consumed
/// only after an existing local parent session. Never writes auth/profile data.
class SubscriptionReviewDestinationResolver
    implements SplashDestinationResolver {
  SubscriptionReviewDestinationResolver({
    SplashDestinationResolver? normalStartup,
    AuthRepository? authRepository,
    SubscriptionReviewStore? reviewStore,
    this.reviewId = subscriptionReviewBuildId,
    this.allowReview = !kReleaseMode,
    DateTime Function()? now,
  }) : _normal = normalStartup ?? StartupDestinationResolver(),
       _auth = authRepository ?? AuthRepository(),
       _store = reviewStore ?? SecureSubscriptionReviewStore(),
       _now = now ?? DateTime.now;
  final SplashDestinationResolver _normal;
  final AuthRepository _auth;
  final SubscriptionReviewStore _store;
  final DateTime Function() _now;
  final String reviewId;
  final bool allowReview;

  @override
  Future<StartupDestination> resolve() async {
    final normal = await _normal.resolve();
    if (kReleaseMode ||
        !allowReview ||
        !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(reviewId) ||
        !const {
          AppRoutes.home,
          AppRoutes.profilePicker,
          AppRoutes.kidProfileSetup,
          AppRoutes.profile,
        }.contains(normal.route)) {
      return normal;
    }
    try {
      final session = await _auth.restoreSession();
      if (!hasSubscriptionReviewSession(session, _now()) ||
          !await _store.claim(reviewId)) {
        return normal;
      }
      return StartupDestination(
        AppRoutes.subscriptionReview,
        arguments: SubscriptionReviewArguments(
          reviewId: reviewId,
          parentId: session!.parent.id,
          returnRoute: normal.route,
          returnArguments: normal.arguments,
        ),
      );
    } catch (_) {
      // Missing/locked review storage must never reset a family session or
      // force onboarding. Resume exactly the original startup destination.
      return normal;
    }
  }
}
