import uuid

from django.core.validators import (
    FileExtensionValidator,
    MaxValueValidator,
    MinValueValidator,
)
from django.db import models


class Story(models.Model):
    """A published story that can be read or narrated in the mobile app."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    slug = models.SlugField(max_length=120, unique=True)
    title = models.CharField(max_length=160)
    author = models.CharField(max_length=120, default='Kingdom Kids')
    category = models.CharField(max_length=80)
    summary = models.TextField()
    body = models.TextField()
    # The first catalogue ships with bundled artwork. A hosted URL can replace
    # it later without changing the API contract or app model.
    cover_asset_key = models.CharField(max_length=180, blank=True)
    cover_image_url = models.URLField(blank=True, null=True)
    cover_focus_x = models.FloatField(
        default=0,
        validators=(MinValueValidator(-1), MaxValueValidator(1)),
    )
    cover_focus_y = models.FloatField(
        default=0,
        validators=(MinValueValidator(-1), MaxValueValidator(1)),
    )
    rating = models.DecimalField(
        max_digits=2,
        decimal_places=1,
        default=4.8,
        validators=(MinValueValidator(0), MaxValueValidator(5)),
    )
    review_count = models.PositiveIntegerField(default=0)
    reading_time_minutes = models.PositiveSmallIntegerField(default=2)
    is_featured = models.BooleanField(default=False)
    is_published = models.BooleanField(default=True)
    sort_order = models.PositiveSmallIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ('sort_order', 'title')

    def __str__(self) -> str:
        return self.title


class NarratorVoice(models.Model):
    """Provider-neutral voice personality attached to a profile character."""

    avatar_key = models.CharField(max_length=16, primary_key=True)
    voice_key = models.SlugField(max_length=40, unique=True)
    display_name = models.CharField(max_length=60)
    voice_description = models.CharField(max_length=160)
    locale = models.CharField(max_length=16, default='en-US')
    speech_rate = models.FloatField(
        default=0.45,
        validators=(MinValueValidator(0.1), MaxValueValidator(1)),
    )
    pitch = models.FloatField(
        default=1,
        validators=(MinValueValidator(0.5), MaxValueValidator(2)),
    )
    # Locally cached auditions live beneath MEDIA_ROOT. ``sample_url`` remains
    # available as a hosted/CDN fallback, while the public API always exposes a
    # single computed sample_url and never leaks the provider identifiers.
    sample_audio = models.FileField(
        upload_to='voice_auditions/',
        blank=True,
        max_length=255,
        validators=(
            FileExtensionValidator(
                allowed_extensions=('mp3', 'm4a', 'aac', 'wav'),
            ),
        ),
    )
    sample_url = models.URLField(blank=True, null=True)
    # Provider settings are intentionally private and are never serialized.
    provider = models.CharField(max_length=40, blank=True)
    provider_voice_id = models.CharField(max_length=160, blank=True)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ('display_name',)

    def __str__(self) -> str:
        return self.display_name

    @property
    def cached_sample_available(self) -> bool:
        """Return true only when the configured cached file still exists."""

        if not self.sample_audio:
            return False
        try:
            return self.sample_audio.storage.exists(self.sample_audio.name)
        except OSError:
            # A missing/unmounted development media directory must not make the
            # story-detail endpoint fail. The hosted URL can still be used.
            return False


class StoryNarration(models.Model):
    """Narrator availability for one story, ready for cached audio later."""

    class Status(models.TextChoices):
        DEVICE_TTS = 'device_tts', 'Device text-to-speech'
        PROCESSING = 'processing', 'Processing hosted audio'
        READY = 'ready', 'Hosted audio ready'
        UNAVAILABLE = 'unavailable', 'Unavailable'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    story = models.ForeignKey(
        Story,
        on_delete=models.CASCADE,
        related_name='narrations',
    )
    narrator = models.ForeignKey(
        NarratorVoice,
        on_delete=models.PROTECT,
        related_name='story_narrations',
    )
    status = models.CharField(
        max_length=20,
        choices=Status.choices,
        default=Status.DEVICE_TTS,
    )
    audio_url = models.URLField(blank=True, null=True)
    duration_seconds = models.PositiveIntegerField(blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ('narrator__display_name',)
        constraints = (
            models.UniqueConstraint(
                fields=('story', 'narrator'),
                name='unique_story_narrator',
            ),
        )

    @property
    def audio_available(self) -> bool:
        return self.status == self.Status.READY and bool(self.audio_url)

    def __str__(self) -> str:
        return f'{self.story.title} — {self.narrator.display_name}'
