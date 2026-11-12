import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../shared/widgets/scoped_feature_page.dart';
import '../core/network/feature_view_state_cache.dart';

import '../features/auth/presentation/auth_screen.dart';
import '../features/auth/domain/email_verification.dart';
import '../features/auth/domain/kid_profile.dart';
import '../features/auth/presentation/adult_gate.dart';
import '../features/auth/presentation/email_verification_screen.dart';
import '../features/auth/presentation/kid_profile_setup_screen.dart';
import '../features/auth/presentation/password_reset_screen.dart';
import '../features/auth/presentation/profile_picker_screen.dart';
import '../features/games/domain/mini_game.dart';
import '../features/games/presentation/game_detail_screen.dart';
import '../features/bible/presentation/bible_screen.dart';
import '../features/games/presentation/games_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/milestones/domain/level_milestone.dart';
import '../features/milestones/presentation/level_milestone_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/parental_controls/presentation/parental_controls_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/splash/data/startup_destination_resolver.dart';
import '../features/splash/presentation/splash_screen.dart';
import '../features/streak/presentation/streak_screen.dart';
import '../features/streak/domain/streak_presentation.dart';
import '../features/stories/domain/story_detail.dart';
import '../features/stories/domain/story_read_along_arguments.dart';
import '../features/stories/domain/story_reading_arguments.dart';
import '../features/stories/presentation/read_along_screen.dart';
import '../features/stories/presentation/story_detail_screen.dart';
import '../features/stories/presentation/stories_screen.dart';
import '../features/subscription/data/subscription_review_launch.dart';
import '../features/subscription/presentation/subscription_review_screen.dart';
import '../features/subscription/presentation/subscription_parent_screen.dart';
import '../features/subscription/presentation/subscription_screen.dart';
import '../features/subscription/presentation/hosted_paid_route_boundary.dart';
import '../features/privacy/presentation/privacy_policy_screen.dart';
import '../features/videos/domain/video_story.dart';
import '../features/videos/presentation/video_watch_screen.dart';
import '../features/videos/presentation/videos_screen.dart';

class AppRoutes {
  const AppRoutes._();

  static const home = '/';
  static const splash = '/splash';
  static const streak = '/streak';
  static const levelMilestone = '/milestones/level';
  static const onboarding = '/onboarding';
  static const stories = '/stories';
  static const videos = '/videos';
  static const videoDetail = '/videos/detail';
  static const games = '/games';
  static const gameDetail = '/games/detail';
  static const bible = '/bible';
  static const storyDetail = '/stories/detail';
  static const storyReadAlong = '/stories/read-along';
  static const auth = '/auth';
  static const login = '/auth/login';
  static const register = '/auth/register';
  static const emailVerification = '/auth/verify-email';
  static const passwordReset = '/auth/password-reset';
  static const kidProfileSetup = '/auth/kid-profile';
  static const profilePicker = '/auth/profiles';
  static const profile = '/profile';
  static const parentalControls = '/parental-controls';
  static const subscription = '/parent/subscription';
  static const subscriptionRequired = '/parent/subscription-required';
  static const privacy = '/privacy';
  static const subscriptionReview = '/dev/subscription-review';

  static const tabRoutes = [home, stories, videos, games, profile];

  static bool isTabRoute(String? route) {
    return route != null && tabRoutes.contains(route);
  }

  static int tabIndex(String route) {
    return tabRoutes.indexOf(route);
  }
}

class TabRouteTransition {
  const TabRouteTransition({required this.fromRoute, this.preparation});

  final String fromRoute;
  final FeaturePagePreparation? preparation;
}

class AppRouter {
  const AppRouter._();

