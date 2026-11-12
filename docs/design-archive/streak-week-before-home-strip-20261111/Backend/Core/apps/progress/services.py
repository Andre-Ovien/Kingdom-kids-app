from datetime import date, timedelta, timezone as fixed_timezone

from django.db import transaction
from django.db.models import Count, Max, Prefetch, Q
from django.db.models.functions import TruncDate
from django.utils import timezone

from apps.accounts.models import KidProfile, KidProfilePreferences
from apps.games.models import Game, GameAttempt, GameLevel, KidGameProgress
from apps.stories.models import Story

from .models import KidActivityEvent, StreakDailyVisit
from .progression import (
    LEGACY_COMPLETION_XP,
    LEVEL_TITLES,
    MAX_LEVEL,
    XP_PER_COMPLETED_LEVEL,
    XP_PER_COMPLETED_STORY,
    XP_PER_LEVEL,
    XP_PER_STAR,
    XP_PER_STREAK_DAY,
    earned_completion_xp,
)


WEEK_COUNT = 5
RECENT_STREAK_DAY_COUNT = 7
STREAK_TIMEZONE_CHANGE_COOLDOWN = timedelta(hours=24)


class StreakTimezoneChangeTooSoon(Exception):
    def __init__(self, retry_after: int):
        super().__init__('The streak timezone cannot be changed yet.')
        self.retry_after = retry_after

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
    return LEVEL_TITLES[min(max(level_number, 1), MAX_LEVEL) - 1]


def _level_payload(xp: int) -> dict:
    number = min(xp // XP_PER_LEVEL + 1, MAX_LEVEL)
    is_max_level = number == MAX_LEVEL
    return {
        'number': number,
        'title': _title_for_level(number),
        'xp': xp,
        # This is an absolute lifetime-XP threshold, not XP remaining.
        # At the cap this remains numeric for older clients and represents
        # the attained final threshold. New clients use is_max_level.
        'next_level_xp': (number - int(is_max_level)) * XP_PER_LEVEL,
        'max_level': MAX_LEVEL,
        'is_max_level': is_max_level,
    }


def _catalogue_progress(profile: KidProfile) -> dict:
    """Summarize playable progress while retaining earned XP from retired games."""

    games = list(
        Game.objects.all()
        .prefetch_related(
            Prefetch(
                'levels',
                queryset=GameLevel.objects.only('id', 'game_id', 'level_number')
                .order_by('level_number'),
            ),
        )
        .order_by('sort_order', 'title')
    )
    game_ids = {game.pk for game in games if game.is_published}
    progress_by_game = {
        progress.game_id: progress
        for progress in KidGameProgress.objects.filter(
            profile=profile,
            game_id__in={game.pk for game in games},
        )
    }

    completed_game_levels = 0
    game_stars = 0
    games_completed = 0
    total_game_levels = 0
    quest_xp = 0

    for game in games:
        level_numbers = {level.level_number for level in game.levels.all()}
        if game.is_published:
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
            if game.is_published:
                game_stars += _safe_stars(item.get('best_stars', 0))
            quest_xp += (
                earned_completion_xp(item)
                + _safe_stars(item.get('best_stars', 0)) * XP_PER_STAR
            )
            if item.get('completed') is True:
                completed_numbers.add(level_number)

        if game.is_published:
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
        'quest_xp': quest_xp,
    }


def build_profile_xp_breakdown(
    profile: KidProfile, *, catalogue=None, streak_visit_count=None,
) -> dict:
    """Count earned learning XP, independently of repeat activity receipts."""

    catalogue = catalogue if catalogue is not None else _catalogue_progress(profile)
    completion_receipts = (
        KidActivityEvent.objects.filter(
            profile=profile,
            event_type=KidActivityEvent.EventType.STORY_COMPLETED,
        )
        .order_by()
        .values_list('story_id', 'reward_receipt')
    )
    story_xp = {}
    for story_id, receipt in completion_receipts:
        amount = receipt.get('xp_awarded') if isinstance(receipt, dict) else None
        if type(amount) is not int or amount < 0:
            amount = LEGACY_COMPLETION_XP
        # One completion award per story; later reads have zero-XP receipts.
        # Historical empty receipts retain their original 100 XP.
        story_xp[story_id] = max(story_xp.get(story_id, 0), amount)
    return {
        'quests': catalogue['quest_xp'],
        # Retiring a story must not erase a child's earned learning XP.
        'stories': sum(story_xp.values()),
        'streaks': (
            StreakDailyVisit.objects.filter(profile=profile).count()
            if streak_visit_count is None else streak_visit_count
        ) * XP_PER_STREAK_DAY,
    }


