import uuid

from django.contrib.auth.models import AbstractUser, BaseUserManager
from django.conf import settings
from django.db import models
from django.db.models.functions import Lower
from django.utils import timezone


class UserManager(BaseUserManager):
    """User manager that makes email the only login identifier."""

    def normalize_email(self, email: str) -> str:
        """Store emails consistently so email login is case-insensitive."""
        if not email:
            return email
        return super().normalize_email(email.strip()).lower()

    def create_user(self, email: str, password: str | None = None, **extra_fields):
        if not email:
            raise ValueError('An email address is required.')
        if not password:
            raise ValueError('A password is required.')

        user = self.model(email=self.normalize_email(email), **extra_fields)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email: str, password: str | None = None, **extra_fields):
        extra_fields.setdefault('is_staff', True)
        extra_fields.setdefault('is_superuser', True)
        extra_fields.setdefault('is_active', True)
        extra_fields.setdefault('email_verified_at', timezone.now())

        if extra_fields.get('is_staff') is not True:
            raise ValueError('Superusers must have is_staff=True.')
        if extra_fields.get('is_superuser') is not True:
            raise ValueError('Superusers must have is_superuser=True.')

        return self.create_user(email, password, **extra_fields)


class User(AbstractUser):
    """A parent account authenticated solely with an email address."""

    username = None
    email = models.EmailField('email address', unique=True)
    email_verified_at = models.DateTimeField(null=True, blank=True)
    email_verification_failed_attempts = models.PositiveIntegerField(default=0)
    email_verification_failure_window_started_at = models.DateTimeField(
        null=True,
        blank=True,
    )
    email_verification_locked_until = models.DateTimeField(null=True, blank=True)

    USERNAME_FIELD = 'email'
    REQUIRED_FIELDS: list[str] = []

    objects = UserManager()

    class Meta(AbstractUser.Meta):
        constraints = (
            models.UniqueConstraint(
                Lower('email'),
                name='user_email_ci_unique',
            ),
        )

    def save(self, *args, **kwargs):
        self.email = self.__class__.objects.normalize_email(self.email)
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.email

    @property
    def is_email_verified(self) -> bool:
        return self.email_verified_at is not None


class EmailVerificationChallenge(models.Model):
    """A short-lived, single-use proof of control over a parent's email."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='email_verification_challenges',
    )
    # A keyed digest is stored instead of the six-digit code. A database leak
    # must not reveal a code that is still valid in a parent's inbox.
    code_digest = models.CharField(max_length=64)
    expires_at = models.DateTimeField()
    resend_available_at = models.DateTimeField()
    # Per-code telemetry only. Enforcement uses the User-level rolling state so
    # replacing a challenge cannot restore the parent's guess budget.
    attempt_count = models.PositiveSmallIntegerField(default=0)
    max_attempts = models.PositiveSmallIntegerField(default=5)
    consumed_at = models.DateTimeField(null=True, blank=True)
    invalidated_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ('-created_at',)
        indexes = (
            models.Index(
                fields=('user', '-created_at'),
                name='email_verify_user_created',
            ),
            models.Index(fields=('expires_at',), name='email_verify_expires'),
        )

    def __str__(self) -> str:
        return f'{self.user.email} ({self.created_at:%Y-%m-%d %H:%M})'


class PasswordResetChallenge(models.Model):
    """A short-lived, single-use password recovery proof."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='password_reset_challenges',
    )
    code_digest = models.CharField(max_length=64)
    expires_at = models.DateTimeField()
    attempt_count = models.PositiveSmallIntegerField(default=0)
    max_attempts = models.PositiveSmallIntegerField(default=5)
    consumed_at = models.DateTimeField(null=True, blank=True)
    invalidated_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ('-created_at',)
        indexes = (
            models.Index(
                fields=('user', '-created_at'),
                name='pwd_reset_user_created',
            ),
            models.Index(fields=('expires_at',), name='pwd_reset_expires'),
        )
        constraints = (
            models.CheckConstraint(
                condition=(
                    models.Q(max_attempts__gt=0)
                    & models.Q(attempt_count__lte=models.F('max_attempts'))
                ),
                name='pwd_reset_attempts_valid',
            ),
            models.UniqueConstraint(
                fields=('user',),
                condition=(
                    models.Q(consumed_at__isnull=True)
                    & models.Q(invalidated_at__isnull=True)
                ),
                name='unique_active_password_reset',
            ),
        )

    def __str__(self) -> str:
        # Avoid putting a parent's email or the bearer-like challenge ID into
        # incidental admin and log representations.
        return f'Password reset challenge ({self.created_at:%Y-%m-%d %H:%M})'


