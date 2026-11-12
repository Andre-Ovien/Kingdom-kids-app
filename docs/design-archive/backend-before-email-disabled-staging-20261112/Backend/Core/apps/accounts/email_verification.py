import hashlib
import hmac
import math
import secrets
from functools import partial
import logging
from uuid import UUID, uuid4

from django.conf import settings
from django.core.mail import send_mail
from django.db import transaction
from django.utils import timezone

from .models import EmailVerificationChallenge, User


logger = logging.getLogger(__name__)


class InvalidVerificationChallenge(Exception):
    """The opaque challenge identifier cannot be used."""


class InvalidVerificationCode(Exception):
    """The submitted code is wrong, expired, consumed, or locked."""


class EmailAlreadyVerified(Exception):
    """The parent completed email verification already."""


class ResendTooSoon(Exception):
    def __init__(self, retry_after: int):
        super().__init__('A new verification code cannot be sent yet.')
        self.retry_after = retry_after


class VerificationDeliveryDelayed(Exception):
    """The challenge was committed, but its email could not be delivered."""

    def __init__(self, challenge_id: UUID):
        super().__init__('Verification email delivery was delayed.')
        self.challenge_id = challenge_id


def verification_payload(challenge: EmailVerificationChallenge) -> dict[str, object]:
    now = timezone.now()
    resend_available_at = challenge.resend_available_at
    locked_until = challenge.user.email_verification_locked_until
    if locked_until is not None and locked_until > resend_available_at:
        resend_available_at = locked_until
    return {
        'challenge_id': str(challenge.pk),
        'destination_hint': _masked_email(challenge.user.email),
        'expires_in': _seconds_until(challenge.expires_at, now),
        'resend_after': _seconds_until(resend_available_at, now),
    }


def private_registration_payload(email: str) -> dict[str, object]:
    """Return a non-actionable duplicate response without disclosing state.

    Existing verified, disabled, and pending accounts all receive this same
    shape. The random identifier is deliberately not stored, so an anonymous
    caller cannot obtain or attack another parent's live verification challenge.
    """

    return {
        'challenge_id': str(uuid4()),
        'destination_hint': _masked_email(email),
        'expires_in': int(settings.EMAIL_VERIFICATION_TTL.total_seconds()),
        'resend_after': int(
            settings.EMAIL_VERIFICATION_RESEND_COOLDOWN.total_seconds()
        ),
    }


def issue_email_verification_challenge(user: User) -> EmailVerificationChallenge:
    """Return a cooling challenge or rotate it and send after commit."""
    with transaction.atomic():
        locked_user = User.objects.select_for_update().get(pk=user.pk)
        if not locked_user.is_active:
            raise InvalidVerificationChallenge
        if locked_user.is_email_verified:
            raise EmailAlreadyVerified

        now = timezone.now()
        is_locked = _normalize_attempt_state(locked_user, now)
        active_challenge = (
            EmailVerificationChallenge.objects.select_for_update()
            .filter(
                user=locked_user,
                consumed_at__isnull=True,
                invalidated_at__isnull=True,
            )
            .first()
        )
        if active_challenge is not None and (
            is_locked or active_challenge.resend_available_at > now
        ):
            active_challenge.user = locked_user
            return active_challenge

        if is_locked:
            # A lock normally always has an active challenge. Preserve a
            # recoverable opaque handle even if maintenance removed that row,
            # but do not send a fresh guess while the account is locked.
            challenge, _ = _create_challenge(
                locked_user,
                now,
                resend_available_at=locked_user.email_verification_locked_until,
            )
            return challenge

        EmailVerificationChallenge.objects.filter(
            user=locked_user,
            consumed_at__isnull=True,
            invalidated_at__isnull=True,
        ).update(invalidated_at=now)
        challenge, code = _create_challenge(locked_user, now)
        transaction.on_commit(
            partial(
                _deliver_verification_email,
                challenge.pk,
                locked_user.email,
                code,
            )
        )
        return challenge


def challenge_for_unverified_login(user: User) -> EmailVerificationChallenge:
    """Return a resendable challenge after valid credentials are supplied."""
    with transaction.atomic():
        locked_user = User.objects.select_for_update().get(pk=user.pk)
        challenge = (
            EmailVerificationChallenge.objects.select_for_update()
            .filter(
                user=locked_user,
                consumed_at__isnull=True,
                invalidated_at__isnull=True,
            )
            .first()
        )
        if challenge is not None:
            challenge.user = locked_user
            return challenge
        return issue_email_verification_challenge(locked_user)