def build_profile_level(profile: KidProfile) -> dict:
    """Return the same combined learning level displayed in the profile summary."""

    return _level_payload(sum(build_profile_xp_breakdown(profile).values()))


def build_reward_receipt(previous_level: dict, *, xp_awarded: int) -> dict:
    """Snapshot this operation's reward before creating its immutable record."""

    current_level = _level_payload(previous_level['xp'] + xp_awarded)
    return {
        'xp_awarded': xp_awarded,
        'level_milestone': (
            {
                'previous_level': previous_level['number'],
                'level': current_level,
            }
            if current_level['number'] > previous_level['number']
            else None
        ),
    }


def milestone_reward_payload(milestone) -> dict | None:
    """Present saved milestones under current ranks without changing the ledger."""

    if not isinstance(milestone, dict):
        return None
    previous = milestone.get('previous_level')
    level = milestone.get('level')
    if not isinstance(level, dict):
        return None
    number = level.get('number')
    xp = level.get('xp')
    if (
        type(previous) is not int
        or type(number) is not int
        or not 1 <= previous < number <= MAX_LEVEL
        or type(xp) is not int
        or xp < 0
    ):
        return None
    current_level = _level_payload(xp)
    if current_level['number'] != number:
        return None
    return {**milestone, 'level': {**level, **current_level}}


def activity_reward_payload(receipt) -> dict:
    """Historical records count toward XP but never invent old celebrations."""

    receipt = receipt if isinstance(receipt, dict) else {}
    return {
        'xp_awarded': receipt.get('xp_awarded', 0),
        'level_milestone': milestone_reward_payload(receipt.get('level_milestone')),
    }


def _week_label(week_start: date) -> str:
    return f'{MONTH_LABELS[week_start.month]} {week_start.day}'


