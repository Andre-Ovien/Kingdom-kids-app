"""Single-use browser bootstrap and a narrow, memory-only checkout session.

The fragment carries only a 90-second checkout code. The app's credentials are
never copied into a URL, cookie or browser. A redeemed session is accepted only
by the explicitly wired billing views and never authorizes a charge itself.
"""
from datetime import datetime, timedelta, timezone as datetime_timezone
import re
import secrets
from uuid import UUID
from urllib.parse import urlsplit

from django.conf import settings
from django.core import signing
from django.db import transaction
from django.utils import timezone
from django.utils.crypto import constant_time_compare, salted_hmac
from django.views.decorators.debug import sensitive_variables

from .handoff_models import ParentCheckoutHandoff

CODE_SECONDS = 90
SESSION_SECONDS = 600
TOKEN_PREFIX = 'kkco.'
TOKEN_SALT = 'kingdom-kids.parent-checkout.session.v1'
CODE_PATTERN = re.compile(r'^[A-Za-z0-9_-]{43}$')


class HandoffUnavailable(ValueError):
    pass


def _enabled():
    if getattr(settings, 'PARENT_CHECKOUT_HANDOFF_ENABLED', False) is not True:
        raise HandoffUnavailable('Checkout link is unavailable or expired.')


def _binding():
    _enabled()
    from .configuration import active_billing_environment, SquareDisabled, SquareConfigurationError
    from .parent_checkout_web import _origin, ParentCheckoutUnavailable
    try:
        return active_billing_environment(), _origin(settings.PARENT_CHECKOUT_ORIGIN)
    except (SquareDisabled, SquareConfigurationError, ParentCheckoutUnavailable):
        raise HandoffUnavailable('Checkout link is unavailable or expired.') from None


def _same_origin(value, expected):
    try:
        parts, target = urlsplit(value), urlsplit(expected)
        return (parts.scheme == 'https' and not parts.username and not parts.password
                and parts.path in ('', '/') and not parts.query and not parts.fragment
                and parts.hostname == target.hostname and (parts.port or 443) == (target.port or 443))
    except (ValueError, TypeError, AttributeError):
        return False


def request_matches_origin(request, origin, *, require_origin=False):
    if not request.is_secure() or not _same_origin('https://' + request.get_host(), origin):
        raise HandoffUnavailable('Checkout link is unavailable or expired.')
    supplied = request.headers.get('Origin')
    if ((require_origin and not supplied) or (supplied and not _same_origin(supplied, origin))):
        raise HandoffUnavailable('Checkout link is unavailable or expired.')


@sensitive_variables()
def _parent_fingerprint(parent):
    return salted_hmac('kingdom-kids.checkout.parent-auth.v1',
                       str(parent.pk) + ':' + parent.password, algorithm='sha256').hexdigest()


@sensitive_variables()
def _digest(code):
    return salted_hmac('kingdom-kids.checkout.code.v1', code, algorithm='sha256').hexdigest()


def _eligible(parent):
    return bool(parent and parent.is_authenticated and parent.is_active and parent.is_email_verified)


@sensitive_variables()
def issue_handoff(*, parent, access_expiry, purpose, billing_period=None, request=None):
    environment, origin = _binding()
    if purpose not in ('purchase', 'manage') or not _eligible(parent):
        raise HandoffUnavailable('Checkout link is unavailable or expired.')
    if (purpose == 'purchase' and billing_period not in ('monthly', 'yearly')) or (
            purpose == 'manage' and billing_period is not None):
        raise HandoffUnavailable('Checkout link is unavailable or expired.')
    from .parent_checkout_web import checkout_capability, public_checkout_configuration, ParentCheckoutUnavailable
    from .configuration import SquareDisabled, SquareConfigurationError
    try:
        public = public_checkout_configuration(purpose=purpose)
    except (ParentCheckoutUnavailable, SquareDisabled, SquareConfigurationError):
        raise HandoffUnavailable('Checkout link is unavailable or expired.') from None
    if (public.get('environment') != environment or public['origin'] != origin
            or checkout_capability(parent, purpose=purpose).get('state') != 'available'):
        raise HandoffUnavailable('Checkout link is unavailable or expired.')
    if request is not None:
        request_matches_origin(request, origin)
    now = timezone.now()
    if type(access_expiry) is not int:
        raise HandoffUnavailable('Checkout link is unavailable or expired.')
    try:
        access_end = datetime.fromtimestamp(access_expiry, tz=datetime_timezone.utc)
    except (OverflowError, ValueError, OSError):
        raise HandoffUnavailable('Checkout link is unavailable or expired.') from None
    expiry = min(now + timedelta(seconds=CODE_SECONDS), access_end)
    if expiry <= now + timedelta(seconds=5):
        raise HandoffUnavailable('Checkout link is unavailable or expired.')
    code = secrets.token_urlsafe(32)
    with transaction.atomic():
        current = type(parent).objects.select_for_update().get(pk=parent.pk)
        if not _eligible(current) or not constant_time_compare(current.password, parent.password):
            raise HandoffUnavailable('Checkout link is unavailable or expired.')
        ParentCheckoutHandoff.objects.filter(parent=current, environment=environment,
            consumed_at__isnull=True, revoked_at__isnull=True).update(revoked_at=now)
        row = ParentCheckoutHandoff.objects.create(parent=current, environment=environment,
            purpose=purpose, billing_period=billing_period or '', origin=origin,
            code_digest=_digest(code), parent_auth_fingerprint=_parent_fingerprint(current),
            created_at=now, expires_at=expiry, origin_access_expires_at=access_end)
    return {'schema_version': 1, 'parent_id': str(parent.pk), 'environment': environment,
            'purpose': purpose, 'billing_period': row.billing_period or None,
            'code': code, 'expires_in': max(1, int((expiry - now).total_seconds())),
            'expires_at': expiry.isoformat()}


