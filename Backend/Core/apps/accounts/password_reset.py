import hashlib
import hmac
import logging
import secrets
import uuid
from functools import partial
from uuid import UUID

from django.conf import settings
from Core.email_capability import require_email_delivery
from django.contrib.auth import password_validation
from django.core.mail import send_mail
from django.db import transaction
from django.utils import timezone

from .models import EmailVerificationChallenge, PasswordResetChallenge, User


PASSWORD_RESET_PURPOSE = 'kingdom-kids:password-reset:v1'  # noqa: S105
logger = logging.getLogger(__name__)


class InvalidPasswordResetChallenge(Exception):
    """The reset handle or code cannot authorize a password change."""


def request_password_reset(email: str) -> UUID:
    """Return a real or decoy reset handle without disclosing account state."""
    require_email_delivery()

    decoy_id = uuid.uuid4()
    with transaction.atomic():
        user = (
            User.objects.select_for_update()
            .filter(email=email)
            .first()
        )
        if user is None or not user.is_active:
            return decoy_id

        now = timezone.now()
        PasswordResetChallenge.objects.filter(
            user=user,
            consumed_at__isnull=True,
            invalidated_at__isnull=True,
        ).update(invalidated_at=now)

        code = f'{secrets.randbelow(1_000_000):06d}'
        challenge = PasswordResetChallenge(
            user=user,
            expires_at=now + settings.PASSWORD_RESET_TTL,
            max_attempts=settings.PASSWORD_RESET_MAX_ATTEMPTS,
        )
        challenge.code_digest = _code_digest(challenge.pk, code)
        challenge.save(force_insert=True)
        transaction.on_commit(
            partial(
                _deliver_password_reset_email,
                challenge.pk,
                user.email,
                code,
            )
        )
        return challenge.pk


def verify_password_reset_code(challenge_id: UUID, code: str) -> None:
    """Check the email proof without consuming it or changing the account.

    Final confirmation checks the same proof again under the same locks. A
    successful check only lets the client display its new-password page.
    """
    require_email_delivery()

    invalid = False
    with transaction.atomic():
        locked = _locked_reset_challenge(challenge_id)
        if locked is None:
            invalid = True
        else:
            user, challenge = locked
            invalid = not _accept_reset_code(user, challenge, code, timezone.now())
    # Raise outside the transaction so a wrong-code attempt remains counted.
    if invalid:
        raise InvalidPasswordResetChallenge


def confirm_password_reset(
    challenge_id: UUID,
    code: str,
    new_password: str,
) -> None:
    """Consume a valid proof and change the password under database locks."""
    require_email_delivery()

    invalid = False
    with transaction.atomic():
        locked = _locked_reset_challenge(challenge_id)
        if locked is None:
            invalid = True
        else:
            user, challenge = locked
            now = timezone.now()
            if not _accept_reset_code(user, challenge, code, now):
                invalid = True
            else:
                # This second validation supplies the real user to Django's
                # similarity validator, but only after email control is proven.
                password_validation.validate_password(new_password, user=user)
                user.set_password(new_password)
                user_update_fields = ['password']
                if not user.is_email_verified:
                    # The reset code is itself proof of control over the
                    # address. Completing recovery must let the real mailbox
                    # owner reclaim an address that somebody else registered
                    # but never verified.
                    user.email_verified_at = now
                    user.email_verification_failed_attempts = 0
                    user.email_verification_failure_window_started_at = None
                    user.email_verification_locked_until = None
                    user_update_fields.extend(
                        (
                            'email_verified_at',
                            'email_verification_failed_attempts',
                            'email_verification_failure_window_started_at',
                            'email_verification_locked_until',
                        )
                    )
                    EmailVerificationChallenge.objects.filter(
                        user=user,
                        consumed_at__isnull=True,
                        invalidated_at__isnull=True,
                    ).update(invalidated_at=now)
                user.save(update_fields=user_update_fields)
                challenge.consumed_at = now
                challenge.save(update_fields=('consumed_at',))
                PasswordResetChallenge.objects.filter(
                    user=user,
                    consumed_at__isnull=True,
                    invalidated_at__isnull=True,
                ).exclude(pk=challenge.pk).update(invalidated_at=now)

    if invalid:
        raise InvalidPasswordResetChallenge


