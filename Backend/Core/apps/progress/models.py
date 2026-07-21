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
