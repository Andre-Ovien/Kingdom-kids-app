import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../../milestones/data/level_milestone_store.dart';
import '../../milestones/domain/level_milestone.dart';
import '../../milestones/presentation/level_milestone_presenter.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';
import 'david_sling_engine.dart';
import 'game_cover_image.dart';
import 'game_engines.dart';
import 'game_level_completion.dart';
import 'puzzle_quest_completion.dart';
import 'red_sea_crossing_engine.dart';
import 'storm_sailing_engine.dart';

class GamePlayScreen extends StatefulWidget {
  const GamePlayScreen({
    required this.game,
    required this.profile,
    required this.repository,
    super.key,
    this.startingLevel,
    this.authRepository,
    this.milestoneStore,
  });

  final MiniGame game;
  final KidProfile profile;
  final GameRepository repository;
  final AuthRepository? authRepository;
  final LevelMilestoneStore? milestoneStore;
  final int? startingLevel;

  @override
  State<GamePlayScreen> createState() => _GamePlayScreenState();
}

enum _PlayPhase { intro, playing, result }

class _GamePlayScreenState extends State<GamePlayScreen>
    with WidgetsBindingObserver {
  late int _levelIndex;
  _PlayPhase _phase = _PlayPhase.intro;
  GameSubmission? _submission;
  Map<String, dynamic>? _pendingResult;
  String? _operationId;
  String? _submitError;
  bool _canRetrySave = false;
  bool _submitting = false;
  bool _allowExit = false;
  bool _exitPromptOpen = false;
  bool _foreground = true;
  bool _immersive = false;
  int _attempt = 0;
  late final AuthRepository _authRepository;
  late final LevelMilestoneStore _milestoneStore;
  late final LevelMilestonePresenter _milestonePresenter;
  LevelMilestone? _pendingMilestone;
  bool _presentingMilestone = false;

  List<GameLevel> get _levels => widget.game.levels;
  GameLevel get _level => _levels[_levelIndex];
  bool get _isDavid => widget.game.gameType == GameType.aim;
  bool get _isSailing =>
      _levels.isNotEmpty &&
      widget.game.gameType == GameType.maze &&
      _level.config['sailing'] is Map;
  bool get _isCrossing =>
      _levels.isNotEmpty &&
      widget.game.gameType == GameType.path &&
      _level.config['crossing'] is Map;
  bool get _isBlenderActivity =>
      _levels.isNotEmpty &&
      ((widget.game.gameType == GameType.matching &&
              {'ark_traffic', 'ark_garden'}.contains(_level.config['mode'])) ||
          (widget.game.gameType == GameType.ordering &&
              {
                'living_world',
                'wise_builders',
              }.contains(_level.config['mode'])));
  bool get _isMatchingStudio =>
      _levels.isNotEmpty &&
      widget.game.gameType == GameType.matching &&
      {
        'coat_studio',
        'harvest_chain',
        'sheep_reunion',
        'creation_bloom',
        'esther_table',
      }.contains(_level.config['mode']);
  bool get _isFullScreenGame =>
      _isDavid ||
      _isSailing ||
      _isCrossing ||
      _isBlenderActivity ||
      _isMatchingStudio;
  bool get _opensDirectly =>
      _isFullScreenGame || widget.game.gameType == GameType.puzzle;

  void _setImmersiveGame(bool immersive) {
    _immersive = immersive;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
  }

  void _syncImmersiveGame() {
    final immersive =
        _isFullScreenGame &&
        _foreground &&
        !_presentingMilestone &&
        ModalRoute.of(context)?.isCurrent == true;
    if (_immersive != immersive) _setImmersiveGame(immersive);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncImmersiveGame();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground != foreground && mounted) {
      setState(() => _foreground = foreground);
    }
    _syncImmersiveGame();
    if (state == AppLifecycleState.resumed) {
      unawaited(_presentMilestone());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_immersive) {
      _setImmersiveGame(false);
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _milestoneStore = widget.milestoneStore ?? SecureLevelMilestoneStore();
    _milestonePresenter = LevelMilestonePresenter(
      authRepository: _authRepository,
      store: _milestoneStore,
    );
    WidgetsBinding.instance.addObserver(this);
    final wanted =
        widget.startingLevel ??
        (widget.game.playerProgress.isComplete
            ? 1
            : widget.game.playerProgress.currentLevel);
    final found = _levels.indexWhere((level) => level.number == wanted);
    _levelIndex = found < 0 ? 0 : found;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_isMatchingStudio) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]),
      );
    }
    if (_isFullScreenGame) {
      _setImmersiveGame(true);
    }
    if (_opensDirectly) {
      // Picture puzzles own their ready stage; full-screen games open directly.
      _phase = _PlayPhase.playing;
    }
  }

  void _begin() {
    if (_levels.isEmpty) return;
    setState(() {
      _phase = _PlayPhase.playing;
      _submission = null;
      _pendingResult = null;
      _operationId = null;
      _submitError = null;
      _canRetrySave = false;
      _submitting = false;
      _attempt += 1;
    });
  }

  Future<void> _submit(Map<String, dynamic> result) async {
    if (_submitting || _submission != null) return;
    _pendingResult ??= result;
    _operationId ??= _newOperationId();
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final submission = await widget.repository.submitResult(
        slug: widget.game.slug,
        profileId: widget.profile.id,
        levelNumber: _level.number,
        operationId: _operationId!,
        result: _pendingResult!,
      );
      if (!mounted) return;
      setState(() {
        _submission = submission;
        _phase = _PlayPhase.result;
      });
      _pendingMilestone = submission.levelMilestone;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_presentMilestone());
      });
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) {
        final status = error.statusCode;
        final isRejectedResult =
            status != null && status >= 400 && status < 500;
        setState(() {
          _submitError = error.userMessage;
          _canRetrySave = !isRejectedResult;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitError =
              'Your answer is safe here, but we could not save it yet.';
          _canRetrySave = true;
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  bool get _canPresentMilestone {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        !_allowExit &&
        !_exitPromptOpen &&
        ModalRoute.of(context)?.isCurrent == true &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  Future<void> _presentMilestone() async {
    final milestone = _pendingMilestone;
    if (milestone == null ||
        !milestone.isLevelUp ||
        _presentingMilestone ||
        !_canPresentMilestone) {
      return;
    }
    _presentingMilestone = true;
    try {
      final result = await _milestonePresenter.present(
        context,
        profileId: widget.profile.id,
        milestone: milestone,
        canPresent: () => _canPresentMilestone,
        beforePresent: () {
          if (_isFullScreenGame) _setImmersiveGame(false);
        },
        afterPresent: () {
          if (_isFullScreenGame && _canPresentMilestone) {
            _setImmersiveGame(true);
          }
        },
      );
      if (result != LevelMilestonePresentationResult.deferred &&
          identical(_pendingMilestone, milestone)) {
        _pendingMilestone = null;
      }
    } finally {
      _presentingMilestone = false;
    }
  }

  String _newOperationId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  void _tryLevelAgain() {
    setState(() {
      _phase = _opensDirectly ? _PlayPhase.playing : _PlayPhase.intro;
      _submission = null;
      _pendingResult = null;
      _operationId = null;
      _submitError = null;
      _canRetrySave = false;
      if (_opensDirectly) _attempt += 1;
    });
  }

  void _redoAfterSaveFailure() {
    setState(() {
      _phase = _PlayPhase.playing;
      _submission = null;
      _pendingResult = null;
      _operationId = null;
      _submitError = null;
      _canRetrySave = false;
      _submitting = false;
      _attempt += 1;
    });
  }

  void _nextLevel() {
    if (_pendingMilestone != null || _presentingMilestone) {
      unawaited(_presentMilestone());
      return;
    }
    if (_levelIndex >= _levels.length - 1) return;
    setState(() {
      _levelIndex += 1;
      _phase = _opensDirectly ? _PlayPhase.playing : _PlayPhase.intro;
      _submission = null;
      _pendingResult = null;
      _operationId = null;
      _submitError = null;
      _canRetrySave = false;
    });
    _syncImmersiveGame();
  }

  void _popWithResult(bool changed) {
    if (!mounted || _allowExit) return;
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(changed);
    });
  }

  Future<void> _requestExit() async {
    // Keep a finished round here until its server receipt determines whether
    // the caller must refresh progress. Its save overlay remains visible.
    if (_exitPromptOpen ||
        ((_isSailing ||
                _isCrossing ||
                _isBlenderActivity ||
                _isMatchingStudio) &&
            _submitting)) {
      return;
    }
    if (_pendingMilestone != null || _presentingMilestone) {
      await _presentMilestone();
      if (!mounted || _presentingMilestone) return;
    }
    if (_phase == _PlayPhase.result || _submission != null) {
      _popWithResult(true);
      return;
    }
    if (_phase != _PlayPhase.playing) {
      _popWithResult(false);
      return;
    }
    if (_isFullScreenGame) setState(() => _exitPromptOpen = true);
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('game-exit-dialog'),
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        iconPadding: const EdgeInsets.fromLTRB(24, 28, 24, 18),
        icon: Icon(
          Icons.sentiment_dissatisfied_rounded,
          key: const Key('game-exit-sad-face'),
          size: 76,
          color: Theme.of(context).colorScheme.primary,
        ),
        titlePadding: const EdgeInsets.symmetric(horizontal: 24),
        title: Text(
          _isDavid
              ? 'Leave the battlefield?'
              : _isSailing
              ? 'Leave this voyage?'
              : _isCrossing
              ? 'Leave this crossing?'
              : 'Leave this level?',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.2,
          ),
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        content: const Text(
          'This try has not been saved yet. You can come back and play again.',
          textAlign: TextAlign.center,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        actions: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const Key('game-exit-keep-playing'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep playing', textAlign: TextAlign.center),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('game-exit-leave'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  foregroundColor: Theme.of(context).colorScheme.error,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.error,
                    width: 2,
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Leave', textAlign: TextAlign.center),
              ),
            ],
          ),
        ],
      ),
    );
    if (mounted && _isFullScreenGame && leave != true) {
      setState(() => _exitPromptOpen = false);
    }
    if (leave == true && mounted) {
      _popWithResult(_submission != null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(widget.game);
    if (_levels.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.game.title)),
        body: _NoPlayableLevels(onExit: () => Navigator.of(context).pop()),
      );
    }
    final showCelebration =
        _phase == _PlayPhase.result && _submission?.completed == true;

    return PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_phase == _PlayPhase.result) {
          _popWithResult(true);
        } else {
          _requestExit();
        }
      },
      child: Scaffold(
        backgroundColor: _pageBackground(context),
        body: Stack(
          children: [
            if (!showCelebration && !_isFullScreenGame)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _PlayBackdropPainter(accent: accent),
                  ),
                ),
              ),
            if (showCelebration)
              Positioned.fill(
                child: widget.game.gameType == GameType.puzzle
                    ? PuzzleQuestCompletion(
                        key: ValueKey(
                          'puzzle-result-${_submission!.operationId}',
                        ),
                        game: widget.game,
                        profile: widget.profile,
                        submission: _submission!,
                        result: _pendingResult,
                        onNext: _levelIndex == _levels.length - 1
                            ? null
                            : _nextLevel,
                        onFinish: () => _popWithResult(true),
                      )
                    : GameLevelCompletion(
                        key: ValueKey(
                          'game-result-${_submission!.operationId}',
                        ),
                        game: widget.game,
                        profile: widget.profile,
                        submission: _submission!,
                        onNext: _levelIndex == _levels.length - 1
                            ? null
                            : _nextLevel,
                        onFinish: () => _popWithResult(true),
                      ),
              )
            else if (_isFullScreenGame)
              Positioned.fill(
                child: _phase == _PlayPhase.result
                    ? ColoredBox(
                        color: const Color(0xFFFFF4DD),
                        child: SafeArea(
                          child: _LevelFailureResult(
                            key: ValueKey(
                              'battle-result-${_submission?.operationId}',
                            ),
                            game: widget.game,
                            submission: _submission!,
                            onRetry: _tryLevelAgain,
                            onExit: () => _popWithResult(true),
                          ),
                        ),
                      )
                    : _isBlenderActivity || _isMatchingStudio
                    ? _BlenderActivityLevel(
                        key: ValueKey(
                          'activity-${widget.game.slug}-${_level.number}-$_attempt',
                        ),
                        type: widget.game.gameType,
                        level: _level,
                        paused:
                            _exitPromptOpen ||
                            _allowExit ||
                            !_foreground ||
                            ModalRoute.of(context)?.isCurrent != true,
                        onExit: _requestExit,
                        submitting: _submitting,
                        error: _submitError,
                        onComplete: _submit,
                        onRetrySubmit: !_canRetrySave || _pendingResult == null
                            ? null
                            : () => _submit(_pendingResult!),
                        onRedo: _redoAfterSaveFailure,
                      )
                    : _isSailing || _isCrossing
                    ? _JourneyLevel(
                        key: ValueKey(
                          '${_isCrossing ? 'crossing' : 'sailing'}-${_level.number}-$_attempt',
                        ),
                        crossing: _isCrossing,
                        level: _level,
                        paused:
                            _exitPromptOpen ||
                            _allowExit ||
                            !_foreground ||
                            ModalRoute.of(context)?.isCurrent != true,
                        onExit: _requestExit,
                        submitting: _submitting,
                        error: _submitError,
                        onComplete: _submit,
                        onRetrySubmit: !_canRetrySave || _pendingResult == null
                            ? null
                            : () => _submit(_pendingResult!),
                        onRedo: _redoAfterSaveFailure,
                      )
                    : _DavidBattleLevel(
                        key: ValueKey('battle-${_level.number}-$_attempt'),
                        level: _level,
                        paused: _exitPromptOpen,
                        onExit: _requestExit,
                        submitting: _submitting,
                        error: _submitError,
                        onComplete: _submit,
                        onRetrySubmit: !_canRetrySave || _pendingResult == null
                            ? null
                            : () => _submit(_pendingResult!),
                        onRedo: _redoAfterSaveFailure,
                      ),
              )
            else
              SafeArea(
                child: Column(
                  children: [
                    _PlayTopBar(
                      game: widget.game,
                      profile: widget.profile,
                      level: _level,
                      currentIndex: _levelIndex + 1,
                      total: _levels.length,
                      onExit: _requestExit,
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        switchInCurve: Curves.easeOutBack,
                        switchOutCurve: Curves.easeInCubic,
                        child: switch (_phase) {
                          _PlayPhase.intro => _LevelIntro(
                            key: ValueKey('intro-${_level.number}-$_attempt'),
                            game: widget.game,
                            level: _level,
                            profile: widget.profile,
                            onStart: _begin,
                          ),
                          _PlayPhase.playing => _PlayingLevel(
                            key: ValueKey('play-${_level.number}-$_attempt'),
                            game: widget.game,
                            level: _level,
                            submitting: _submitting,
                            error: _submitError,
                            onComplete: _submit,
                            onRetrySubmit:
                                !_canRetrySave || _pendingResult == null
                                ? null
                                : () => _submit(_pendingResult!),
                            onRedo: _redoAfterSaveFailure,
                          ),
                          _PlayPhase.result => _LevelFailureResult(
                            key: ValueKey(
                              'result-${_submission?.operationId ?? _level.number}',
                            ),
                            game: widget.game,
                            submission: _submission!,
                            onRetry: _tryLevelAgain,
                            onExit: () => _popWithResult(true),
                          ),
                        },
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlayTopBar extends StatelessWidget {
  const _PlayTopBar({
    required this.game,
    required this.profile,
    required this.level,
    required this.currentIndex,
    required this.total,
    required this.onExit,
  });

  final MiniGame game;
  final KidProfile profile;
  final GameLevel level;
  final int currentIndex;
  final int total;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(game);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.8;
          final progress = ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              key: const Key('game-level-progress'),
              value: currentIndex / total,
              minHeight: 7,
              backgroundColor: accent.withValues(alpha: 0.13),
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          );
          final levelLabel = Text(
            'Level ${level.number} of $total',
            maxLines: largeText ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w900),
          );
          final profileLabel = Text(
            profile.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          );
          final exit = IconButton.filledTonal(
            key: const Key('game-exit'),
            tooltip: 'Leave game',
            onPressed: onExit,
            icon: const Icon(Icons.close_rounded),
          );
          if (largeText || constraints.maxWidth < 340) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    exit,
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [levelLabel, profileLabel],
                      ),
                    ),
                    const SizedBox(width: 8),
                    KidProfileAvatar(profile: profile, size: 38),
                  ],
                ),
                const SizedBox(height: 8),
                progress,
              ],
            );
          }
          return Row(
            children: [
              exit,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: levelLabel),
                        profileLabel,
                      ],
                    ),
                    const SizedBox(height: 5),
                    progress,
                  ],
                ),
              ),
              const SizedBox(width: 10),
              KidProfileAvatar(profile: profile, size: 42),
            ],
          );
        },
      ),
    );
  }
}