def confirm_email_verification(challenge_id: UUID, code: str) -> User:
    """Consume a valid challenge under the parent's shared attempt budget."""
    failure: Exception | None = None
    verified_user: User | None = None

    with transaction.atomic():
        try:
            user_id = EmailVerificationChallenge.objects.values_list(
                'user_id',
                flat=True,
            ).get(pk=challenge_id)
            locked_user = User.objects.select_for_update().get(pk=user_id)
            challenge = EmailVerificationChallenge.objects.select_for_update().get(
                pk=challenge_id,
                user=locked_user,
            )
        except (EmailVerificationChallenge.DoesNotExist, User.DoesNotExist):
            failure = InvalidVerificationChallenge()
        else:
            now = timezone.now()
            if not locked_user.is_active or locked_user.is_email_verified:
                failure = InvalidVerificationCode()
            elif _normalize_attempt_state(locked_user, now):
                failure = InvalidVerificationCode()
            elif (
                challenge.consumed_at is not None
                or challenge.invalidated_at is not None
                or challenge.expires_at <= now
            ):
                failure = InvalidVerificationCode()
            elif not _code_matches(challenge, code):
                challenge.attempt_count += 1
                challenge.save(update_fields=('attempt_count',))
                _record_failed_attempt(locked_user, now)
                failure = InvalidVerificationCode()
            else:
                challenge.consumed_at = now
                challenge.save(update_fields=('consumed_at',))
                locked_user.email_verified_at = now
                _reset_attempt_state(locked_user)
                locked_user.save(
                    update_fields=(
                        'email_verified_at',
                        'email_verification_failed_attempts',
                        'email_verification_failure_window_started_at',
                        'email_verification_locked_until',
                    )
                )
                EmailVerificationChallenge.objects.filter(
                    user=locked_user,
                    consumed_at__isnull=True,
                    invalidated_at__isnull=True,
                ).exclude(pk=challenge.pk).update(invalidated_at=now)
                verified_user = locked_user

    if failure is not None:
        raise failure
    if verified_user is None:  # Defensive: every branch above must set one.
        raise InvalidVerificationCode
    return verified_user


def resend_email_verification(challenge_id: UUID) -> EmailVerificationChallenge:
    """Rotate after both the account lockout and resend cooldown permit it."""
    failure: Exception | None = None
    replacement: EmailVerificationChallenge | None = None

    with transaction.atomic():
        try:
            user_id = EmailVerificationChallenge.objects.values_list(
                'user_id',
                flat=True,
            ).get(pk=challenge_id)
            locked_user = User.objects.select_for_update().get(pk=user_id)
            challenge = EmailVerificationChallenge.objects.select_for_update().get(
                pk=challenge_id,
                user=locked_user,
            )
        except (EmailVerificationChallenge.DoesNotExist, User.DoesNotExist):
            failure = InvalidVerificationChallenge()
        else:
            now = timezone.now()
            if not locked_user.is_active:
                failure = InvalidVerificationChallenge()
            elif locked_user.is_email_verified:
                failure = EmailAlreadyVerified()
            elif (
                challenge.consumed_at is not None
                or challenge.invalidated_at is not None
            ):
                failure = InvalidVerificationChallenge()
            elif _normalize_attempt_state(locked_user, now):
                failure = ResendTooSoon(
                    _seconds_until(
                        locked_user.email_verification_locked_until,
                        now,
                    )
                )
            elif challenge.resend_available_at > now:
                failure = ResendTooSoon(
                    _seconds_until(challenge.resend_available_at, now)
                )
            else:
                challenge.invalidated_at = now
                challenge.save(update_fields=('invalidated_at',))
                replacement, code = _create_challenge(locked_user, now)
                transaction.on_commit(
                    partial(
                        _deliver_verification_email,
                        replacement.pk,
                        locked_user.email,
                        code,
                    )
                )

    if failure is not None:
        raise failure
    if replacement is None:
        raise InvalidVerificationChallenge
    return replacement


def _create_challenge(
    user: User,
    now,
    *,
    resend_available_at=None,
) -> tuple[EmailVerificationChallenge, str]:
    code = f'{secrets.randbelow(1_000_000):06d}'
    challenge = EmailVerificationChallenge(
        user=user,
        expires_at=now + settings.EMAIL_VERIFICATION_TTL,
        resend_available_at=(
            resend_available_at
            if resend_available_at is not None
            else now + settings.EMAIL_VERIFICATION_RESEND_COOLDOWN
        ),
        max_attempts=settings.EMAIL_VERIFICATION_MAX_ATTEMPTS,
    )
    challenge.code_digest = _code_digest(challenge.pk, code)
    challenge.save(force_insert=True)
    return challenge, code