def _locked_reset_challenge(challenge_id: UUID):
    """Lock the user first, matching request/resend and confirmation ordering."""

    try:
        user_id = PasswordResetChallenge.objects.values_list(
            'user_id', flat=True,
        ).get(pk=challenge_id)
        user = User.objects.select_for_update().get(pk=user_id)
        challenge = PasswordResetChallenge.objects.select_for_update().get(
            pk=challenge_id, user=user,
        )
    except (PasswordResetChallenge.DoesNotExist, User.DoesNotExist):
        return None
    return user, challenge


def _accept_reset_code(user, challenge, code, now) -> bool:
    """Validate one locked proof; both endpoints share its failure budget."""

    if (
        not user.is_active
        or challenge.consumed_at is not None
        or challenge.invalidated_at is not None
        or challenge.expires_at <= now
        or challenge.attempt_count >= challenge.max_attempts
    ):
        return False
    if _code_matches(challenge, code):
        return True
    challenge.attempt_count += 1
    update_fields = ['attempt_count']
    if challenge.attempt_count >= challenge.max_attempts:
        challenge.invalidated_at = now
        update_fields.append('invalidated_at')
    challenge.save(update_fields=update_fields)
    return False


def _code_matches(challenge: PasswordResetChallenge, code: str) -> bool:
    return hmac.compare_digest(challenge.code_digest, _code_digest(challenge.pk, code))


def _code_digest(challenge_id: UUID, code: str) -> str:
    message = f'{PASSWORD_RESET_PURPOSE}:{challenge_id}:{code}'.encode()
    return hmac.new(
        settings.PASSWORD_RESET_PEPPER.encode(),
        message,
        hashlib.sha256,
    ).hexdigest()


def _deliver_password_reset_email(
    challenge_id: UUID,
    email: str,
    code: str,
) -> None:
    # A developer may explicitly opt a named local test fixture into console
    # delivery. All other accounts retain the undelivered-code protection.
    require_email_delivery()
    if settings.EMAIL_BACKEND == 'django.core.mail.backends.console.EmailBackend':
        local_test_delivery = (
            settings.DEBUG
            and settings.PASSWORD_RESET_PRINT_LOCAL_TEST_CODES
            and email.strip().lower() in settings.PASSWORD_RESET_LOCAL_TEST_EMAILS
        )
        if not local_test_delivery:
            _invalidate_undelivered_challenge(challenge_id)
            return

    try:
        sent_count = send_mail(
            subject='Reset your Kingdom Kids password',
            message=(
                'A password reset was requested for your Kingdom Kids parent '
                'account.\n\n'
                f'Your password reset code is {code}.\n\n'
                'This code expires in '
                f'{int(settings.PASSWORD_RESET_TTL.total_seconds() // 60)} '
                'minutes. If you did not request this change, you can ignore '
                'this email and keep your current password.'
            ),
            from_email=settings.DEFAULT_FROM_EMAIL,
            recipient_list=[email],
            fail_silently=False,
        )
    except Exception:
        # Keep the public response identical for eligible and ineligible
        # addresses. Do not log the exception: provider exceptions can contain
        # the recipient, message body, or authentication details.
        _invalidate_undelivered_challenge(challenge_id)
        logger.error(
            'Password reset email delivery failed challenge_id=%s',
            challenge_id,
        )
        return

    if sent_count != 1:
        _invalidate_undelivered_challenge(challenge_id)
        logger.error(
            'Password reset email was not accepted challenge_id=%s',
            challenge_id,
        )


def _invalidate_undelivered_challenge(challenge_id: UUID) -> None:
    PasswordResetChallenge.objects.filter(
        pk=challenge_id,
        consumed_at__isnull=True,
        invalidated_at__isnull=True,
    ).update(invalidated_at=timezone.now())