def _activity_payload(
    attempt_daily_rows: list[dict],
    story_completion_daily_rows: list[dict],
    *,
    timezone_offset_minutes: int,
    now,
    last_activity_at=None,
    additional_streak_dates: set[date] | None = None,
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

    def record_daily_activity(row, weekly_key):
        local_date = row['local_date']
        activity_dates.add(local_date)
        week_index = (local_date - first_week_start).days // 7
        if 0 <= week_index < WEEK_COUNT:
            count = row['count']
            weekly_activity[week_index][weekly_key] += count
            weekly_activity[week_index]['activities'] += count

    for row in attempt_daily_rows:
        record_daily_activity(row, 'attempts')
    for row in story_completion_daily_rows:
        record_daily_activity(row, 'story_completions')
    activity_dates.update(additional_streak_dates or ())
    activity_dates = {
        activity_date
        for activity_date in activity_dates
        if activity_date <= local_today
    }

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


def _streak_activity_dates(
    profile: KidProfile,
    *,
    local_timezone,
) -> set[date]:
    """Return local dates that already contribute to this child's streak."""

    attempt_dates = (
        GameAttempt.objects.filter(profile=profile)
        .annotate(activity_date=TruncDate('created_at', tzinfo=local_timezone))
        .order_by()
        .values_list('activity_date', flat=True)
        .distinct()
    )
    story_completion_dates = (
        KidActivityEvent.objects.filter(
            profile=profile,
            event_type=KidActivityEvent.EventType.STORY_COMPLETED,
        )
        .annotate(activity_date=TruncDate('created_at', tzinfo=local_timezone))
        .order_by()
        .values_list('activity_date', flat=True)
        .distinct()
    )
    activity_dates = set(attempt_dates) | set(story_completion_dates)
    activity_dates.update(
        StreakDailyVisit.objects.filter(profile=profile).values_list(
            'local_date',
            flat=True,
        )
    )
    return activity_dates


def _streak_totals(activity_dates: set[date], *, local_today: date) -> tuple[int, int]:
    """Calculate longest and current streaks with the existing one-day grace."""

    sorted_dates = sorted(
        activity_date
        for activity_date in activity_dates
        if activity_date <= local_today
    )
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
    return current_days, longest_days


def claim_streak_presentation(
    profile: KidProfile,
    *,
    timezone_offset_minutes: int,
    now=None,
) -> dict:
    """Atomically claim the streak moment currently due for one child.

    Reaching Home is itself the daily visit, so this command adds the server's
    current local date before calculating the streak. The first call for that
    profile/date records the visit and returns its celebration; later calls
    replay its reward receipt without another streak presentation. At-risk
    reminders are device notifications and never a screen state.
    """

    now = now or timezone.now()
    with transaction.atomic():
        locked_profile = KidProfile.objects.select_for_update().get(pk=profile.pk)
        preferences, _ = KidProfilePreferences.objects.get_or_create(
            profile=locked_profile,
        )

        bound_offset = preferences.streak_timezone_offset_minutes
        if bound_offset is not None and bound_offset != timezone_offset_minutes:
            latest_visit = StreakDailyVisit.objects.filter(
                profile=locked_profile,
            ).order_by('-created_at').first()
            change_available_at = (
                latest_visit.created_at + STREAK_TIMEZONE_CHANGE_COOLDOWN
                if latest_visit is not None
                else now
            )
            if change_available_at > now:
                retry_after = max(
                    1,
                    int((change_available_at - now).total_seconds()),
                )
                raise StreakTimezoneChangeTooSoon(retry_after)

        if bound_offset != timezone_offset_minutes:
            preferences.streak_timezone_offset_minutes = timezone_offset_minutes
            preferences.save(
                update_fields=('streak_timezone_offset_minutes', 'updated_at')
            )

        local_timezone = fixed_timezone(
            timedelta(minutes=timezone_offset_minutes)
        )
        local_now = timezone.localtime(now, local_timezone)
        local_today = local_now.date()
        activity_dates = _streak_activity_dates(
            locked_profile,
            local_timezone=local_timezone,
        )
        activity_dates.add(local_today)
        current_days, longest_days = _streak_totals(
            activity_dates,
            local_today=local_today,
        )

        state = (
            StreakDailyVisit.State.FIRST_STREAK
            if current_days == 1
            else StreakDailyVisit.State.CONTINUED
        )
        visit = StreakDailyVisit.objects.filter(
            profile=locked_profile,
            local_date=local_today,
        ).first()
        created = visit is None
        if created:
            reward_receipt = build_reward_receipt(
                build_profile_level(locked_profile),
                xp_awarded=XP_PER_STREAK_DAY,
            )
            visit = StreakDailyVisit.objects.create(
                profile=locked_profile,
                local_date=local_today,
                state=state,
                timezone_offset_minutes=timezone_offset_minutes,
                reward_receipt=reward_receipt,
            )
        response = {
            'show': created,
            'profile_id': str(locked_profile.pk),
            **activity_reward_payload(visit.reward_receipt),
        }
    if not created:
        return response

    first_recent_date = local_today - timedelta(
        days=RECENT_STREAK_DAY_COUNT - 1
    )
    response['presentation'] = {
        'profile': {
            'id': str(profile.pk),
            'parent_id': str(locked_profile.parent_id),
            'display_name': locked_profile.display_name,
            'avatar_key': locked_profile.avatar_key,
        },
        'state': state,
        'current_days': current_days,
        'longest_days': longest_days,
        'local_date': local_today.isoformat(),
        'recent_days': [
            {
                'date': (first_recent_date + timedelta(days=index)).isoformat(),
                'active': (
                    first_recent_date + timedelta(days=index)
                    in activity_dates
                ),
            }
            for index in range(RECENT_STREAK_DAY_COUNT)
        ],
    }
    return response


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
    bound_offset = KidProfilePreferences.objects.filter(
        profile=profile,
        streak_timezone_offset_minutes__isnull=False,
    ).values_list('streak_timezone_offset_minutes', flat=True).first()
    if bound_offset is not None:
        timezone_offset_minutes = bound_offset
    local_timezone = fixed_timezone(timedelta(minutes=timezone_offset_minutes))
    local_today = timezone.localtime(now, local_timezone).date()
    catalogue = _catalogue_progress(profile)
    visit_dates = list(
        StreakDailyVisit.objects.filter(profile=profile)
        .values_list('local_date', flat=True)
    )
    xp_breakdown = build_profile_xp_breakdown(
        profile, catalogue=catalogue, streak_visit_count=len(visit_dates),
    )
    attempt_queryset = GameAttempt.objects.filter(profile=profile)
    story_event_queryset = KidActivityEvent.objects.filter(profile=profile)
    story_completion_queryset = story_event_queryset.filter(
        event_type=KidActivityEvent.EventType.STORY_COMPLETED,
    )
    published_game_ids = catalogue.pop('published_game_ids')
    attempt_totals = attempt_queryset.aggregate(
        attempts=Count('pk'),
        games_started=Count(
            'game_id', filter=Q(game_id__in=published_game_ids), distinct=True,
        ),
        latest=Max('created_at'),
    )
    completed_story = Q(event_type=KidActivityEvent.EventType.STORY_COMPLETED)
    story_totals = story_event_queryset.aggregate(
        started=Count('story_id', filter=Q(story__is_published=True), distinct=True),
        completed=Count(
            'story_id', filter=Q(story__is_published=True) & completed_story,
            distinct=True,
        ),
        latest=Max('created_at', filter=completed_story),
    )

    stats = {
        'completed_game_levels': catalogue['completed_game_levels'],
        'total_game_levels': catalogue['total_game_levels'],
        'game_stars': catalogue['game_stars'],
        'max_game_stars': catalogue['max_game_stars'],
        'games_started': attempt_totals['games_started'],
        'games_completed': catalogue['games_completed'],
        'total_stories': Story.objects.filter(is_published=True).count(),
        'stories_started': story_totals['started'],
        'stories_completed': story_totals['completed'],
    }
    badge_metrics = {
        **stats,
        'attempts': attempt_totals['attempts'],
    }
    badges, earned_badges = _badge_payload(badge_metrics)
    stats['earned_badges'] = earned_badges

    attempt_daily_rows = list(
        attempt_queryset
        .annotate(local_date=TruncDate('created_at', tzinfo=local_timezone))
        .order_by()
        .values('local_date')
        .annotate(count=Count('pk'))
    )
    story_completion_daily_rows = list(
        story_completion_queryset
        .annotate(local_date=TruncDate('created_at', tzinfo=local_timezone))
        .order_by()
        .values('local_date')
        .annotate(count=Count('pk'))
    )
    latest_activity_values = (
        attempt_totals['latest'],
        story_totals['latest'],
    )
    last_activity_at = max(
        (value for value in latest_activity_values if value is not None),
        default=None,
    )
    activity = _activity_payload(
        attempt_daily_rows,
        story_completion_daily_rows,
        timezone_offset_minutes=timezone_offset_minutes,
        now=now,
        last_activity_at=last_activity_at,
        # The daily groups include history, so the same two queries drive both
        # the five-week graph and lifetime streaks without duplicate date scans.
        additional_streak_dates=set(visit_dates),
    )
    return {
        'profile': {
            'id': str(profile.pk),
            'display_name': profile.display_name,
            'avatar_key': profile.avatar_key,
        },
        'level': _level_payload(sum(xp_breakdown.values())),
        'xp_breakdown': xp_breakdown,
        'stats': stats,
        'badges': badges,
        **activity,
    }