class _LevelIntro extends StatelessWidget {
  const _LevelIntro({
    required this.game,
    required this.level,
    required this.profile,
    required this.onStart,
    super.key,
  });

  final MiniGame game;
  final GameLevel level;
  final KidProfile profile;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(game);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 30),
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 680),
        curve: Curves.easeOutBack,
        tween: Tween(begin: 0.72, end: 1),
        builder: (context, value, child) => Transform.scale(
          scale: value,
          child: Opacity(opacity: value.clamp(0, 1), child: child),
        ),
        child: Column(
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.22),
                    blurRadius: 38,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Icon(gameIcon(game), color: accent, size: 58),
            ),
            const SizedBox(height: 25),
            Text(
              'Ready, ${profile.displayName}?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: _accentTextColor(context, accent),
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              level.title,
              key: const Key('game-level-title'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                height: 1.06,
              ),
            ),
            const SizedBox(height: 13),
            Text(
              level.instructions,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 9,
              runSpacing: 9,
              children: [
                _IntroPill(icon: gameIcon(game), label: game.typeLabel),
                _IntroPill(icon: Icons.bolt_rounded, label: game.difficulty),
              ],
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('start-level-button'),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: _foregroundFor(accent),
                  minimumSize: const Size.fromHeight(56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow_rounded, size: 28),
                label: const Text(
                  'Let’s play!',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The battlefield uses the complete viewport. Only saving failures add a
/// temporary overlay; the enemy's landed pose remains visible underneath.
class _DavidBattleLevel extends StatelessWidget {
  const _DavidBattleLevel({
    required this.level,
    required this.onComplete,
    required this.onExit,
    required this.paused,
    required this.submitting,
    required this.error,
    required this.onRetrySubmit,
    required this.onRedo,
    super.key,
  });
  final GameLevel level;
  final GameEngineComplete onComplete;
  final VoidCallback onExit;
  final bool paused;
  final bool submitting;
  final String? error;
  final VoidCallback? onRetrySubmit;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) => Stack(
    key: const Key('david-fullscreen-battle'),
    fit: StackFit.expand,
    children: [
      DavidSlingEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      if (error != null)
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 16,
          child: _SubmitError(
            message: error!,
            onRetry: onRetrySubmit,
            onRedo: onRedo,
          ),
        ),
      if (submitting)
        Positioned(
          left: 24,
          right: 24,
          top: MediaQuery.paddingOf(context).top + 72,
          child: const IgnorePointer(
            child: Card(
              color: Color(0xDFFFFFF5),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Saving this round…'),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Journey engines own their viewport and ready stage. Saving keeps the
/// finished activity behind a retry overlay without restarting it.
class _JourneyLevel extends StatelessWidget {
  const _JourneyLevel({
    required this.crossing,
    required this.level,
    required this.onComplete,
    required this.onExit,
    required this.paused,
    required this.submitting,
    required this.error,
    required this.onRetrySubmit,
    required this.onRedo,
    super.key,
  });

  final bool crossing;
  final GameLevel level;
  final GameEngineComplete onComplete;
  final VoidCallback onExit;
  final bool paused;
  final bool submitting;
  final String? error;
  final VoidCallback? onRetrySubmit;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) => Stack(
    key: Key(
      crossing ? 'red-sea-fullscreen-level' : 'sailing-fullscreen-level',
    ),
    fit: StackFit.expand,
    children: [
      if (crossing)
        RedSeaCrossingEngine(
          level: level,
          graphicsManifestAsset: 'assets/images/games/red-sea-graphics-v1.json',
          onComplete: onComplete,
          onExit: onExit,
          paused: paused || submitting || error != null,
        )
      else
        StormSailingEngine(
          level: level,
          onComplete: onComplete,
          onExit: onExit,
          paused: paused || submitting || error != null,
        ),
      if (error != null)
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 16,
          child: _SubmitError(
            message: error!,
            onRetry: onRetrySubmit,
            onRedo: onRedo,
          ),
        ),
      if (submitting)
        Positioned(
          left: 24,
          right: 24,
          top: MediaQuery.paddingOf(context).top + 72,
          child: IgnorePointer(
            child: Card(
              color: const Color(0xDFFFFFF5),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      crossing
                          ? 'Saving this crossing…'
                          : 'Saving this voyage…',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _BlenderActivityLevel extends StatelessWidget {
  const _BlenderActivityLevel({
    required this.type,
    required this.level,
    required this.onComplete,
    required this.onExit,
    required this.paused,
    required this.submitting,
    required this.error,
    required this.onRetrySubmit,
    required this.onRedo,
    super.key,
  });
  final GameType type;
  final GameLevel level;
  final GameEngineComplete onComplete;
  final VoidCallback onExit;
  final bool paused;
  final bool submitting;
  final String? error;
  final VoidCallback? onRetrySubmit;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) => Stack(
    key: Key('${level.config['mode']}-fullscreen-level'),
    fit: StackFit.expand,
    children: [
      GameLevelEngine(
        type: type,
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused || submitting || error != null,
      ),
      if (error != null)
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 16,
          child: _SubmitError(
            message: error!,
            onRetry: onRetrySubmit,
            onRedo: onRedo,
          ),
        ),
      if (submitting)
        Positioned(
          left: 24,
          right: 24,
          top: MediaQuery.paddingOf(context).top + 72,
          child: const IgnorePointer(
            child: Card(
              color: Color(0xDFFFFFF5),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Saving this round…'),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _PlayingLevel extends StatelessWidget {
  const _PlayingLevel({
    required this.game,
    required this.level,
    required this.submitting,
    required this.error,
    required this.onComplete,
    required this.onRetrySubmit,
    required this.onRedo,
    super.key,
  });

  final MiniGame game;
  final GameLevel level;
  final bool submitting;
  final String? error;
  final GameEngineComplete onComplete;
  final VoidCallback? onRetrySubmit;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: game.gameType == GameType.puzzle
                    ? const EdgeInsets.fromLTRB(20, 15, 20, 36)
                    : const EdgeInsets.fromLTRB(14, 12, 14, 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GameLevelEngine(
                      type: game.gameType,
                      level: level,
                      onComplete: onComplete,
                    ),
                  ],
                ),
              ),
            ),
            if (error != null)
              SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: _SubmitError(
                  message: error!,
                  onRetry: onRetrySubmit,
                  onRedo: onRedo,
                ),
              ),
          ],
        ),
        if (submitting)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.76),
              child: const Center(child: _SavingResult()),
            ),
          ),
      ],
    );
  }
}

class _LevelFailureResult extends StatelessWidget {
  const _LevelFailureResult({
    required this.game,
    required this.submission,
    required this.onRetry,
    required this.onExit,
    super.key,
  });

  final MiniGame game;
  final GameSubmission submission;
  final VoidCallback onRetry;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(game);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 720),
            curve: Curves.elasticOut,
            tween: Tween(begin: 0, end: 1),
            builder: (context, value, child) =>
                Transform.scale(scale: value, child: child),
            child: Container(
              width: 126,
              height: 126,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFE1B6), Color(0xFFFFB66C)],
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.25),
                    blurRadius: 36,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: const Center(
                child: Text('💪', style: TextStyle(fontSize: 61)),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'So close — try again!',
            key: const Key('game-result-heading'),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Text(
            submission.feedback.isNotEmpty
                ? submission.feedback
                : 'Every try helps your courage grow.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 22),
          _AuthoritativeResultCard(submission: submission),
          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('retry-level-button'),
              onPressed: onRetry,
              icon: const Icon(Icons.replay_rounded),
              label: const Text('Try this level again'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('finish-game-button'),
            onPressed: onExit,
            icon: const Icon(Icons.grid_view_rounded),
            label: const Text('Back to the game library'),
          ),
        ],
      ),
    );
  }
}