  static Route<dynamic> onGenerateRoute(
    RouteSettings settings, {
    SplashDestinationResolver? splashDestinationResolver,
    SplashVideoControllerFactory? splashVideoControllerFactory,
  }) {
    final tabTransition = settings.arguments is TabRouteTransition
        ? settings.arguments! as TabRouteTransition
        : null;
    final Widget destination = switch (settings.name) {
      AppRoutes.splash => SplashScreen(
        destinationResolver:
            splashDestinationResolver ??
            SubscriptionReviewDestinationResolver(),
        videoControllerFactory: splashVideoControllerFactory,
      ),
      AppRoutes.streak =>
        settings.arguments is StreakPresentation
            ? StreakScreen(
                presentation: settings.arguments! as StreakPresentation,
              )
            : const HomeScreen(),
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
      AppRoutes.levelMilestone =>
        settings.arguments is LevelMilestonePresentation
            ? LevelMilestoneScreen(
                profile:
                    (settings.arguments! as LevelMilestonePresentation).profile,
                level: (settings.arguments! as LevelMilestonePresentation)
                    .milestone
                    .level
                    .number,
                levelTitle: (settings.arguments! as LevelMilestonePresentation)
                    .milestone
                    .level
                    .title,
              )
            : const HomeScreen(),
      AppRoutes.gameDetail =>
        settings.arguments is MiniGame
            ? GameDetailScreen(game: settings.arguments! as MiniGame)
            : const GamesScreen(),
      AppRoutes.bible => const BibleScreen(),
      AppRoutes.storyDetail => StoryDetailScreen(
        story: settings.arguments is StoryReadingArguments
            ? (settings.arguments! as StoryReadingArguments).story
            : settings.arguments is StoryDetail
            ? settings.arguments! as StoryDetail
            : StoryDetail.fallback,
        resumeReading:
            settings.arguments is StoryReadingArguments &&
            (settings.arguments! as StoryReadingArguments).resumeReading,
      ),
      AppRoutes.storyReadAlong => ReadAlongScreen(
        story: settings.arguments is StoryReadAlongArguments
            ? (settings.arguments! as StoryReadAlongArguments).story
            : settings.arguments is StoryDetail
            ? settings.arguments! as StoryDetail
            : StoryDetail.unavailable,
        resumeReading:
            settings.arguments is StoryReadAlongArguments &&
            (settings.arguments! as StoryReadAlongArguments).resumeReading,
      ),
      AppRoutes.auth => const AuthScreen(),
      AppRoutes.login => const AuthScreen(initialMode: AuthScreenMode.login),
      AppRoutes.register => const AuthScreen(
        initialMode: AuthScreenMode.register,
      ),
      AppRoutes.emailVerification =>
        settings.arguments is PendingEmailVerification
            ? EmailVerificationScreen(
                pending: settings.arguments! as PendingEmailVerification,
              )
            : const AuthScreen(initialMode: AuthScreenMode.register),
      AppRoutes.passwordReset => const PasswordResetScreen(),
      AppRoutes.kidProfileSetup => KidProfileSetupScreen(
        existingProfiles: _profileArguments(settings.arguments),
      ),
      AppRoutes.profilePicker => ProfilePickerScreen(
        initialProfiles: _profileArguments(settings.arguments),
      ),
      AppRoutes.profile => const ProfileScreen(),
      AppRoutes.parentalControls => AdultGate(
        title: 'Parent settings',
        reason: 'Enter the parent password to open parent settings.',
        protectedBuilder: (_) => const ParentalControlsScreen(),
      ),
      AppRoutes.subscription => const SubscriptionParentScreen(),
      AppRoutes.subscriptionRequired => const SubscriptionParentScreen(),
      AppRoutes.privacy => const PrivacyPolicyScreen(),
      AppRoutes.subscriptionReview =>
        !kReleaseMode &&
                subscriptionReviewBuildId.isNotEmpty &&
                settings.arguments is SubscriptionReviewArguments &&
                (settings.arguments! as SubscriptionReviewArguments).reviewId ==
                    subscriptionReviewBuildId
            ? SubscriptionReviewScreen(
                arguments: settings.arguments! as SubscriptionReviewArguments,
              )
            : AdultGate(
                title: 'Subscription plans',
                reason: 'Enter the parent password to view subscription plans.',
                protectedBuilder: (_) => const SubscriptionScreen(),
              ),
      _ => const HomeScreen(),
    };

    final detailKey = switch (destination) {
      GameDetailScreen(:final game) => '${AppRoutes.gameDetail}/${game.slug}',
      StoryDetailScreen(:final story) =>
        '${AppRoutes.storyDetail}/${story.slug}',
      ReadAlongScreen(:final story) =>
        '${AppRoutes.storyReadAlong}/${story.slug}',
      _ => null,
    };
    final featureScreen = AppRoutes.isTabRoute(settings.name)
        ? ScopedFeaturePage(
            route: settings.name!,
            preparation: tabTransition?.preparation,
            child: destination,
          )
        : detailKey != null
        ? ScopedFeaturePage(
            route: detailKey,
            identityBound: true,
            child: destination,
          )
        : destination;

    const publicRoutes = {
      AppRoutes.splash,
      AppRoutes.onboarding,
      AppRoutes.auth,
      AppRoutes.login,
      AppRoutes.register,
      AppRoutes.emailVerification,
      AppRoutes.passwordReset,
      AppRoutes.subscription,
      AppRoutes.subscriptionRequired,
      AppRoutes.privacy,
    };
    final screen = publicRoutes.contains(settings.name)
        ? featureScreen
        : HostedPaidRouteBoundary(
            childContext: !const {
              AppRoutes.profilePicker,
              AppRoutes.kidProfileSetup,
              AppRoutes.parentalControls,
            }.contains(settings.name),
            child: featureScreen,
          );

    if (tabTransition != null && AppRoutes.isTabRoute(settings.name)) {
      return TabGlideRoute(
        builder: (_) => screen,
        settings: settings,
        fromRoute: tabTransition.fromRoute,
      );
    }

    return MaterialPageRoute<void>(builder: (_) => screen, settings: settings);
  }

