import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../app/router.dart';
import '../data/startup_destination_resolver.dart';

const kingdomKidsSplashVideoAsset = 'assets/videos/kingdom-kids-splash-v2.mp4';
const kingdomKidsSplashPosterAsset =
    'assets/images/splash/static-periwinkle-title-v3.png';
const kingdomKidsSplashBackgroundColor = Color(0xFFA8C0F0);

abstract interface class SplashVideoController {
  Future<void> initialize();

  Future<void> play();

  bool get isInitialized;

  double get aspectRatio;

  Widget buildView();

  Future<void> dispose();
}

typedef SplashVideoControllerFactory = SplashVideoController Function();

class AssetSplashVideoController implements SplashVideoController {
  AssetSplashVideoController({String assetPath = kingdomKidsSplashVideoAsset})
    : _controller = VideoPlayerController.asset(
        assetPath,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

  final VideoPlayerController _controller;

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  double get aspectRatio {
    final ratio = _controller.value.aspectRatio;
    return ratio.isFinite && ratio > 0 ? ratio : 9 / 16;
  }

  @override
  Future<void> initialize() async {
    await _controller.initialize();
    await _controller.setLooping(false);
    await _controller.setVolume(0);
  }

  @override
  Future<void> play() => _controller.play();

  @override
  Widget buildView() => VideoPlayer(_controller);

  @override
  Future<void> dispose() => _controller.dispose();
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.destinationResolver,
    this.videoControllerFactory,
    this.displayDuration = const Duration(seconds: 6),
    this.returningDisplayDuration = const Duration(milliseconds: 1800),
    this.reducedMotionDisplayDuration = const Duration(milliseconds: 900),
    this.videoInitializationTimeout = const Duration(milliseconds: 1200),
  });

  final SplashDestinationResolver destinationResolver;
  final SplashVideoControllerFactory? videoControllerFactory;

  /// Full arrival reserved for a true first-launch onboarding.
  final Duration displayDuration;

  /// Short branded arrival used for every returning startup destination.
  final Duration returningDisplayDuration;

  final Duration reducedMotionDisplayDuration;
  final Duration videoInitializationTimeout;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  SplashVideoController? _videoController;
  bool _started = false;
  bool _videoReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    unawaited(_runSplash(reduceMotion: reduceMotion));
  }

  Future<void> _runSplash({required bool reduceMotion}) async {
    final shortDisplayDuration = reduceMotion
        ? widget.reducedMotionDisplayDuration
        : widget.returningDisplayDuration;
    final shortDisplayFuture = Future<void>.delayed(shortDisplayDuration);
    final posterDisplayCompleter = Completer<void>();
    final posterDisplayTimer = Timer(
      widget.displayDuration,
      posterDisplayCompleter.complete,
    );

    try {
      final destination = await _resolveDestination();

      if (reduceMotion || destination.route != AppRoutes.onboarding) {
        posterDisplayTimer.cancel();
        await shortDisplayFuture;
        _openDestination(destination);
        return;
      }

      // Poster failures still leave first-time families with the complete
      // branded arrival, counted from splash entry. A successfully started
      // video receives its full playback window so initialization never trims
      // the cinematic.
      final videoStarted = await _prepareVideo();
      if (videoStarted) {
        posterDisplayTimer.cancel();
        await Future<void>.delayed(widget.displayDuration);
      } else {
        await posterDisplayCompleter.future;
      }
      _openDestination(destination);
    } finally {
      posterDisplayTimer.cancel();
    }
  }

  Future<StartupDestination> _resolveDestination() async {
    try {
      // This screen owns the minimum branded display, not an authentication
      // deadline. The resolver's bounded access request can safely choose plans
      // on an outage after restoring the parent; timing it out here would turn
      // that valid saved session into a misleading sign-in screen.
      return await widget.destinationResolver.resolve();
    } catch (_) {
      return const StartupDestination(AppRoutes.login);
    }
  }

  void _openDestination(StartupDestination destination) {
    if (!mounted) {
      return;
    }
    unawaited(
      Navigator.of(context).pushNamedAndRemoveUntil(
        destination.route,
        (_) => false,
        arguments: destination.arguments,
      ),
    );
  }

  Future<bool> _prepareVideo() async {
    // The static title artwork is the production default. A supplied
    // controller keeps older cinematics available for explicit previews.
    final factory = widget.videoControllerFactory;
    if (factory == null) {
      return false;
    }
    SplashVideoController? controller;
    try {
      final candidate = factory();
      controller = candidate;
      _videoController = candidate;
      await (() async {
        await candidate.initialize();
        if (!candidate.isInitialized) {
          return;
        }
        await candidate.play();
      })().timeout(widget.videoInitializationTimeout);
      if (!mounted || !candidate.isInitialized) {
        return false;
      }
      if (mounted) {
        setState(() => _videoReady = true);
        return true;
      }
      return false;
    } catch (_) {
      if (identical(_videoController, controller)) {
        _videoController = null;
      }
      if (controller != null) {
        unawaited(controller.dispose());
      }
      // The illustrated brand scene beneath the player is the intentional
      // offline/missing-asset fallback, so video failures need no error UI.
      return false;
    }
  }

  @override
  void dispose() {
    final controller = _videoController;
    _videoController = null;
    if (controller != null) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: PopScope(
        canPop: false,
        child: Scaffold(
          key: const Key('cinematic-splash-screen'),
          backgroundColor: kingdomKidsSplashBackgroundColor,
          body: Semantics(
            container: true,
            label: 'Kingdom Kids',
            child: Stack(
              fit: StackFit.expand,
              children: [
                const _ApprovedSplashScene(key: Key('splash-static-fallback')),
                if (_videoReady &&
                    controller != null &&
                    controller.isInitialized)
                  ExcludeSemantics(child: _CoverVideo(controller: controller)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The approved wordmark is one static asset. A centered cover fit preserves
/// its proportions and keeps the complete title visible on short phones.
class _ApprovedSplashScene extends StatelessWidget {
  const _ApprovedSplashScene({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const Key('splash-composition-canvas'),
      color: kingdomKidsSplashBackgroundColor,
      child: Image.asset(
        kingdomKidsSplashPosterAsset,
        key: const Key('splash-poster-image'),
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => const SizedBox.expand(),
      ),
    );
  }
}

class _CoverVideo extends StatelessWidget {
  const _CoverVideo({required this.controller});

  final SplashVideoController controller;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFBFE8F2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: controller.aspectRatio * constraints.maxHeight,
              height: constraints.maxHeight,
              child: controller.buildView(),
            ),
          );
        },
      ),
    );
  }
}
