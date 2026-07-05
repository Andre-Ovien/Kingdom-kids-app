import 'package:flutter/material.dart';

import '../features/auth/presentation/auth_screen.dart';
import '../features/games/domain/mini_game.dart';
import '../features/games/presentation/game_detail_screen.dart';
import '../features/bible/presentation/bible_screen.dart';
import '../features/games/presentation/games_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/parental_controls/presentation/parental_controls_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/streak/presentation/streak_screen.dart';
import '../features/stories/domain/story_detail.dart';
import '../features/stories/presentation/story_detail_screen.dart';
import '../features/stories/presentation/stories_screen.dart';
import '../features/videos/domain/video_story.dart';
import '../features/videos/presentation/video_watch_screen.dart';
import '../features/videos/presentation/videos_screen.dart';

class AppRoutes {
  const AppRoutes._();

  static const home = '/';
  static const streak = '/streak';
  static const onboarding = '/onboarding';
  static const stories = '/stories';
  static const videos = '/videos';
  static const videoDetail = '/videos/detail';
  static const games = '/games';
  static const gameDetail = '/games/detail';
  static const bible = '/bible';
  static const storyDetail = '/stories/detail';
  static const auth = '/auth';
  static const profile = '/profile';
  static const parentalControls = '/parental-controls';

  static const tabRoutes = [home, stories, videos, games, profile];

  static bool isTabRoute(String? route) {
    return route != null && tabRoutes.contains(route);
  }

  static int tabIndex(String route) {
    return tabRoutes.indexOf(route);
  }
}

class TabRouteTransition {
  const TabRouteTransition({required this.fromRoute});

  final String fromRoute;
}

class AppRouter {
  const AppRouter._();

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final tabTransition = settings.arguments is TabRouteTransition
        ? settings.arguments! as TabRouteTransition
        : null;
    final Widget screen = switch (settings.name) {
      AppRoutes.streak => const StreakScreen(),
      AppRoutes.onboarding => const OnboardingScreen(),
      AppRoutes.home => const HomeScreen(),
      AppRoutes.stories => const StoriesScreen(),
      AppRoutes.videos => const VideosScreen(),
      AppRoutes.videoDetail => VideoWatchScreen(
        video: settings.arguments is VideoStory
            ? settings.arguments! as VideoStory
            : VideoStory.fallback,
      ),
      AppRoutes.games => const GamesScreen(),
      AppRoutes.gameDetail => GameDetailScreen(
        game: settings.arguments is MiniGame
            ? settings.arguments! as MiniGame
            : MiniGame.fallback,
      ),
      AppRoutes.bible => const BibleScreen(),
      AppRoutes.storyDetail => StoryDetailScreen(
        story: settings.arguments is StoryDetail
            ? settings.arguments! as StoryDetail
            : StoryDetail.fallback,
      ),
      AppRoutes.auth => const AuthScreen(),
      AppRoutes.profile => const ProfileScreen(),
      AppRoutes.parentalControls => const ParentalControlsScreen(),
      _ => const HomeScreen(),
    };

    if (tabTransition != null && AppRoutes.isTabRoute(settings.name)) {
      return _tabRoute(
        screen: screen,
        settings: settings,
        transition: tabTransition,
      );
    }

    return MaterialPageRoute<void>(builder: (_) => screen, settings: settings);
  }

  static Route<dynamic> _tabRoute({
    required Widget screen,
    required RouteSettings settings,
    required TabRouteTransition transition,
  }) {
    final fromIndex = AppRoutes.tabIndex(transition.fromRoute);
    final toIndex = AppRoutes.tabIndex(settings.name ?? AppRoutes.home);
    final entersFromLeft =
        fromIndex != -1 && toIndex != -1 && toIndex < fromIndex;
    final beginOffset = Offset(entersFromLeft ? -1 : 1, 0);

    return PageRouteBuilder<void>(
      settings: settings,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => screen,
      transitionsBuilder: (context, animation, _, child) {
        final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
        final slide = Tween<Offset>(
          begin: beginOffset,
          end: Offset.zero,
        ).animate(curved);
        final fade = Tween<double>(begin: 0.94, end: 1).animate(curved);

        return SlideTransition(
          position: slide,
          child: FadeTransition(opacity: fade, child: child),
        );
      },
    );
  }
}