  static List<KidProfile> _profileArguments(Object? arguments) {
    if (arguments is List<KidProfile>) {
      return arguments;
    }
    if (arguments is List) {
      return arguments.whereType<KidProfile>().toList(growable: false);
    }
    return const [];
  }
}

/// Full pages move together underneath the separately mounted navigation bar.
/// Delegating the outgoing slide also covers the first Home route, which still
/// uses its ordinary MaterialPageRoute for normal app startup.
class TabGlideRoute extends MaterialPageRoute<void> {
  TabGlideRoute({
    required super.builder,
    required RouteSettings settings,
    required String fromRoute,
  }) : _direction =
           AppRoutes.tabIndex(settings.name ?? AppRoutes.home) >=
               AppRoutes.tabIndex(fromRoute)
           ? 1.0
           : -1.0,
       super(settings: settings);

  static const glideDuration = Duration(milliseconds: 340);
  final double _direction;

  bool get _reducedMotion {
    final media = navigator?.context
        .getInheritedWidgetOfExactType<MediaQuery>()
        ?.data;
    return media?.disableAnimations == true ||
        media?.accessibleNavigation == true;
  }

  @override
  Duration get transitionDuration =>
      _reducedMotion ? Duration.zero : glideDuration;

  @override
  Duration get reverseTransitionDuration =>
      _reducedMotion ? Duration.zero : glideDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _slidePrevious;

  Widget _slidePrevious(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (child == null) return const SizedBox.shrink();
    if (_reduceMotionIn(context)) return child;
    return ClipRect(
      child: SlideTransition(
        position: secondaryAnimation
            .drive(CurveTween(curve: Curves.easeOutCubic))
            .drive(
              Tween<Offset>(begin: Offset.zero, end: Offset(-_direction, 0)),
            ),
        child: child,
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_reduceMotionIn(context)) return child;
    return ClipRect(
      child: SlideTransition(
        position: animation
            .drive(CurveTween(curve: Curves.easeOutCubic))
            .drive(
              Tween<Offset>(begin: Offset(_direction, 0), end: Offset.zero),
            ),
        child: IgnorePointer(
          ignoring: animation.status != AnimationStatus.completed,
          child: child,
        ),
      ),
    );
  }
}

bool _reduceMotionIn(BuildContext context) {
  final media = MediaQuery.of(context);
  return media.disableAnimations || media.accessibleNavigation;
}