class _AuthoritativeResultCard extends StatelessWidget {
  const _AuthoritativeResultCard({required this.submission});

  final GameSubmission submission;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('authoritative-game-result'),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackStats =
              MediaQuery.textScalerOf(context).scale(1) >= 2 ||
              constraints.maxWidth < 250;
          final score = _ResultStat(
            icon: Icons.auto_graph_rounded,
            value: '${submission.score}/${submission.maxScore}',
            label: 'Level score',
          );
          final stars = _ResultStat(
            icon: Icons.star_rounded,
            value: '${submission.starsAwarded}/3',
            label: 'Level stars',
          );
          if (stackStats) {
            return Column(
              children: [
                score,
                Divider(
                  height: 28,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                stars,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: score),
              Container(
                width: 1,
                height: 48,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: stars),
            ],
          );
        },
      ),
    );
  }
}

class _ResultStat extends StatelessWidget {
  const _ResultStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFFFFA000), size: 25),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _IntroPill extends StatelessWidget {
  const _IntroPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _SavingResult extends StatelessWidget {
  const _SavingResult();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('saving-game-result'),
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 24,
          ),
        ],
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 13),
          Text('Checking your adventure…'),
        ],
      ),
    );
  }
}

class _SubmitError extends StatelessWidget {
  const _SubmitError({
    required this.message,
    required this.onRetry,
    required this.onRedo,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.6;
            final messageRow = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  onRetry == null
                      ? Icons.refresh_rounded
                      : Icons.cloud_off_rounded,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            );
            final actions = Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (onRetry != null)
                  TextButton.icon(
                    key: const Key('retry-game-save'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.cloud_upload_rounded),
                    label: const Text('Retry save'),
                  ),
                FilledButton.tonalIcon(
                  key: const Key('redo-game-level'),
                  onPressed: onRedo,
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text('Redo level'),
                ),
              ],
            );
            if (largeText || constraints.maxWidth < 430) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  messageRow,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: messageRow),
                const SizedBox(width: 8),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NoPlayableLevels extends StatelessWidget {
  const _NoPlayableLevels({required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🧩', style: TextStyle(fontSize: 58)),
            const SizedBox(height: 14),
            Text(
              'This quest is being prepared.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            const Text(
              'No playable levels are ready for this quest yet.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onExit, child: const Text('Back to games')),
          ],
        ),
      ),
    );
  }
}

