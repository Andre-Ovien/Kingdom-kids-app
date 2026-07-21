from datetime import date, timedelta, timezone as fixed_timezone

from django.db.models import Prefetch
from django.utils import timezone

from apps.accounts.models import KidProfile
from apps.games.models import Game, GameAttempt, GameLevel, KidGameProgress
from apps.stories.models import Story

from .models import KidActivityEvent


XP_PER_COMPLETED_LEVEL = 100
XP_PER_STAR = 20
XP_PER_LEVEL = 300
WEEK_COUNT = 5

MONTH_LABELS = (
    '',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
)

BADGE_DEFINITIONS = (
    {
        'key': 'first-play',
        'title': 'First Play',
        'description': 'Finish your first game attempt.',
        'icon_key': 'play-spark',
        'metric': 'attempts',
        'target': 1,
    },
    {
        'key': 'star-seeker',
        'title': 'Star Seeker',
        'description': 'Collect 10 stars across game levels.',
        'icon_key': 'star',
        'metric': 'game_stars',
        'target': 10,
    },
    {
        'key': 'level-legend',
        'title': 'Level Legend',
        'description': 'Complete 5 different game levels.',
        'icon_key': 'trophy',
        'metric': 'completed_game_levels',
        'target': 5,
    },
    {
        'key': 'game-explorer',
        'title': 'Game Explorer',
        'description': 'Try 3 different games.',
        'icon_key': 'compass',
        'metric': 'games_started',
        'target': 3,
    },
    {
        'key': 'quest-champion',
        'title': 'Quest Champion',
        'description': 'Complete every level in one game.',
        'icon_key': 'crown',
        'metric': 'games_completed',
        'target': 1,
    },
)


def _safe_stars(value) -> int:
    """Treat malformed historical JSON as no stars instead of breaking a profile."""

    try:
        stars = int(value)
    except (TypeError, ValueError):
        return 0
    return min(max(stars, 0), 3)


def _title_for_level(level_number: int) -> str:
    if level_number <= 2:
        return 'Little Explorer'
    if level_number <= 5:
        return 'Brave Believer'
    if level_number <= 9:
        return 'Faith Adventurer'
    return 'Kingdom Champion'


def _level_payload(completed_levels: int, stars: int) -> dict:
    xp = completed_levels * XP_PER_COMPLETED_LEVEL + stars * XP_PER_STAR
    number = xp // XP_PER_LEVEL + 1
    return {
        'number': number,
        'title': _title_for_level(number),
        'xp': xp,
        # This is an absolute lifetime-XP threshold, not XP remaining.
        'next_level_xp': number * XP_PER_LEVEL,
    }


def _catalogue_progress(profile: KidProfile) -> dict:
    """Summarize best progress against the currently published catalogue."""

    games = list(
        Game.objects.filter(is_published=True)
        .prefetch_related(
            Prefetch('levels', queryset=GameLevel.objects.order_by('level_number')),
        )
        .order_by('sort_order', 'title')
    )
    game_ids = {game.pk for game in games}
    progress_by_game = {
        progress.game_id: progress
        for progress in KidGameProgress.objects.filter(
            profile=profile,
            game_id__in=game_ids,
        )
    }

    completed_game_levels = 0
    game_stars = 0
    games_completed = 0
    total_game_levels = 0

    for game in games:
        level_numbers = {level.level_number for level in game.levels.all()}
        total_game_levels += len(level_numbers)
        progress = progress_by_game.get(game.pk)
        raw_level_progress = progress.level_progress if progress else {}
        if not isinstance(raw_level_progress, dict):
            raw_level_progress = {}

        completed_numbers = set()
        for level_number in level_numbers:
            item = raw_level_progress.get(str(level_number), {})
            if not isinstance(item, dict):
                continue
            game_stars += _safe_stars(item.get('best_stars', 0))
            if item.get('completed') is True:
                completed_numbers.add(level_number)

        completed_game_levels += len(completed_numbers)
        if level_numbers and completed_numbers == level_numbers:
            games_completed += 1

    return {
        'published_game_ids': game_ids,
        'completed_game_levels': completed_game_levels,
        'total_game_levels': total_game_levels,
        'game_stars': game_stars,
        'max_game_stars': total_game_levels * 3,
        'games_completed': games_completed,
    }


def _week_label(week_start: date) -> str:
    return f'{MONTH_LABELS[week_start.month]} {week_start.day}'


