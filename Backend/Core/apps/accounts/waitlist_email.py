"""Explicit, leased waitlist confirmation; no bulk sends or background worker."""
from datetime import timedelta
from uuid import uuid4

from django.conf import settings
from django.core.mail import EmailMultiAlternatives, get_connection
from django.db import transaction
from django.utils import timezone
from django.views.decorators.debug import sensitive_variables

from .models import WaitlistSubscriber


SUBJECT = "You're on the Kingdom Kids waitlist"
TEXT = (
    "You're on the Kingdom Kids waitlist!\n\n"
    "We'll email you with launch updates and let you know when Kingdom Kids is ready.\n\n"
    "If you didn't sign up, you can ignore this confirmation.\n\n"
    'The Kingdom Kids team\nhttps://kingdom-kids.app/\n'
)
HTML = (
    "<h1>You're on the Kingdom Kids waitlist!</h1>"
    "<p>We'll email you with launch updates and let you know when Kingdom Kids is ready.</p>"
    "<p>If you didn't sign up, you can ignore this confirmation.</p>"
    '<p>The Kingdom Kids team<br><a href="https://kingdom-kids.app/">Kingdom Kids</a></p>'
)
LEASE = timedelta(minutes=2)
# Resend keys expire after24hours. Never blindly resend an old unknown outcome;
# retain an operator review margin rather than risk a second confirmation.
SAFE_RETRY_WINDOW = timedelta(hours=23)


@sensitive_variables()
def ensure_waitlist_confirmation(subscriber_id):
    """Return provider-accepted/already accepted; False means saved but delayed."""
    try:
        if WaitlistSubscriber.objects.filter(pk=subscriber_id, confirmation_sent_at__isnull=False).exists():
            return True
        if getattr(settings, 'EMAIL_DELIVERY_ENABLED', True) is not True:
            return False
        # Backend construction validates configuration without sending. A
        # missing key must not start the unknown-provider-result clock.
        connection = get_connection(fail_silently=False)
        with transaction.atomic():
            row = WaitlistSubscriber.objects.select_for_update().get(pk=subscriber_id)
            if row.confirmation_sent_at is not None:
                return True
            now = timezone.now()
            if row.confirmation_lease_until is not None and row.confirmation_lease_until > now:
                return False
            if (row.confirmation_first_attempt_at is not None
                    and now - row.confirmation_first_attempt_at >= SAFE_RETRY_WINDOW):
                return False
            claim = uuid4()
            row.confirmation_claim_id = claim
            row.confirmation_lease_until = now + LEASE
            if row.confirmation_first_attempt_at is None:
                row.confirmation_first_attempt_at = now
            row.save(update_fields=['confirmation_claim_id', 'confirmation_lease_until', 'confirmation_first_attempt_at'])
            recipient = row.email
        # External I/O is outside the row lock. Every retry uses the same
        # immutable subscriber ID, message version and fixed content.
        accepted = False
        try:
            message = EmailMultiAlternatives(
                SUBJECT, TEXT, settings.DEFAULT_FROM_EMAIL, [recipient], connection=connection,
                headers={'Resend-Idempotency-Key': f'waitlist-confirmation-v1/{subscriber_id}'},
            )
            message.attach_alternative(HTML, 'text/html')
            accepted = message.send(fail_silently=False) == 1
        except Exception:
            # A timeout can follow provider acceptance; do not rotate the key.
            pass
        with transaction.atomic():
            row = WaitlistSubscriber.objects.select_for_update().get(pk=subscriber_id)
            if row.confirmation_sent_at is not None:
                return True
            if row.confirmation_claim_id != claim:
                return False
            row.confirmation_claim_id = None
            row.confirmation_lease_until = None
            fields = ['confirmation_claim_id', 'confirmation_lease_until']
            if accepted:
                row.confirmation_sent_at = timezone.now()
                fields.append('confirmation_sent_at')
            row.save(update_fields=fields)
        return accepted
    except Exception:
        # Never let transport/configuration or a competing SQLite writer erase
        # signup consent or expose a recipient, message or credential.
        return False