@sensitive_variables()
def redeem_handoff(*, code, request):
    environment, origin = _binding()
    request_matches_origin(request, origin, require_origin=True)
    if not isinstance(code, str) or not CODE_PATTERN.fullmatch(code):
        raise HandoffUnavailable('Checkout link is unavailable or expired.')
    now = timezone.now()
    with transaction.atomic():
        row = (ParentCheckoutHandoff.objects.select_for_update(of=('self',)).select_related('parent')
               .filter(code_digest=_digest(code)).first())
        if (row is None or row.environment != environment or row.origin != origin
                or row.consumed_at is not None or row.revoked_at is not None
                or row.expires_at <= now or row.origin_access_expires_at <= now
                or not _eligible(row.parent)
                or not constant_time_compare(row.parent_auth_fingerprint, _parent_fingerprint(row.parent))):
            raise HandoffUnavailable('Checkout link is unavailable or expired.')
        from .parent_checkout_web import checkout_capability
        if checkout_capability(row.parent, purpose=row.purpose).get('state') != 'available':
            raise HandoffUnavailable('Checkout link is unavailable or expired.')
        # The row lock/capability read can wait. Never consume using an earlier
        # timestamp if the code or originating app access expired meanwhile.
        now = timezone.now()
        if row.expires_at <= now or row.origin_access_expires_at <= now:
            raise HandoffUnavailable('Checkout link is unavailable or expired.')
        end = min(now + timedelta(seconds=SESSION_SECONDS), row.origin_access_expires_at)
        changed = ParentCheckoutHandoff.objects.filter(pk=row.pk, consumed_at__isnull=True,
            revoked_at__isnull=True, expires_at__gt=now).update(consumed_at=now, session_expires_at=end)
        if changed != 1:
            raise HandoffUnavailable('Checkout link is unavailable or expired.')
    token = TOKEN_PREFIX + signing.dumps({'id': str(row.pk), 'environment': row.environment,
        'purpose': row.purpose, 'aud': row.origin}, salt=TOKEN_SALT)
    return {'schema_version': 1, 'environment': environment, 'purpose': row.purpose,
            'billing_period': row.billing_period or None,
            'parent': {'id': str(row.parent_id), 'email': row.parent.email, 'email_verified': True},
            'checkout_token': token, 'expires_at': end.isoformat()}


@sensitive_variables()
def authenticate_checkout_session(*, token, request):
    environment, origin = _binding()
    request_matches_origin(request, origin, require_origin=request.method not in ('GET', 'HEAD', 'OPTIONS'))
    if not isinstance(token, str) or not token.startswith(TOKEN_PREFIX) or len(token) > 2048:
        raise HandoffUnavailable('Checkout session is unavailable or expired.')
    try:
        value = signing.loads(token[len(TOKEN_PREFIX):], salt=TOKEN_SALT, max_age=SESSION_SECONDS)
        if not isinstance(value, dict) or set(value) != {'id', 'environment', 'purpose', 'aud'}:
            raise ValueError
        if not isinstance(value['id'], str):
            raise ValueError
        UUID(value['id'])
        row = ParentCheckoutHandoff.objects.select_related('parent').get(pk=value['id'])
    except (signing.BadSignature, ValueError, TypeError, ParentCheckoutHandoff.DoesNotExist):
        raise HandoffUnavailable('Checkout session is unavailable or expired.') from None
    now = timezone.now()
    if (value['environment'] != environment or value['purpose'] != row.purpose or value['aud'] != origin
            or row.environment != environment or row.origin != origin or row.consumed_at is None
            or row.revoked_at is not None or row.session_expires_at is None
            or row.session_expires_at <= now or row.origin_access_expires_at <= now
            or not _eligible(row.parent)
            or not constant_time_compare(row.parent_auth_fingerprint, _parent_fingerprint(row.parent))):
        raise HandoffUnavailable('Checkout session is unavailable or expired.')
    return row
