from datetime import timedelta

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db.models import Q
from django.utils import timezone

from apps.accounts.models import (
    AccountDeletionChallenge,
    EmailVerificationChallenge,
    PasswordResetChallenge,
)


class Command(BaseCommand):
    help = (
        'Delete stale email-verification, password-reset, and account-deletion '
        'challenges.'
    )

    def handle(self, *args, **options):
        cutoff = timezone.now() - timedelta(
            days=settings.AUTH_CHALLENGE_RETENTION_DAYS
        )
        stale = (
            Q(expires_at__lt=cutoff)
            | Q(consumed_at__lt=cutoff)
            | Q(invalidated_at__lt=cutoff)
        )
        verification_deleted, _ = EmailVerificationChallenge.objects.filter(
            stale
        ).delete()
        reset_deleted, _ = PasswordResetChallenge.objects.filter(stale).delete()
        deletion_deleted, _ = AccountDeletionChallenge.objects.filter(stale).delete()
        self.stdout.write(
            self.style.SUCCESS(
                'Purged auth challenges: '
                f'verification={verification_deleted}, reset={reset_deleted}, '
                f'deletion={deletion_deleted}.'
            )
        )
