import uuid

from django.core.exceptions import ValidationError
from django.db import models

from apps.accounts.models import KidProfile


def default_star_thresholds():
    return [60, 80, 95]


class Game(models.Model):
    """A published mini-game whose rules and levels are owned by the backend."""

    class Type(models.TextChoices):
        QUIZ = 'quiz', 'Quiz'
        MEMORY = 'memory', 'Memory cards'
        ORDERING = 'ordering', 'Ordering'
        MATCHING = 'matching', 'Matching'
        MAZE = 'maze', 'Maze'
        PATH = 'path', 'Path finding'
        AIM = 'aim', 'Aim'
        PUZZLE = 'puzzle', 'Puzzle'

    class Difficulty(models.TextChoices):
        EASY = 'Easy', 'Easy'
        MEDIUM = 'Medium', 'Medium'
        CHALLENGING = 'Challenging', 'Challenging'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    slug = models.SlugField(max_length=120, unique=True)
    title = models.CharField(max_length=120)
    subtitle = models.CharField(max_length=180)
    description = models.TextField()
    game_type = models.CharField(max_length=16, choices=Type.choices)
    difficulty = models.CharField(
        max_length=16,
        choices=Difficulty.choices,
        default=Difficulty.EASY,
    )
    estimated_duration_seconds = models.PositiveSmallIntegerField(default=180)
    cover_asset_key = models.CharField(max_length=200)
    accent_color = models.CharField(max_length=9, default='#6C5CE7')
    icon_key = models.CharField(max_length=40, default='sparkles')
    is_featured = models.BooleanField(default=False)
    is_published = models.BooleanField(default=True)
    sort_order = models.PositiveSmallIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ('sort_order', 'title')

    def __str__(self) -> str:
        return self.title

    def clean(self):
        super().clean()
        if self._state.adding:
            return
        previous_type = (
            self.__class__.objects.filter(pk=self.pk)
            .values_list('game_type', flat=True)
            .first()
        )
        if previous_type == self.game_type:
            return
        from .validators import validate_level_definition

        for level in self.levels.all():
            try:
                validate_level_definition(
                    game_type=self.game_type,
                    config=level.config,
                    max_score=level.max_score,
                    star_thresholds=level.star_thresholds,
                )
            except ValidationError as exc:
                raise ValidationError(
                    {
                        'game_type': (
                            f'Level {level.level_number} is incompatible with '
                            f'{self.get_game_type_display()}: {exc}'
                        )
                    }
                ) from exc

    def save(self, *args, **kwargs):
        self.full_clean()
        return super().save(*args, **kwargs)


class GameLevel(models.Model):
    """One ordered, backend-authored challenge within a game."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    game = models.ForeignKey(
        Game,
        on_delete=models.CASCADE,
        related_name='levels',
    )
    level_number = models.PositiveSmallIntegerField()
    title = models.CharField(max_length=120)
    instructions = models.CharField(max_length=240)
    # Config contains both presentation data and private answer keys. API
    # serializers remove answer keys before returning a level to a device.
    config = models.JSONField(default=dict)
    max_score = models.PositiveSmallIntegerField(default=100)
    star_thresholds = models.JSONField(default=default_star_thresholds)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ('level_number',)
        constraints = (
            models.CheckConstraint(
                condition=models.Q(level_number__gte=1),
                name='game_level_number_at_least_one',
            ),
            models.UniqueConstraint(
                fields=('game', 'level_number'),
                name='unique_game_level_number',
            ),
        )

    def __str__(self) -> str:
        return f'{self.game.title} · Level {self.level_number}'

    def clean(self):
        super().clean()
        from .validators import validate_level_definition

        validate_level_definition(
            game_type=self.game.game_type,
            config=self.config,
            max_score=self.max_score,
            star_thresholds=self.star_thresholds,
        )

    def save(self, *args, **kwargs):
        self.full_clean()
        sibling_numbers = list(
            self.__class__.objects.filter(game=self.game)
            .exclude(pk=self.pk)
            .values_list('level_number', flat=True)
        )
        numbers = sorted([*sibling_numbers, self.level_number])
        if numbers != list(range(1, len(numbers) + 1)):
            raise ValidationError(
                {'level_number': 'Game levels must remain contiguous from level one.'}
            )
        return super().save(*args, **kwargs)

    def delete(self, *args, **kwargs):
        remaining = sorted(
            self.__class__.objects.filter(game=self.game)
            .exclude(pk=self.pk)
            .values_list('level_number', flat=True)
        )
        if remaining != list(range(1, len(remaining) + 1)):
            raise ValidationError(
                'Delete higher levels before removing a level from the middle.'
            )
        return super().delete(*args, **kwargs)


class KidGameProgress(models.Model):
    """A compact, query-friendly summary of one child's game journey."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(
        KidProfile,
        on_delete=models.CASCADE,
        related_name='game_progress',
    )
    game = models.ForeignKey(
        Game,
        on_delete=models.CASCADE,
        related_name='kid_progress',
    )
    highest_completed_level = models.PositiveSmallIntegerField(default=0)
    total_stars = models.PositiveSmallIntegerField(default=0)
    # Keys are level numbers as strings. Each value stores the best score,
    # best stars, completion state, and number of evaluated attempts.
    level_progress = models.JSONField(default=dict)
    last_played_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ('game__sort_order',)
        constraints = (
            models.UniqueConstraint(
                fields=('profile', 'game'),
                name='unique_kid_game_progress',
            ),
        )

    def __str__(self) -> str:
        return f'{self.profile.display_name} · {self.game.title}'


class GameAttempt(models.Model):
    """An immutable, idempotent record of a server-evaluated game result."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    operation_id = models.UUIDField()
    profile = models.ForeignKey(
        KidProfile,
        on_delete=models.CASCADE,
        related_name='game_attempts',
    )
    game = models.ForeignKey(
        Game,
        on_delete=models.PROTECT,
        related_name='attempts',
    )
    level = models.ForeignKey(
        GameLevel,
        on_delete=models.PROTECT,
        related_name='attempts',
    )
    submitted_result = models.JSONField(default=dict)
    completed = models.BooleanField(default=False)
    score = models.PositiveSmallIntegerField(default=0)
    stars = models.PositiveSmallIntegerField(default=0)
    feedback = models.CharField(max_length=240)
    evaluation = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ('-created_at',)
        constraints = (
            models.UniqueConstraint(
                fields=('profile', 'operation_id'),
                name='unique_kid_game_operation',
            ),
        )
        indexes = (
            models.Index(
                fields=('profile', 'game', '-created_at'),
                name='game_attempt_profile_game',
            ),
        )

    def __str__(self) -> str:
        return f'{self.profile.display_name} · {self.game.slug} · {self.score}'

    def save(self, *args, **kwargs):
        if not self._state.adding:
            raise ValidationError('Game attempts are immutable.')
        return super().save(*args, **kwargs)

    def delete(self, *args, **kwargs):
        raise ValidationError('Game attempts are immutable.')
