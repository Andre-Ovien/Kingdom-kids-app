from datetime import timedelta
from io import StringIO

from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone

from .models import (
    AccountDeletionChallenge,
    EmailVerificationChallenge,
    PasswordResetChallenge,
    User,
)


@override_settings(AUTH_CHALLENGE_RETENTION_DAYS=30)
class PurgeExpiredAuthChallengesTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='cleanup@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )

    def _verification(self, *, expires_at):
        return EmailVerificationChallenge.objects.create(
            user=self.user,
            code_digest='a' * 64,
            expires_at=expires_at,
            resend_available_at=expires_at,
        )

    def _reset(self, *, expires_at, invalidated_at=None):
        return PasswordResetChallenge.objects.create(
            user=self.user,
            code_digest='b' * 64,
            expires_at=expires_at,
            invalidated_at=invalidated_at,
        )

    def _deletion(self, *, expires_at, consumed_at=None):
        return AccountDeletionChallenge.objects.create(
            user=self.user,
            code_digest='c' * 64,
            expires_at=expires_at,
            consumed_at=consumed_at,
        )

    def test_command_deletes_only_challenges_older_than_retention(self):
        now = timezone.now()
        old_verification = self._verification(
            expires_at=now - timedelta(days=31)
        )
        recent_verification = self._verification(
            expires_at=now - timedelta(days=2)
        )
        old_reset = self._reset(
            expires_at=now + timedelta(days=1),
            invalidated_at=now - timedelta(days=31),
        )
        recent_reset = self._reset(expires_at=now + timedelta(minutes=5))
        old_deletion = self._deletion(
            expires_at=now + timedelta(days=1),
            consumed_at=now - timedelta(days=31),
        )
        recent_deletion = self._deletion(expires_at=now + timedelta(minutes=5))

        output = StringIO()
        call_command('purge_expired_auth_challenges', stdout=output)

        self.assertFalse(
            EmailVerificationChallenge.objects.filter(pk=old_verification.pk).exists()
        )
        self.assertTrue(
            EmailVerificationChallenge.objects.filter(pk=recent_verification.pk).exists()
        )
        self.assertFalse(
            PasswordResetChallenge.objects.filter(pk=old_reset.pk).exists()
        )
        self.assertTrue(
            PasswordResetChallenge.objects.filter(pk=recent_reset.pk).exists()
        )
        self.assertFalse(
            AccountDeletionChallenge.objects.filter(pk=old_deletion.pk).exists()
        )
        self.assertTrue(
            AccountDeletionChallenge.objects.filter(pk=recent_deletion.pk).exists()
        )
        self.assertIn(
            'verification=1, reset=1, deletion=1',
            output.getvalue(),
        )