class _PlayBackdropPainter extends CustomPainter {
  const _PlayBackdropPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = accent.withValues(alpha: 0.055);
    canvas.drawCircle(
      Offset(size.width * 0.92, size.height * 0.18),
      120,
      paint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.08, size.height * 0.78),
      150,
      paint,
    );
    final star = Paint()..color = accent.withValues(alpha: 0.16);
    for (final point in const [
      Offset(0.12, 0.17),
      Offset(0.82, 0.34),
      Offset(0.18, 0.57),
      Offset(0.88, 0.73),
    ]) {
      canvas.drawCircle(
        Offset(point.dx * size.width, point.dy * size.height),
        4,
        star,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PlayBackdropPainter oldDelegate) {
    return oldDelegate.accent != accent;
  }
}

Color _pageBackground(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF111515)
      : const Color(0xFFFFFCF8);
}

Color _foregroundFor(Color background) {
  return background.computeLuminance() > 0.179
      ? const Color(0xFF2E2940)
      : Colors.white;
}

Color _accentTextColor(BuildContext context, Color accent) {
  final surface = _pageBackground(context);
  final accentLuminance = accent.computeLuminance();
  final surfaceLuminance = surface.computeLuminance();
  final lighter = accentLuminance > surfaceLuminance
      ? accentLuminance
      : surfaceLuminance;
  final darker = accentLuminance < surfaceLuminance
      ? accentLuminance
      : surfaceLuminance;
  return (lighter + 0.05) / (darker + 0.05) >= 4.5
      ? accent
      : _foregroundFor(surface);
}