def _activity_payload(
    attempt_rows: list[dict],
    story_completion_rows: list[dict],
    *,
    timezone_offset_minutes: int,
    now,
) -> dict:
    local_timezone = fixed_timezone(timedelta(minutes=timezone_offset_minutes))
    local_today = timezone.localtime(now, local_timezone).date()
    current_week_start = local_today - timedelta(days=local_today.weekday())
    first_week_start = current_week_start - timedelta(weeks=WEEK_COUNT - 1)

    weekly_activity = [
        {
            'week_start': (first_week_start + timedelta(weeks=index)).isoformat(),
            'label': _week_label(first_week_start + timedelta(weeks=index)),
            'attempts': 0,
            'story_completions': 0,
            'activities': 0,
        }
        for index in range(WEEK_COUNT)
    ]

    activity_dates = set()
    last_activity_at = None

    def record_activity(row, weekly_key):
        nonlocal last_activity_at
        created_at = row['created_at']
        if last_activity_at is None or created_at > last_activity_at:
            last_activity_at = created_at
        local_date = timezone.localtime(created_at, local_timezone).date()
        activity_dates.add(local_date)
        week_index = (local_date - first_week_start).days // 7
        if 0 <= week_index < WEEK_COUNT:
            weekly_activity[week_index][weekly_key] += 1
            weekly_activity[week_index]['activities'] += 1

    for row in attempt_rows:
        record_activity(row, 'attempts')
    for row in story_completion_rows:
        record_activity(row, 'story_completions')

    sorted_dates = sorted(activity_dates)
    longest_days = 0
    running_days = 0
    previous_date = None
    for activity_date in sorted_dates:
        if previous_date is not None and activity_date == previous_date + timedelta(days=1):
            running_days += 1
        else:
            running_days = 1
        longest_days = max(longest_days, running_days)
        previous_date = activity_date

    current_days = 0
    if sorted_dates and (local_today - sorted_dates[-1]).days in (0, 1):
        expected_date = sorted_dates[-1]
        for activity_date in reversed(sorted_dates):
            if activity_date != expected_date:
                break
            current_days += 1
            expected_date -= timedelta(days=1)

    return {
        'activity_streak': {
            'current_days': current_days,
            'longest_days': longest_days,
        },
        'weekly_activity': weekly_activity,
        'last_activity_at': (
            last_activity_at.astimezone(fixed_timezone.utc)
            .isoformat()
            .replace('+00:00', 'Z')
            if last_activity_at
            else None
        ),
    }


def _badge_payload(metrics: dict) -> tuple[list[dict], int]:
    badges = []
    earned_badges = 0
    for definition in BADGE_DEFINITIONS:
        actual_progress = max(int(metrics[definition['metric']]), 0)
        target = definition['target']
        earned = actual_progress >= target
        earned_badges += int(earned)
        badges.append(
            {
                key: value
                for key, value in definition.items()
                if key != 'metric'
            }
            | {
                'earned': earned,
                # The UI gets a bounded numerator; `earned` retains the real
                # threshold result when the underlying metric exceeds it.
                'progress': min(actual_progress, target),
            }
        )
    return badges, earned_badges


def build_kid_profile_summary(
    profile: KidProfile,
    *,
    timezone_offset_minutes: int = 0,
    now=None,
) -> dict:
    now = now or timezone.now()
    catalogue = _catalogue_progress(profile)
    attempt_rows = list(
        GameAttempt.objects.filter(profile=profile).values('game_id', 'created_at')
    )
    published_story_ids = set(
        Story.objects.filter(is_published=True).values_list('pk', flat=True)
    )
    story_event_rows = list(
        KidActivityEvent.objects.filter(profile=profile).values(
            'story_id',
            'event_type',
            'created_at',
        )
    )
    published_game_ids = catalogue.pop('published_game_ids')
    games_started = len(
        {
            row['game_id']
            for row in attempt_rows
            if row['game_id'] in published_game_ids
        }
    )

    stats = {
        'completed_game_levels': catalogue['completed_game_levels'],
        'total_game_levels': catalogue['total_game_levels'],
        'game_stars': catalogue['game_stars'],
        'max_game_stars': catalogue['max_game_stars'],
        'games_started': games_started,
        'games_completed': catalogue['games_completed'],
        'total_stories': len(published_story_ids),
        'stories_started': len(
            {
                row['story_id']
                for row in story_event_rows
                if row['story_id'] in published_story_ids
            }
        ),
        'stories_completed': len(
            {
                row['story_id']
                for row in story_event_rows
                if row['story_id'] in published_story_ids
                and row['event_type']
                == KidActivityEvent.EventType.STORY_COMPLETED
            }
        ),
    }
    badge_metrics = {
        **stats,
        'attempts': len(attempt_rows),
    }
    badges, earned_badges = _badge_payload(badge_metrics)
    stats['earned_badges'] = earned_badges

    activity = _activity_payload(
        attempt_rows,
        [
            row
            for row in story_event_rows
            if row['event_type'] == KidActivityEvent.EventType.STORY_COMPLETED
        ],
        timezone_offset_minutes=timezone_offset_minutes,
        now=now,
    )
    return {
        'profile': {
            'id': str(profile.pk),
            'display_name': profile.display_name,
            'avatar_key': profile.avatar_key,
        },
        'level': _level_payload(
            stats['completed_game_levels'],
            stats['game_stars'],
        ),
        'stats': stats,
        'badges': badges,
        **activity,
    }