def _normalize_attempt_state(user: User, now) -> bool:
    """Clear an elapsed window/lock and report whether the parent is locked."""
    locked_until = user.email_verification_locked_until
    if locked_until is not None:
        if locked_until > now:
            return True
        _reset_attempt_state(user)
        _save_attempt_state(user)
        return False

    window_started_at = user.email_verification_failure_window_started_at
    if (
        window_started_at is not None
        and window_started_at + settings.EMAIL_VERIFICATION_ATTEMPT_WINDOW <= now
    ):
        _reset_attempt_state(user)
        _save_attempt_state(user)
        return False

    if (
        window_started_at is not None
        and user.email_verification_failed_attempts
        >= settings.EMAIL_VERIFICATION_MAX_ATTEMPTS
    ):
        user.email_verification_locked_until = (
            now + settings.EMAIL_VERIFICATION_LOCKOUT
        )
        _save_attempt_state(user)
        return True
    return False


def _record_failed_attempt(user: User, now) -> None:
    if user.email_verification_failure_window_started_at is None:
        user.email_verification_failure_window_started_at = now
        user.email_verification_failed_attempts = 0

    user.email_verification_failed_attempts += 1
    if (
        user.email_verification_failed_attempts
        >= settings.EMAIL_VERIFICATION_MAX_ATTEMPTS
    ):
        user.email_verification_locked_until = (
            now + settings.EMAIL_VERIFICATION_LOCKOUT
        )
    _save_attempt_state(user)


def _reset_attempt_state(user: User) -> None:
    user.email_verification_failed_attempts = 0
    user.email_verification_failure_window_started_at = None
    user.email_verification_locked_until = None


def _save_attempt_state(user: User) -> None:
    user.save(
        update_fields=(
            'email_verification_failed_attempts',
            'email_verification_failure_window_started_at',
            'email_verification_locked_until',
        )
    )


def _code_matches(challenge: EmailVerificationChallenge, code: str) -> bool:
    return hmac.compare_digest(challenge.code_digest, _code_digest(challenge.pk, code))


def _code_digest(challenge_id: UUID, code: str) -> str:
    message = f'{challenge_id}:{code}'.encode()
    return hmac.new(
        settings.EMAIL_VERIFICATION_PEPPER.encode(),
        message,
        hashlib.sha256,
    ).hexdigest()


def _deliver_verification_email(
    challenge_id: UUID,
    email: str,
    code: str,
) -> None:
    if (
        settings.DEBUG
        and settings.EMAIL_BACKEND
        == 'django.core.mail.backends.console.EmailBackend'
    ):
        print(
            '\n'
            '========================================\n'
            ' KINGDOM KIDS DEVELOPMENT CODE\n'
            f' Email: {email}\n'
            f' Code:  {code}\n'
            '========================================\n',
            flush=True,
        )
        return

    try:
        sent_count = send_mail(
            subject='Your Kingdom Kids verification code',
            message=(
                'Welcome to Kingdom Kids!\n\n'
                f'Your parent verification code is {code}.\n\n'
                f'This code expires in '
                f'{int(settings.EMAIL_VERIFICATION_TTL.total_seconds() // 60)} '
                'minutes. If you did not create this account, you can ignore this email.'
            ),
            from_email=settings.DEFAULT_FROM_EMAIL,
            recipient_list=[email],
            fail_silently=False,
        )
        if sent_count != 1:
            raise RuntimeError('The email backend did not accept the message.')
    except Exception as exc:
        # on_commit callbacks run after the challenge transaction has been
        # durably committed. Keep that opaque challenge usable and clear its
        # cooldown so the client can retry immediately.
        EmailVerificationChallenge.objects.filter(
            pk=challenge_id,
            consumed_at__isnull=True,
            invalidated_at__isnull=True,
        ).update(resend_available_at=timezone.now())
        # Provider exceptions can contain the recipient, message body, or
        # credentials. Keep logs actionable without copying that data.
        logger.error(
            'Verification email delivery failed challenge_id=%s',
            challenge_id,
        )
        raise VerificationDeliveryDelayed(challenge_id) from exc


def _masked_email(email: str) -> str:
    local, separator, domain = email.partition('@')
    if not separator:
        return '***'
    visible = local[:1] if local else ''
    return f'{visible}***@{domain}'


def _seconds_until(moment, now) -> int:
    return max(0, math.ceil((moment - now).total_seconds()))
