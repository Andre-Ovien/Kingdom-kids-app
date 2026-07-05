import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../../shared/widgets/liquid_glass.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  static const _stats = [
    _ProgressStat(
      value: '24',
      label: 'Stories',
      icon: Icons.menu_book_rounded,
      color: Color(0xFF4E8A6D),
    ),
    _ProgressStat(
      value: '6.2h',
      label: 'Read time',
      icon: Icons.timer_rounded,
      color: Color(0xFF4B9BD6),
    ),
    _ProgressStat(
      value: '12',
      label: 'Badges',
      icon: Icons.emoji_events_rounded,
      color: Color(0xFFF4C430),
    ),
  ];

  static const _badges = [
    _BadgeItem(
      'Story hero',
      Icons.local_fire_department_rounded,
      Color(0xFFE45B4D),
    ),
    _BadgeItem('Star reader', Icons.star_rounded, Color(0xFFF4C430)),
    _BadgeItem('Book worm', Icons.library_books_rounded, Color(0xFF4A8EDB)),
    _BadgeItem('Audio fan', Icons.headphones_rounded, Color(0xFF69A7C6)),
    _BadgeItem('Night learner', Icons.nightlight_round, Color(0xFF333138)),
  ];

  static const _weeks = [
    _WeekBar('Week 1', 0.82, Color(0xFFE14D42)),
    _WeekBar('Week 2', 0.56, Color(0xFF4168D7)),
    _WeekBar('Week 3', 0.38, Color(0xFF7B5DDA)),
    _WeekBar('Week 4', 0.72, Color(0xFFE86139)),
    _WeekBar('Week 5', 0.92, Color(0xFF4773E4)),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 110),
                  sliver: SliverList.list(
                    children: const [
                      _ProfileHeader(),
                      SizedBox(height: 34),
                      _StatsRow(stats: _stats),
                      SizedBox(height: 42),
                      _SectionTitle('My Badges'),
                      SizedBox(height: 14),
                      _BadgeShelf(badges: _badges),
                      SizedBox(height: 28),
                      _ReadingStreakChart(weeks: _weeks),
                    ],
                  ),
                ),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(selectedRoute: AppRoutes.profile),
            ),
            const Positioned(top: 14, right: 24, child: _SettingsButton()),
          ],
        ),
      ),
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      borderRadius: 28,
      opacity: 0.02,
      blur: 28,
      borderOpacity: 0.38,
      child: SizedBox.square(
        dimension: 52,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: () =>
              Navigator.of(context).pushNamed(AppRoutes.parentalControls),
          child: Icon(
            Icons.settings_rounded,
            color: _primaryText(context),
            size: 24,
          ),
        ),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 82,
          height: 82,
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
            color: Color(0xFFFFD8DF),
            shape: BoxShape.circle,
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/profile_avatar.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Ethan the Reader',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: _primaryText(context),
            fontSize: 24,
            fontWeight: FontWeight.w500,
            height: 1.1,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.star_rounded, color: Color(0xFFFFB642), size: 19),
            const SizedBox(width: 7),
            Text(
              'Level 7 Story Explorer',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _mutedText(context),
                fontSize: 13,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});

  final List<_ProgressStat> stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: stats.map((stat) => _StatColumn(stat: stat)).toList(),
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({required this.stat});

  final _ProgressStat stat;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      child: Column(
        children: [
          Icon(stat.icon, color: stat.color, size: 22),
          const SizedBox(height: 8),
          Text(
            stat.value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _primaryText(context),
              fontSize: 24,
              fontWeight: FontWeight.w400,
              height: 1,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            stat.label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        color: _primaryText(context),
        fontSize: 18,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
    );
  }
}

class _BadgeShelf extends StatelessWidget {
  const _BadgeShelf({required this.badges});

  final List<_BadgeItem> badges;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: badges.length,
        separatorBuilder: (_, _) => const SizedBox(width: 18),
        itemBuilder: (context, index) => _BadgeIcon(item: badges[index]),
      ),
    );
  }
}

class _BadgeIcon extends StatelessWidget {
  const _BadgeIcon({required this.item});

  final _BadgeItem item;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          Icon(item.icon, color: item.color, size: 28),
          const SizedBox(height: 9),
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              fontSize: 10.5,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadingStreakChart extends StatefulWidget {
  const _ReadingStreakChart({required this.weeks});

  final List<_WeekBar> weeks;

  @override
  State<_ReadingStreakChart> createState() => _ReadingStreakChartState();
}

class _ReadingStreakChartState extends State<_ReadingStreakChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _riseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    );
    _riseAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Reading Streak',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: _primaryText(context),
            fontSize: 18,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text(
              'This week',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _secondaryText(context),
                fontSize: 14,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
            const Spacer(),
            Text(
              '🔥  5 day streak!',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFE15A43),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 170,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _YAxisLabels(),
              const SizedBox(width: 14),
              Expanded(
                child: AnimatedBuilder(
                  animation: _riseAnimation,
                  builder: (context, _) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: widget.weeks
                          .map(
                            (week) => _WeekColumn(
                              week: week,
                              progress: _riseAnimation.value,
                            ),
                          )
                          .toList(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _YAxisLabels extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const labels = ['200', '150', '100', '50', '25', '0'];

    return SizedBox(
      width: 28,
      height: 144,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final label in labels)
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _axisText(context),
                fontSize: 10.5,
                letterSpacing: 0,
              ),
            ),
        ],
      ),
    );
  }
}

class _WeekColumn extends StatelessWidget {
  const _WeekColumn({required this.week, required this.progress});

  final _WeekBar week;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final easedProgress = progress.clamp(0.0, 1.0);

    return SizedBox(
      width: 48,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Opacity(
            opacity: easedProgress,
            child: Transform.translate(
              offset: Offset(0, 18 * (1 - easedProgress)),
              child: Container(
                width: 45,
                height: 128 * week.heightFactor * easedProgress,
                decoration: BoxDecoration(
                  color: week.color,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: week.color.withValues(alpha: 0.22 * easedProgress),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            week.label,
            maxLines: 1,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              fontSize: 10.5,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressStat {
  const _ProgressStat({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
  });

  final String value;
  final String label;
  final IconData icon;
  final Color color;
}

class _BadgeItem {
  const _BadgeItem(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

class _WeekBar {
  const _WeekBar(this.label, this.heightFactor, this.color);

  final String label;
  final double heightFactor;
  final Color color;
}

Color _primaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _secondaryText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFC4BCBA)
      : const Color(0xFF756C6C);
}

Color _mutedText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF9EA8A6)
      : const Color(0xFFB8ADAE);
}

Color _axisText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF7F8B89)
      : const Color(0xFFC8BEBE);
}