class AccountDeletionChallenge(models.Model):
    """A short-lived, single-use proof authorizing account deletion."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='account_deletion_challenges',
    )
    code_digest = models.CharField(max_length=64)
    expires_at = models.DateTimeField()
    attempt_count = models.PositiveSmallIntegerField(default=0)
    max_attempts = models.PositiveSmallIntegerField(default=5)
    consumed_at = models.DateTimeField(null=True, blank=True)
    invalidated_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ('-created_at',)
        indexes = (
            models.Index(
                fields=('user', '-created_at'),
                name='acct_delete_user_created',
            ),
            models.Index(fields=('expires_at',), name='acct_delete_expires'),
        )
        constraints = (
            models.CheckConstraint(
                condition=(
                    models.Q(max_attempts__gt=0)
                    & models.Q(attempt_count__lte=models.F('max_attempts'))
                ),
                name='acct_delete_attempts_valid',
            ),
            models.UniqueConstraint(
                fields=('user',),
                condition=(
                    models.Q(consumed_at__isnull=True)
                    & models.Q(invalidated_at__isnull=True)
                ),
                name='unique_active_account_deletion',
            ),
        )

    def __str__(self) -> str:
        return f'Account deletion challenge ({self.created_at:%Y-%m-%d %H:%M})'


class WaitlistSubscriber(models.Model):
    """An explicit request to hear when Kingdom Kids becomes available."""

    class ConsentSource(models.TextChoices):
        WEBSITE_FOOTER = 'website_footer', 'Website footer'

    email = models.EmailField(max_length=254)
    consented_at = models.DateTimeField(default=timezone.now, editable=False)
    consent_source = models.CharField(
        max_length=32,
        choices=ConsentSource.choices,
        default=ConsentSource.WEBSITE_FOOTER,
        editable=False,
    )
    # Only an explicit signup submission requests this one confirmation; adding
    # these nullable fields never schedules mail for pre-existing subscribers.
    confirmation_sent_at = models.DateTimeField(null=True, blank=True, editable=False)
    confirmation_claim_id = models.UUIDField(null=True, blank=True, editable=False)
    confirmation_lease_until = models.DateTimeField(null=True, blank=True, editable=False)
    confirmation_first_attempt_at = models.DateTimeField(null=True, blank=True, editable=False)

    class Meta:
        ordering = ('-consented_at',)
        constraints = (
            models.UniqueConstraint(
                Lower('email'),
                name='waitlist_email_ci_unique',
            ),
        )

    def save(self, *args, **kwargs):
        self.email = User.objects.normalize_email(self.email)
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.email


class KidProfile(models.Model):
    """A minimal child profile owned by exactly one parent account."""

    class AvatarKey(models.TextChoices):
        LION = 'lion', 'Lion'
        DOVE = 'dove', 'Dove'
        RAINBOW = 'rainbow', 'Rainbow'
        STAR = 'star', 'Star'
        CROWN = 'crown', 'Crown'
        SHEEP = 'sheep', 'Sheep'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    parent = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='kid_profiles',
    )
    display_name = models.CharField(max_length=40)
    avatar_key = models.CharField(max_length=16, choices=AvatarKey.choices)
    creation_operation_id = models.UUIDField(
        null=True,
        blank=True,
        editable=False,
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ('created_at',)
        constraints = (
            models.UniqueConstraint(
                fields=('parent', 'creation_operation_id'),
                name='unique_kid_profile_creation_op',
            ),
        )

    def __str__(self) -> str:
        return self.display_name


class KidProfilePreferences(models.Model):
    """Typed reading preferences belonging to exactly one child profile."""

    class StoryTextScale(models.TextChoices):
        COMFORTABLE = 'comfortable', 'Comfortable'
        LARGE = 'large', 'Large'
        EXTRA_LARGE = 'extra_large', 'Extra large'

    profile = models.OneToOneField(
        KidProfile,
        on_delete=models.CASCADE,
        related_name='preferences',
    )
    story_text_scale = models.CharField(
        max_length=16,
        choices=StoryTextScale.choices,
        default=StoryTextScale.COMFORTABLE,
    )
    narration_enabled = models.BooleanField(default=True)
    # The first streak claim binds a profile to one device offset. Changing it
    # is deliberately rate-limited by the streak service to prevent instant
    # multi-day claims while still allowing travel and daylight-saving changes.
    streak_timezone_offset_minutes = models.SmallIntegerField(
        null=True,
        blank=True,
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = 'kid profile preferences'
        verbose_name_plural = 'kid profile preferences'
        constraints = (
            models.CheckConstraint(
                condition=(
                    models.Q(streak_timezone_offset_minutes__isnull=True)
                    | models.Q(
                        streak_timezone_offset_minutes__gte=-840,
                        streak_timezone_offset_minutes__lte=840,
                    )
                ),
                name='kid_preferences_streak_timezone_valid',
            ),
        )

    def __str__(self) -> str:
        return f'{self.profile.display_name} preferences'


class PrivateFamilyImportReceipt(models.Model):
    """One-time administrative import proof, without email or credential data."""

    id = models.UUIDField(primary_key=True, editable=False)
    parent = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, on_delete=models.SET_NULL,
        related_name='private_family_import_receipts',
    )
    digest = models.CharField(max_length=64)
    completed_at = models.DateTimeField(auto_now_add=True)
