import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/app/app.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/shared/audio/app_audio_controller.dart';
import 'package:mobile/shared/audio/app_sound_cue.dart';

void main() {
  test('tab routes glide while detail routes keep platform transitions', () {
    final tabRoute = AppRouter.onGenerateRoute(
      const RouteSettings(
        name: AppRoutes.stories,
        arguments: TabRouteTransition(fromRoute: AppRoutes.home),
      ),
    );
    final detailRoute = AppRouter.onGenerateRoute(
      const RouteSettings(name: AppRoutes.storyDetail),
    );
    final readAlongRoute = AppRouter.onGenerateRoute(
      const RouteSettings(name: AppRoutes.storyReadAlong),
    );

    final tabTransition = tabRoute as TransitionRoute<dynamic>;
    expect(tabTransition.transitionDuration, TabGlideRoute.glideDuration);
    expect(
      tabTransition.reverseTransitionDuration,
      TabGlideRoute.glideDuration,
    );
    expect(detailRoute, isA<MaterialPageRoute<void>>());
    expect(readAlongRoute, isA<MaterialPageRoute<void>>());
  });

  Future<void> enterHome(WidgetTester tester) async {
    await tester.pumpWidget(const KingdomKidsApp(initialRoute: AppRoutes.home));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('does not invent a streak presentation for a direct route', (
    tester,
  ) async {
    await tester.pumpWidget(
      const KingdomKidsApp(initialRoute: AppRoutes.streak),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('streak-screen')), findsNothing);
    expect(find.text('Hey, explorer!'), findsOneWidget);
  });

  testWidgets('shows the Kingdom Kids home shell', (tester) async {
    await enterHome(tester);

    expect(find.text('Hey, explorer!'), findsOneWidget);
    expect(find.text('Pick your adventure'), findsOneWidget);
    expect(find.text('Stories'), findsWidgets);
    expect(find.text('Watch'), findsNothing);
    expect(find.text('Games'), findsWidgets);
  });

  testWidgets('opens the backend-driven game room shell', (tester) async {
    await enterHome(tester);

    await tester.tap(find.text('Games').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Ready to play?'), findsOneWidget);
    expect(find.byKey(const Key('games-header-icon')), findsOneWidget);
    expect(find.byKey(const Key('game-search-field')), findsOneWidget);
    expect(find.text('Quick Bible Games'), findsNothing);
  });

  testWidgets('the app controller does not request a tab selection sound', (
    tester,
  ) async {
    final audio = _TabAudio();
    addTearDown(audio.dispose);
    await tester.pumpWidget(
      KingdomKidsApp(initialRoute: AppRoutes.home, audioController: audio),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Games').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(audio.cues.where((cue) => cue == AppSoundCue.select), isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(audio.cues.where((cue) => cue == AppSoundCue.select), isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _TabAudio extends AppAudioController {
  final cues = <AppSoundCue>[];

  @override
  void playEffect(AppSoundCue cue) => cues.add(cue);
}
