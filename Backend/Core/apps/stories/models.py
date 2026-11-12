import hashlib
import uuid
from urllib.parse import urlparse

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import (
    FileExtensionValidator,
    MaxValueValidator,
    MinValueValidator,
)
from django.db import models


def is_owned_https_media_url(value) -> bool:
    """Return whether a URL is safe to expose to a child's device."""

    if not value:
        return False
    try:
        parsed = urlparse(value)
        hostname = (parsed.hostname or '').lower()
        port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme.lower() == 'https'
        and bool(hostname)
        and hostname in settings.CONTENT_MEDIA_HOSTS
        and parsed.username is None
        and parsed.password is None
        and not parsed.fragment
        and port in {None, 443}
    )


def validate_owned_https_media_url(value):
    """Allow child-facing media only from explicitly owned HTTPS hosts."""

    if not value:
        return
    try:
        parsed = urlparse(value)
        hostname = (parsed.hostname or '').lower()
    except ValueError as exc:
        raise ValidationError(
            'External media URLs must be valid HTTPS URLs.'
        ) from exc
    if parsed.scheme.lower() != 'https' or not hostname:
        raise ValidationError('External media URLs must use HTTPS.')
    if not is_owned_https_media_url(value):
        raise ValidationError(
            'External media must use a host listed in DJANGO_CONTENT_MEDIA_HOSTS.'
        )


def validate_audio_upload(upload):
    """Apply a small size limit and reject obvious extension spoofing."""

    if upload.size > settings.MAX_NARRATOR_AUDIO_BYTES:
        raise ValidationError('Narrator audio exceeds the configured size limit.')

    original_position = upload.tell() if hasattr(upload, 'tell') else None
    header = upload.read(12)
    if original_position is not None:
        upload.seek(original_position)
    signatures = (
        header.startswith(b'ID3'),
        header.startswith((b'\xff\xfb', b'\xff\xf3', b'\xff\xf2')),
        header.startswith((b'\xff\xf1', b'\xff\xf9')),
        header.startswith(b'RIFF') and header[8:12] == b'WAVE',
        len(header) >= 8 and header[4:8] == b'ftyp',
    )
    if not any(signatures):
        raise ValidationError('Narrator audio content does not match an allowed format.')


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
    cover_image_url = models.URLField(
        blank=True,
        null=True,
        validators=(validate_owned_https_media_url,),
    )
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
            validate_audio_upload,
        ),
    )
    sample_url = models.URLField(
        blank=True,
        null=True,
        validators=(validate_owned_https_media_url,),
    )
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

    @property
    def available_sample_url(self) -> str | None:
        if self.cached_sample_available:
            try:
                url = self.sample_audio.url
                if settings.DEBUG or is_owned_https_media_url(url):
                    return url
            except (OSError, ValueError):
                pass
        if is_owned_https_media_url(self.sample_url):
            return self.sample_url
        return None


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
    audio_url = models.URLField(
        blank=True,
        null=True,
        validators=(validate_owned_https_media_url,),
    )
    audio_file = models.FileField(
        upload_to='character_narration/',
        blank=True,
        max_length=255,
        validators=(
            FileExtensionValidator(allowed_extensions=('mp3', 'm4a', 'aac', 'wav')),
            validate_audio_upload,
        ),
    )
    # Bind generated audio and its passage timings to the exact story revision.
    # Old tracks must not keep reading a different body after an editor changes it.
    text_sha256 = models.CharField(max_length=64, blank=True)
    segments = models.JSONField(default=list, blank=True)
    words = models.JSONField(default=list, blank=True)
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
        if self.status != self.Status.READY:
            return False
        if self.text_sha256 and not self.matches_story_text:
            return False
        return bool(self.available_audio_url)

    @property
    def matches_story_text(self) -> bool:
        return self.text_sha256 == hashlib.sha256(
            self.story.body.encode('utf-8'),
        ).hexdigest()

    @property
    def available_audio_url(self) -> str | None:
        if self.audio_file and self.matches_story_text:
            try:
                if self.audio_file.storage.exists(self.audio_file.name):
                    url = self.audio_file.url
                    if settings.DEBUG or is_owned_https_media_url(url):
                        return url
            except (OSError, ValueError):
                pass
        if is_owned_https_media_url(self.audio_url):
            return self.audio_url
        return None

    def __str__(self) -> str:
        return f'{self.story.title} — {self.narrator.display_name}'
