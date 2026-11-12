import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/core/network/feature_view_state_cache.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/shared/widgets/liquid_navigation_controller.dart';
import 'package:mobile/shared/widgets/persistent_liquid_navigation_host.dart';
import 'package:mobile/shared/widgets/scoped_feature_page.dart';

const _kid = KidProfile(
  id: 'production-shaped-child',
  parentId: 'production-shaped-parent',
  displayName: 'Ada',
  avatarKey: 'dove',
);
const _pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  testWidgets(
    'production routes, replayed XP and scoped signed covers keep Games visible on return',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      featureReadCache.invalidate();
      featureViewStateCache.clearIdentity();
      final store = SecureAuthSessionStore();
      await store.writeSession(
        const AuthSession(
          parent: ParentAccount(
            id: 'production-shaped-parent',
            email: 'fixture@example.test',
          ),
          accessToken: 'fixture-access',
          refreshToken: 'fixture-refresh',
          profiles: [_kid],
        ),
      );
      await store.writeSelectedKidId(_kid.id);
      var catalogues = 0, claims = 0, images = 0;
      String? source;
      final heldRenewal = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.url.host == 'api.cloudinary.com') {
          images++;
          expect(request.headers.containsKey('Authorization'), isFalse);
          if (images > 1) return heldRenewal.future;
          return http.Response.bytes(
            base64Decode(_pixel),
            200,
            headers: {'content-type': 'image/png'},
          );
        }
        expect(request.headers['Authorization'], 'Bearer fixture-access');
        if (request.method == 'POST' &&
            request.url.path.endsWith('/streak-presentations/claim/')) {
          claims++;
          // This is the backend's real idempotent replay shape: it repeats the
          // saved reward even though show=false means no new daily visit.
          return http.Response(
            jsonEncode({
              'show': false,
              'profile_id': _kid.id,
              'xp_awarded': 20,
              'level_milestone': null,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/summary/')) {
          return http.Response(
            jsonEncode({
              'profile': _kid.toJson(),
              'level': {'number': 1, 'xp': 20, 'next_level_xp': 300},
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/stories/')) {
          return http.Response('[]', 200);
        }
        if (request.url.path.endsWith('/games/')) {
          catalogues++;
          final issued = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          source = Uri.https(
            'api.cloudinary.com',
            '/v1_1/fixture/image/download',
            {
              'type': 'authenticated',
              'public_id':
                  'kingdom-kids/media-v1/sha256-${List.filled(64, 'a').join()}',
              'format': 'webp',
              'expires_at': '${issued + 900 + catalogues}',
              'signature': 'fixture-signature-$catalogues',
              'timestamp': '${issued + catalogues}',
            },
          ).toString();
          return http.Response(
            jsonEncode([
              {
                'id': 'signed-game',
                'slug': 'esther-quiz',
                'title': 'Signed scoped quest',
                'game_type': 'quiz',
                'is_featured': true,
                'total_levels': 1,
                'cover_image_url': source,
                'progress': {'profile_id': _kid.id},
              },
            ]),
            200,
          );
        }
        throw StateError(
          'Unexpected fixture endpoint ${request.method} ${request.url.path}',
        );
      });
      final navigator = GlobalKey<NavigatorState>();
      final controller = LiquidNavigationController(
        navigatorKey: navigator,
        onAcceptedSelection: () {},
        loadProfile: AuthRepository().currentKid,
        prepareTab: ScopedFeaturePage.prepare,
      );
      try {
        await http.runWithClient(() async {
          await ScopedFeaturePage.prepare(AppRoutes.home);
          Route<dynamic> route(RouteSettings settings) =>
              AppRouter.onGenerateRoute(settings);
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navigator,
              onGenerateInitialRoutes: (_) => [
                route(const RouteSettings(name: AppRoutes.home)),
              ],
              onGenerateRoute: route,
              navigatorObservers: [
                appRouteObserver,
                LiquidNavigationObserver(controller),
              ],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: true, accessibleNavigation: true),
                child: PersistentLiquidNavigationHost(
                  controller: controller,
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(claims, 1);
          expect(controller.select(AppRoutes.games), isTrue);
          await tester.pumpAndSettle();
          expect(catalogues, 1);
          expect(images, 1);
          final cover = find
              .descendant(
                of: find.byKey(const Key('games-featured-cover')),
                matching: find.byType(Image),
              )
              .first;
          await tester.runAsync(
            () => precacheImage(
              tester.widget<Image>(cover).image,
              tester.element(cover),
            ),
          );
          await tester.pumpAndSettle();
          final scope = await AuthRepository().featureCacheScope();
          expect(
            defaultContentMediaFetcher
                .peekScoped(source, scope: scope!)
                ?.cacheScope,
            scope,
          );
          expect(_hasCoverPixels(tester), isTrue);
          expect(controller.select(AppRoutes.home), isTrue);
          await tester.pumpAndSettle();
          expect(claims, 2);
          expect(controller.select(AppRoutes.games), isTrue);
          await tester.pump();
          await tester.pump();
          final report = {
            'claims': claims,
            'catalogues': catalogues,
            'images': images,
            'visible_cover_pixels': _hasCoverPixels(tester),
          };
          // Printed for the before/after production-source reproduction log.
          debugPrint('SCOPED_GAMES_RETURN ${jsonEncode(report)}');
          expect(report, {
            'claims': 2,
            'catalogues': 1,
            'images': 1,
            'visible_cover_pixels': true,
          });
          expect(find.text('Signed scoped quest'), findsWidgets);
          expect(tester.takeException(), isNull);
        }, () => client);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!heldRenewal.isCompleted) {
          heldRenewal.complete(
            http.Response.bytes(
              base64Decode(_pixel),
              200,
              headers: {'content-type': 'image/png'},
            ),
          );
        }
        controller.dispose();
        client.close();
      }
    },
    // The production signed-cover policy requires this host to be enabled in
    // the test build too: --dart-define=CONTENT_MEDIA_HOSTS=api.cloudinary.com.
    skip:
        AppConfig.contentMediaPolicy.sanitize(
          'https://api.cloudinary.com/v1_1/fixture/image/download',
        ) ==
        null,
  );
}

bool _hasCoverPixels(WidgetTester tester) {
  final images = find
      .descendant(
        of: find.byKey(const Key('games-featured-cover')),
        matching: find.byType(RawImage),
      )
      .evaluate();
  return images.any((element) => (element.widget as RawImage).image != null);
}
