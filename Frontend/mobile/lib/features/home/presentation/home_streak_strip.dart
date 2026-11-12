import 'package:flutter/material.dart';

import '../../streak/domain/streak_presentation.dart';

/// A read-only summary. Checks represent supplied visit dates, never a count.
class HomeStreakStrip extends StatelessWidget {
  const HomeStreakStrip({
    required this.currentDays,
    this.recentDays = const [],
    this.localDate,
    super.key,
  });

  final int currentDays;
  final List<StreakDay> recentDays;
  final DateTime? localDate;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF352D58);
    const purple = Color(0xFF8066E8);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final date = localDate;
    final hasWeek = date != null && recentDays.isNotEmpty;
    final visits = {
      for (final day in recentDays)
        DateTime(day.date.year, day.date.month, day.date.day): day.active,
    };
    final monday = date == null
        ? null
        : DateTime(
            date.year,
            date.month,
            date.day,
          ).subtract(Duration(days: date.weekday - 1));
    return SizedBox(
      key: const Key('home-streak-strip'),
      height: 97 + ((scale - 1).clamp(0, 1.5) * 80),
      child: Material(
        color: const Color(0xFFE8E7FC),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(32),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            const Positioned(
              right: 13,
              top: 28,
              child: ExcludeSemantics(
                child: Icon(
                  Icons.star_rounded,
                  color: Color(0xFFF7C64F),
                  size: 33,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 50, 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          currentDays == 0
                              ? 'Your next streak starts today!'
                              : "You're on a $currentDays-day streak!",
                          key: const Key('home-streak-count'),
                          maxLines: 2,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: ink,
                                fontSize: 14.5,
                                height: 1.15,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const ExcludeSemantics(
                        child: Icon(
                          Icons.local_fire_department_rounded,
                          color: Color(0xFFFF7544),
                          size: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  if (hasWeek)
                    Row(
                      key: const Key('home-streak-weekdays'),
                      children: List.generate(7, (index) {
                        const labels = [
                          'Mon',
                          'Tue',
                          'Wed',
                          'Thu',
                          'Fri',
                          'Sat',
                          'Sun',
                        ];
                        final day = monday!.add(Duration(days: index));
                        final active = visits[day] == true;
                        final known = visits.containsKey(day);
                        return Expanded(
                          child: Semantics(
                            label: labels[index],
                            value: active
                                ? 'visited'
                                : known
                                ? 'not visited'
                                : 'no visit data',
                            child: ExcludeSemantics(
                              child: Column(
                                children: [
                                  Container(
                                    key: ValueKey('home-streak-weekday-$index'),
                                    width: 19,
                                    height: 19,
                                    decoration: BoxDecoration(
                                      color: active
                                          ? purple
                                          : const Color(0xFFF7F6FE),
                                      shape: BoxShape.circle,
                                    ),
                                    child: active
                                        ? const Icon(
                                            Icons.check_rounded,
                                            color: Colors.white,
                                            size: 13,
                                          )
                                        : null,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    labels[index],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: ink,
                                          fontSize: 9,
                                          height: 1.1,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    )
                  else
                    Text(
                      'A little discovery, every day.',
                      key: const Key('home-streak-count-only'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: ink.withValues(alpha: 0.75),
                        fontSize: 11,
                        height: 1.25,
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
