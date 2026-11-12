// Preview-only copy of the production streak screen. Only the background
// and character artwork change; no production route imports this widget.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/presentation/kid_profile_avatar.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';

class StreakFireConcept extends StatefulWidget {
  const StreakFireConcept({
    required this.presentation,
    required this.fireImagePath,
    this.xpAwarded = 0,
    this.onClose,
    super.key,
  });

  final StreakPresentation presentation;
  final String fireImagePath;
  final int xpAwarded;
  final VoidCallback? onClose;

  @override
  State<StreakFireConcept> createState() => _StreakFireConceptState();
}

class _StreakFireConceptState extends State<StreakFireConcept>
    with TickerProviderStateMixin {
  static const _ink = Color(0xFF211A35);
  static const _lightBackground = Color(0xFFF3F6FF);

  late final AnimationController _entranceController;
  late final AnimationController _ambientController;
  bool? _reduceMotion;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 980),
    );
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    // Isolated preview: no sound request, streak claim, or storage operation.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;

    if (reduceMotion) {
      _entranceController.stop();
      _ambientController.stop();
      _entranceController.value = 1;
      _ambientController.value = 0.5;
      return;
    }

    if (_entranceController.value < 1) {
      _entranceController.forward();
    }
    _ambientController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _ambientController.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }

    final navigator = Navigator.of(context);
    if (await navigator.maybePop()) return;
    if (mounted) {
      await navigator.pushReplacementNamed(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final presentation = widget.presentation;
    final option = kidAvatarOptionFor(presentation.profile.avatarKey);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        key: const Key('streak-screen'),
        backgroundColor: _lightBackground,
        body: SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _entranceController,
              _ambientController,
            ]),
            builder: (context, _) {
              final entrance = _entranceController.value;
              final ambient = _ambientController.value * 2 - 1;
              final stageProgress = Curves.elasticOut.transform(
                _interval(entrance, 0.02, 0.7),
              );
              final stageOpacity = Curves.easeOut.transform(
                _interval(entrance, 0, 0.32),
              );
              final contentProgress = Curves.easeOutCubic.transform(
                _interval(entrance, 0.3, 0.84),
              );
              final actionProgress = Curves.easeOutCubic.transform(
                _interval(entrance, 0.58, 1),
              );

              return LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 650;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      _StreakBackdrop(
                        color: _lightBackground,
                        progress: stageOpacity,
                        ambient: ambient,
                      ),
                      Column(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              key: const Key('streak-scroll'),
                              padding: EdgeInsets.fromLTRB(
                                22,
                                compact ? 54 : 64,
                                22,
                                compact ? 14 : 20,
                              ),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: math.max(
                                    0,
                                    constraints.maxHeight -
                                        (compact ? 150 : 176),
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Opacity(
                                      opacity: stageOpacity.clamp(0, 1),
                                      child: Transform.translate(
                                        offset: Offset(
                                          0,
                                          42 * (1 - stageProgress) +
                                              ambient * 5,
                                        ),
                                        child: Transform.rotate(
                                          angle: ambient * 0.014,
                                          child: Transform.scale(
                                            scale:
                                                0.58 +
                                                stageProgress * 0.42 +
                                                ambient * 0.006,
                                            child: _FireStreakStage(
                                              fireImagePath:
                                                  widget.fireImagePath,
                                              presentation: presentation,
                                              option: option,
                                              compact: compact,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: compact ? 14 : 24),
                                    Opacity(
                                      opacity: contentProgress.clamp(0, 1),
                                      child: Transform.translate(
                                        offset: Offset(
                                          0,
                                          22 * (1 - contentProgress),
                                        ),
                                        child: _StreakContent(
                                          presentation: presentation,
                                          option: option,
                                          ink: _ink,
                                          compact: compact,
                                          xpAwarded: widget.xpAwarded,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Opacity(
                            opacity: actionProgress.clamp(0, 1),
                            child: Transform.translate(
                              offset: Offset(0, 16 * (1 - actionProgress)),
                              child: _ContinueAction(
                                ink: _ink,
                                onPressed: _close,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8, right: 14),
                          child: _CloseButton(ink: _ink, onPressed: _close),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FireStreakStage extends StatelessWidget {
  const _FireStreakStage({
    required this.fireImagePath,
    required this.presentation,
    required this.option,
    required this.compact,
  });

  final String fireImagePath;
  final StreakPresentation presentation;
  final KidAvatarOption option;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final stageWidth = compact ? 210.0 : 274.0;
    final stageHeight = compact ? 220.0 : 292.0;
    final haloSize = compact ? 166.0 : 218.0;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: 'A burning flame celebrating your streak',
      child: SizedBox(
        key: const Key('streak-character-stage'),
        width: stageWidth,
        height: stageHeight,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: haloSize,
              height: haloSize,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.94),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _StreakFireConceptState._ink,
                  width: 4,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: _StreakFireConceptState._ink,
                    offset: Offset(8, 9),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: Image.memory(
                File(fireImagePath).readAsBytesSync(),
                key: const Key('streak-fire-hero'),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                semanticLabel: 'Realistic burning flames',
              ),
            ),
            Positioned(
              right: compact ? -2 : -4,
              bottom: compact ? 16 : 22,
              child: _FlameCounter(
                days: presentation.currentDays,
                compact: compact,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlameCounter extends StatelessWidget {
  const _FlameCounter({required this.days, required this.compact});

  final int days;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 68.0 : 78.0;
    return Semantics(
      label: '$days ${days == 1 ? 'day' : 'days'}',
      child: Container(
        key: const Key('streak-flame-counter'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFFFC84B),
          shape: BoxShape.circle,
          border: Border.all(color: _StreakFireConceptState._ink, width: 3),
          boxShadow: const [
            BoxShadow(
              color: _StreakFireConceptState._ink,
              offset: Offset(4, 5),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.local_fire_department_rounded,
              color: const Color(0xFFFF6B35),
              size: compact ? 43 : 50,
            ),
            Padding(
              padding: EdgeInsets.only(top: compact ? 12 : 14),
              child: Text(
                '$days',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _StreakFireConceptState._ink,
                  fontWeight: FontWeight.w900,
                  fontSize: compact ? 17 : 19,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StreakContent extends StatelessWidget {
  const _StreakContent({
    required this.presentation,
    required this.option,
    required this.ink,
    required this.compact,
    required this.xpAwarded,
  });

  final StreakPresentation presentation;
  final KidAvatarOption option;
  final Color ink;
  final bool compact;
  final int xpAwarded;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: ink, width: 2),
          ),
          child: Text(
            _eyebrow(presentation),
            key: const Key('streak-eyebrow'),
            style: textTheme.labelLarge?.copyWith(
              color: ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.05,
            ),
          ),
        ),
        const SizedBox(height: 13),
        Semantics(
          key: const Key('streak-announcement'),
          container: true,
          liveRegion: true,
          label: _announcement(presentation),
          child: ExcludeSemantics(
            child: Text(
              _title(presentation),
              key: const Key('streak-title'),
              textAlign: TextAlign.center,
              style: textTheme.headlineLarge?.copyWith(
                color: ink,
                fontSize: compact ? 37 : 45,
                height: 0.98,
                fontWeight: FontWeight.w900,
                letterSpacing: -1.3,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _message(presentation),
          key: const Key('streak-message'),
          textAlign: TextAlign.center,
          style: textTheme.bodyLarge?.copyWith(
            color: ink.withValues(alpha: 0.78),
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        if (xpAwarded > 0) ...[
          const SizedBox(height: 12),
          Text(
            '+$xpAwarded XP for today’s visit',
            key: const Key('streak-xp-reward'),
            textAlign: TextAlign.center,
            style: textTheme.titleMedium?.copyWith(
              color: ink,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
        if (presentation.recentDays.isNotEmpty) ...[
          SizedBox(height: compact ? 16 : 22),
          _RecentStreakDays(
            days: presentation.recentDays,
            localDate: presentation.localDate,
            ink: ink,
            accent: option.color,
          ),
        ],
      ],
    );
  }
}

class _RecentStreakDays extends StatelessWidget {
  const _RecentStreakDays({
    required this.days,
    required this.localDate,
    required this.ink,
    required this.accent,
  });

  final List<StreakDay> days;
  final DateTime localDate;
  final Color ink;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('streak-recent-days'),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ink, width: 2.2),
        boxShadow: [
          BoxShadow(
            color: ink.withValues(alpha: 0.17),
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          for (final day in days)
            Expanded(
              child: _RecentDay(
                day: day,
                isToday: _sameDate(day.date, localDate),
                ink: ink,
                accent: accent,
              ),
            ),
        ],
      ),
    );
  }
}

class _RecentDay extends StatelessWidget {
  const _RecentDay({
    required this.day,
    required this.isToday,
    required this.ink,
    required this.accent,
  });

  final StreakDay day;
  final bool isToday;
  final Color ink;
  final Color accent;

  static const _weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _weekdayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  @override
  Widget build(BuildContext context) {
    final label = _weekdayLabels[day.date.weekday - 1];
    final name = _weekdayNames[day.date.weekday - 1];
    return Semantics(
      label:
          '$name${isToday ? ', today' : ''}: '
          '${day.active ? 'active' : 'not active'}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: ink.withValues(alpha: isToday ? 1 : 0.58),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: day.active
                  ? const Color(0xFFFFC84B)
                  : accent.withValues(alpha: 0.13),
              shape: BoxShape.circle,
              border: Border.all(
                color: isToday ? ink : ink.withValues(alpha: 0.18),
                width: isToday ? 2.2 : 1.2,
              ),
            ),
            child: Icon(
              day.active
                  ? Icons.local_fire_department_rounded
                  : Icons.circle_outlined,
              color: day.active
                  ? const Color(0xFFFF6535)
                  : ink.withValues(alpha: 0.28),
              size: day.active ? 20 : 9,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueAction extends StatelessWidget {
  const _ContinueAction({required this.ink, required this.onPressed});

  final Color ink;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            key: const Key('streak-continue-button'),
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: ink,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              textStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            icon: const Icon(Icons.explore_rounded),
            label: const Text('Keep exploring'),
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.ink, required this.onPressed});

  final Color ink;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 46,
      child: IconButton(
        key: const Key('streak-close-button'),
        tooltip: 'Close streak update',
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.9),
          foregroundColor: ink,
          side: BorderSide(color: ink, width: 2),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.close_rounded, size: 24),
      ),
    );
  }
}

class _StreakBackdrop extends StatelessWidget {
  const _StreakBackdrop({
    required this.color,
    required this.progress,
    required this.ambient,
  });

  final Color color;
  final double progress;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -165 + ambient * 5,
            left: -145,
            child: _BackdropOrb(
              size: 340,
              color: Colors.white.withValues(alpha: 0.18 * progress),
            ),
          ),
          Positioned(
            top: 250 - ambient * 7,
            right: -150,
            child: _BackdropOrb(
              size: 280,
              color: Colors.white.withValues(alpha: 0.1 * progress),
            ),
          ),
          Positioned(
            left: 26,
            top: 155 + ambient * 9,
            child: _Spark(
              icon: Icons.auto_awesome_rounded,
              size: 31,
              opacity: progress,
            ),
          ),
          Positioned(
            right: 30,
            top: 112 - ambient * 7,
            child: _Spark(
              icon: Icons.star_rounded,
              size: 37,
              opacity: progress,
            ),
          ),
          Positioned(
            left: 42,
            bottom: 190 - ambient * 8,
            child: _Spark(
              icon: Icons.star_rounded,
              size: 25,
              opacity: progress * 0.72,
            ),
          ),
          ColoredBox(color: color.withValues(alpha: 0.01)),
        ],
      ),
    );
  }
}

class _BackdropOrb extends StatelessWidget {
  const _BackdropOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Spark extends StatelessWidget {
  const _Spark({required this.icon, required this.size, required this.opacity});

  final IconData icon;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0, 1),
      child: Icon(
        icon,
        size: size,
        color: _StreakFireConceptState._ink.withValues(alpha: 0.34),
      ),
    );
  }
}

String _eyebrow(StreakPresentation presentation) {
  return switch (presentation.state) {
    StreakPresentationState.firstStreak => 'A NEW SPARK',
    StreakPresentationState.continued =>
      presentation.isPersonalBest ? 'YOUR BEST STREAK' : 'STREAK GROWING',
  };
}

String _title(StreakPresentation presentation) {
  final days = presentation.currentDays;
  return switch (presentation.state) {
    StreakPresentationState.firstStreak || StreakPresentationState.continued =>
      '$days ${days == 1 ? 'day' : 'days'} streak!',
  };
}

String _message(StreakPresentation presentation) {
  final name = presentation.profile.displayName;
  switch (presentation.state) {
    case StreakPresentationState.firstStreak:
      return '$name, you showed up today. Come back tomorrow to keep your '
          'flame glowing.';
    case StreakPresentationState.continued:
      if (presentation.isPersonalBest) {
        return 'That’s your best yet, $name! Come back tomorrow to keep your '
            'flame glowing.';
      }
      final remaining = presentation.nextMilestone - presentation.currentDays;
      return '$name, you showed up today. Just $remaining more '
          '${remaining == 1 ? 'day' : 'days'} to a '
          '${presentation.nextMilestone}-day streak.';
  }
}

String _announcement(StreakPresentation presentation) {
  return '${_title(presentation)} ${_message(presentation)}';
}

bool _sameDate(DateTime left, DateTime right) {
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

double _interval(double value, double start, double end) {
  return ((value - start) / (end - start)).clamp(0.0, 1.0);
}
