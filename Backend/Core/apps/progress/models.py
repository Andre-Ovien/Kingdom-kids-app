import uuid

from django.core.exceptions import ValidationError
from django.db import models

from apps.accounts.models import KidProfile
from apps.stories.models import Story


class KidActivityEvent(models.Model):
    """An immutable, idempotent record of a child's story activity."""

    class EventType(models.TextChoices):
        STORY_STARTED = 'story_started', 'Story started'
        STORY_COMPLETED = 'story_completed', 'Story completed'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(
        KidProfile,
        on_delete=models.CASCADE,
        related_name='activity_events',
    )
    operation_id = models.UUIDField()
    event_type = models.CharField(max_length=24, choices=EventType.choices)
    story = models.ForeignKey(
        Story,
        on_delete=models.PROTECT,
        related_name='kid_activity_events',
    )
    created_at = models.DateTimeField(auto_now_add=True)
    # Server-owned snapshot. Historical activity contributes to lifetime XP
    # without inventing a milestone receipt that was never presented.
    reward_receipt = models.JSONField(default=dict)

    class Meta:
        ordering = ('-created_at',)
        constraints = (
            models.UniqueConstraint(
                fields=('profile', 'operation_id'),
                name='unique_kid_activity_operation',
            ),
            models.CheckConstraint(
                condition=models.Q(
                    event_type__in=(
                        'story_started',
                        'story_completed',
                    )
                ),
                name='kid_activity_event_type_valid',
            ),
        )
        indexes = (
            models.Index(
                fields=('profile', 'event_type', '-created_at'),
                name='kid_act_profile_type_created',
            ),
        )

    def save(self, *args, **kwargs):
        if not self._state.adding:
            raise ValidationError('Kid activity events are immutable.')
        return super().save(*args, **kwargs)

    def delete(self, *args, **kwargs):
        raise ValidationError('Kid activity events are immutable.')

    def __str__(self) -> str:
        return f'{self.profile.display_name} · {self.event_type} · {self.story.title}'


class StreakDailyVisit(models.Model):
    """A server-owned daily app visit and its one streak presentation."""

    class State(models.TextChoices):
        FIRST_STREAK = 'first_streak', 'First streak'
        CONTINUED = 'continued', 'Continued streak'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(
        KidProfile,
        on_delete=models.CASCADE,
        related_name='streak_daily_visits',
    )
    local_date = models.DateField()
    state = models.CharField(max_length=16, choices=State.choices)
    timezone_offset_minutes = models.SmallIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)
    reward_receipt = models.JSONField(default=dict)

    class Meta:
        ordering = ('-created_at',)
        constraints = (
            models.UniqueConstraint(
                fields=('profile', 'local_date'),
                name='unique_kid_streak_daily_visit',
            ),
            models.CheckConstraint(
                condition=models.Q(
                    state__in=(
                        'first_streak',
                        'continued',
                    )
                ),
                name='kid_streak_daily_visit_state_valid',
            ),
            models.CheckConstraint(
                condition=models.Q(
                    timezone_offset_minutes__gte=-840,
                    timezone_offset_minutes__lte=840,
                ),
                name='kid_streak_visit_timezone_valid',
            ),
        )
        indexes = (
            models.Index(
                fields=('profile', '-local_date'),
                name='kid_visit_profile_date',
            ),
        )

    def __str__(self) -> str:
        return (
            f'{self.profile.display_name} · {self.state} · '
            f'{self.local_date.isoformat()}'
        )
