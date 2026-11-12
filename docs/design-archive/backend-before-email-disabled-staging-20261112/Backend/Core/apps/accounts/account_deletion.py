import hashlib
import hmac
import logging
import secrets
import uuid
from functools import partial
from uuid import UUID

from django.conf import settings
from django.core.mail import send_mail
from django.db import transaction
from django.utils import timezone
from django.views.decorators.debug import sensitive_variables
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken

from .models import AccountDeletionChallenge, User, WaitlistSubscriber


ACCOUNT_DELETION_PURPOSE = 'kingdom-kids:account-deletion:v1'  # noqa: S105
logger = logging.getLogger(__name__)


class InvalidAccountDeletionChallenge(Exception):
    """The deletion handle or code cannot authorize account deletion."""


def request_account_deletion(email: str) -> UUID:
    """Return a real or decoy handle without disclosing account state."""

    decoy_id = uuid.uuid4()
    with transaction.atomic():
        user = (
            User.objects.select_for_update()
            .filter(
                email=email,
                is_active=True,
                is_staff=False,
                is_superuser=False,
            )
            .first()
        )
        if user is None:
            return decoy_id

        now = timezone.now()
        AccountDeletionChallenge.objects.filter(
            user=user,
            consumed_at__isnull=True,
            invalidated_at__isnull=True,
        ).update(invalidated_at=now)

        code = f'{secrets.randbelow(1_000_000):06d}'
        challenge = AccountDeletionChallenge(
            user=user,
            expires_at=now + settings.ACCOUNT_DELETION_TTL,
            max_attempts=settings.ACCOUNT_DELETION_MAX_ATTEMPTS,
        )
        challenge.code_digest = _code_digest(
            challenge.pk,
            user.email,
            code,
        )
        challenge.save(force_insert=True)
        transaction.on_commit(
            partial(
                _deliver_account_deletion_email,
                challenge.pk,
                user.email,
                code,
            )
        )
        return challenge.pk


@sensitive_variables()
def confirm_account_deletion(challenge_id: UUID, code: str) -> None:
    """Consume valid mailbox proof and atomically erase the parent account."""

    invalid = False
    with transaction.atomic():
        try:
            user_id = AccountDeletionChallenge.objects.values_list(
                'user_id',
                flat=True,
            ).get(pk=challenge_id)
            user = User.objects.select_for_update().get(pk=user_id)
            challenge = AccountDeletionChallenge.objects.select_for_update().get(
                pk=challenge_id,
                user=user,
            )
        except (AccountDeletionChallenge.DoesNotExist, User.DoesNotExist):
            invalid = True
        else:
            now = timezone.now()
            if (
                not user.is_active
                or user.is_staff
                or user.is_superuser
                or challenge.consumed_at is not None
                or challenge.invalidated_at is not None
                or challenge.expires_at <= now
                or challenge.attempt_count >= challenge.max_attempts
            ):
                invalid = True
            elif not _code_matches(challenge, user.email, code):
                challenge.attempt_count += 1
                update_fields = ['attempt_count']
                if challenge.attempt_count >= challenge.max_attempts:
                    challenge.invalidated_at = now
                    update_fields.append('invalidated_at')
                challenge.save(update_fields=update_fields)
                invalid = True
            else:
                challenge.consumed_at = now
                challenge.save(update_fields=('consumed_at',))
                WaitlistSubscriber.objects.filter(email__iexact=user.email).delete()
                OutstandingToken.objects.filter(user=user).delete()
                user.delete()

    if invalid:
        raise InvalidAccountDeletionChallenge


def _code_matches(
    challenge: AccountDeletionChallenge,
    email: str,
    code: str,
) -> bool:
    return hmac.compare_digest(
        challenge.code_digest,
        _code_digest(challenge.pk, email, code),
    )


def _code_digest(challenge_id: UUID, email: str, code: str) -> str:
    message = (
        f'{ACCOUNT_DELETION_PURPOSE}:{challenge_id}:{email}:{code}'
    ).encode()
    return hmac.new(
        settings.ACCOUNT_DELETION_PEPPER.encode(),
        message,
        hashlib.sha256,
    ).hexdigest()


def _deliver_account_deletion_email(
    challenge_id: UUID,
    email: str,
    code: str,
) -> None:
    # Console output is a log. Never write an irreversible-action credential
    # there, even during development.
    if settings.EMAIL_BACKEND == 'django.core.mail.backends.console.EmailBackend':
        _invalidate_undelivered_challenge(challenge_id)
        return

    try:
        sent_count = send_mail(
            subject='Confirm your Kingdom Kids account deletion',
            message=(
                'A request was made to permanently delete your Kingdom Kids '
                'parent account and its associated family data.\n\n'
                f'Your account deletion code is {code}.\n\n'
                'This code expires in '
                f'{int(settings.ACCOUNT_DELETION_TTL.total_seconds() // 60)} '
                'minutes. The code alone does not delete the account; the '
                'request must also be confirmed on the Kingdom Kids website. '
                'If you did not request deletion, ignore this email.'
            ),
            from_email=settings.DEFAULT_FROM_EMAIL,
            recipient_list=[email],
            fail_silently=False,
        )
    except Exception:
        # Provider errors can contain the address, body, or credentials. Keep
        # the public response generic and log only the opaque challenge ID.
        _invalidate_undelivered_challenge(challenge_id)
        logger.error(
            'Account deletion email delivery failed challenge_id=%s',
            challenge_id,
        )
        return

    if sent_count != 1:
        _invalidate_undelivered_challenge(challenge_id)
        logger.error(
            'Account deletion email was not accepted challenge_id=%s',
            challenge_id,
        )


def _invalidate_undelivered_challenge(challenge_id: UUID) -> None:
    AccountDeletionChallenge.objects.filter(
        pk=challenge_id,
        consumed_at__isnull=True,
        invalidated_at__isnull=True,
    ).update(invalidated_at=timezone.now())
