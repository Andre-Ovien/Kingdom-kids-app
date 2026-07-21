import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';
import 'game_cover_image.dart';
import 'game_engines.dart';

class GamePlayScreen extends StatefulWidget {
  const GamePlayScreen({
    required this.game,
    required this.profile,
    required this.repository,
    super.key,
    this.startingLevel,
    this.authRepository,
  });

  final MiniGame game;
  final KidProfile profile;
  final GameRepository repository;
  final AuthRepository? authRepository;
  final int? startingLevel;

  @override
  State<GamePlayScreen> createState() => _GamePlayScreenState();
}

enum _PlayPhase { intro, playing, result }

class _GamePlayScreenState extends State<GamePlayScreen> {
  late int _levelIndex;
  _PlayPhase _phase = _PlayPhase.intro;
  GameSubmission? _submission;
  Map<String, dynamic>? _pendingResult;
  String? _operationId;
  String? _submitError;
  bool _canRetrySave = false;
  bool _submitting = false;
  bool _allowExit = false;
  int _attempt = 0;

  List<GameLevel> get _levels => widget.game.levels;
  GameLevel get _level => _levels[_levelIndex];

  @override
  void initState() {
    super.initState();
    final wanted =
        widget.startingLevel ??
        (widget.game.playerProgress.isComplete
            ? 1
            : widget.game.playerProgress.currentLevel);
    final found = _levels.indexWhere((level) => level.number == wanted);
    _levelIndex = found < 0 ? 0 : found;
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
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) {
        final status = error.statusCode;
        final isRejectedResult =
            status != null && status >= 400 && status < 500;
        setState(() {
          _submitError = error.message;
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
      _phase = _PlayPhase.intro;
      _submission = null;
      _pendingResult = null;
      _operationId = null;
      _submitError = null;
      _canRetrySave = false;
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
    if (_levelIndex >= _levels.length - 1) return;
    setState(() {
      _levelIndex += 1;
      _phase = _PlayPhase.intro;
      _submission = null;
      _pendingResult = null;
      _operationId = null;
      _submitError = null;
      _canRetrySave = false;
    });
  }

  void _replayQuest() {
    setState(() {
      _levelIndex = 0;
      _phase = _PlayPhase.intro;
      _submission = null;
      _pendingResult = null;
      _operationId = null;
      _submitError = null;
      _canRetrySave = false;
    });
  }

  void _popWithResult(bool changed) {
    if (!mounted || _allowExit) return;
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(changed);
    });
  }

  Future<void> _requestExit() async {
    if (_phase == _PlayPhase.result || _submission != null) {
      _popWithResult(true);
      return;
    }
    if (_phase != _PlayPhase.playing) {
      _popWithResult(false);
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this level?'),
        content: const Text(
          'This try has not been saved yet. You can come back and play again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep playing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      _popWithResult(false);
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
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _PlayBackdropPainter(accent: accent),
                ),
              ),
            ),
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
                        _PlayPhase.result => _LevelResult(
                          key: ValueKey(
                            'result-${_submission?.operationId ?? _level.number}',
                          ),
                          game: widget.game,
                          level: _level,
                          submission: _submission!,
                          isLastLevel: _levelIndex == _levels.length - 1,
                          onNext: _nextLevel,
                          onRetry: _tryLevelAgain,
                          onReplay: _replayQuest,
                          onExit: () => Navigator.of(context).pop(true),
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
              child: Icon(gameTypeIcon(game.gameType), color: accent, size: 58),
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
                _IntroPill(
                  icon: gameTypeIcon(game.gameType),
                  label: game.typeLabel,
                ),
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
                padding: const EdgeInsets.fromLTRB(20, 15, 20, 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      level.title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (level.instructions.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        level.instructions,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
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

class _LevelResult extends StatelessWidget {
  const _LevelResult({
    required this.game,
    required this.level,
    required this.submission,
    required this.isLastLevel,
    required this.onNext,
    required this.onRetry,
    required this.onReplay,
    required this.onExit,
    super.key,
  });

  final MiniGame game;
  final GameLevel level;
  final GameSubmission submission;
  final bool isLastLevel;
  final VoidCallback onNext;
  final VoidCallback onRetry;
  final VoidCallback onReplay;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    // Completion is authoritative. A quiz may legitimately pass without a
    // perfect score, so `correct` must not strand a child on an unlocked level.
    final success = submission.completed;
    final accent = gameAccent(game);
    final finishedQuest = success && isLastLevel;
    return Stack(
      children: [
        if (success) const Positioned.fill(child: _CelebrationBurst()),
        SingleChildScrollView(
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
                    gradient: LinearGradient(
                      colors: success
                          ? [const Color(0xFFFFD54F), const Color(0xFFFF8A50)]
                          : [const Color(0xFFFFE1B6), const Color(0xFFFFB66C)],
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
                  child: Center(
                    child: Text(
                      success ? (finishedQuest ? '🏆' : '⭐') : '💪',
                      style: const TextStyle(fontSize: 61),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                success
                    ? (finishedQuest ? 'Quest complete!' : 'Level complete!')
                    : 'So close — try again!',
                key: const Key('game-result-heading'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                submission.feedback.isNotEmpty
                    ? submission.feedback
                    : success
                    ? 'Wonderful work! Your result is saved.'
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
              if (success && !isLastLevel)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('next-level-button'),
                    onPressed: onNext,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('Next level'),
                  ),
                )
              else if (!success)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('retry-level-button'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('Try this level again'),
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('replay-quest-button'),
                    onPressed: onReplay,
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('Replay the quest'),
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
        ),
      ],
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

class _CelebrationBurst extends StatefulWidget {
  const _CelebrationBurst();

  @override
  State<_CelebrationBurst> createState() => _CelebrationBurstState();
}

class _CelebrationBurstState extends State<_CelebrationBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) =>
            CustomPaint(painter: _ConfettiPainter(progress: _controller.value)),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter({required this.progress});

  final double progress;

  static const _colors = [
    Color(0xFFFF7043),
    Color(0xFFFFD54F),
    Color(0xFF6C5CE7),
    Color(0xFF36C98F),
    Color(0xFF48A9FF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(17);
    for (var index = 0; index < 48; index++) {
      final startX = random.nextDouble() * size.width;
      final speed = 0.72 + random.nextDouble() * 0.65;
      final y = -20 + (size.height + 60) * progress * speed;
      final x = startX + math.sin(progress * math.pi * 4 + index) * 18;
      final paint = Paint()
        ..color = _colors[index % _colors.length].withValues(
          alpha: (1 - progress * 0.55).clamp(0, 1),
        );
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(progress * math.pi * (index.isEven ? 3 : -3));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-4, -7, 8, 14),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) {
    return oldDelegate.progress != progress;
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
