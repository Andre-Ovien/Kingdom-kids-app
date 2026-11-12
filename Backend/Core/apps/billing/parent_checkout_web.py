"""Default-OFF same-origin parent checkout shell; no provider I/O here."""
import re
from urllib.parse import urlsplit

from django.conf import settings
from django.http import Http404
from django.shortcuts import render
from django.views.decorators.cache import never_cache
from django.views.decorators.debug import sensitive_variables
from django.views.decorators.http import require_GET

from .configuration import (SquareConfigurationError, SquareDisabled,
                            checkout_configuration, provider_identifier)


class ParentCheckoutUnavailable(ValueError):
    pass


def _origin(value):
    try:
        if not isinstance(value, str):
            raise ValueError
        parsed = urlsplit(value)
        if (not isinstance(value, str) or len(value) > 512 or parsed.scheme != 'https'
                or not parsed.hostname or parsed.username or parsed.password
                or parsed.path not in {'', '/'} or parsed.query or parsed.fragment
                or any(char in value for char in '\\?#')
                or any(ord(char) <= 32 or ord(char) == 127 for char in value)):
            raise ValueError
        if parsed.port not in (None, 443) and parsed.hostname not in {'localhost', '127.0.0.1', '::1'}:
            raise ValueError
        return value.rstrip('/')
    except (TypeError, ValueError):
        raise ParentCheckoutUnavailable from None


@sensitive_variables()
def public_checkout_configuration():
    if (getattr(settings, 'PARENT_CHECKOUT_SANDBOX_ENABLED', False) is not True
            or getattr(settings, 'PARENT_CONTENT_ACCESS_STATUS_ENABLED', False) is not True
            or settings.SQUARE_ENVIRONMENT != 'sandbox'
            or settings.PAID_CONTENT_ENTITLEMENT_ENVIRONMENT != 'sandbox'):
        raise ParentCheckoutUnavailable
    config = checkout_configuration(terms=True)
    application_id = getattr(settings, 'SQUARE_SANDBOX_APPLICATION_ID', '')
    if not isinstance(application_id, str) or not re.fullmatch(r'sandbox-[A-Za-z0-9_-]{8,160}', application_id):
        raise ParentCheckoutUnavailable
    if (getattr(settings, 'SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED', False) is not True
            and not callable(getattr(settings, 'SQUARE_SANDBOX_TRANSPORT_FACTORY', None))):
        raise ParentCheckoutUnavailable
    return {'environment': 'sandbox', 'origin': _origin(settings.PARENT_CHECKOUT_ORIGIN),
            'application_id': application_id, 'location_id': provider_identifier(config.location_id, 192)}


@sensitive_variables()
def checkout_capability():
    try:
        public_checkout_configuration()
    except (ParentCheckoutUnavailable, SquareDisabled, SquareConfigurationError):
        return {'state': 'unavailable', 'reason_code': 'not_configured'}
    return {'state': 'available', 'reason_code': 'sandbox_only'}


@require_GET
@never_cache
@sensitive_variables()
def parent_checkout(request):
    try:
        public = public_checkout_configuration()
        if (not request.is_secure() or request.GET
                or f'https://{request.get_host()}' != public['origin']):
            raise ParentCheckoutUnavailable
    except (ParentCheckoutUnavailable, SquareDisabled, SquareConfigurationError):
        raise Http404 from None
    response = render(request, 'billing/parent_checkout.html', {'runtime': public})
    response['Cache-Control'] = 'no-store, private'
    response['Referrer-Policy'] = 'no-referrer'
    response['X-Frame-Options'] = 'DENY'
    response['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
    response['Content-Security-Policy'] = (
        "default-src 'none'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; "
        "form-action 'none'; script-src 'self' https://sandbox.web.squarecdn.com; "
        "connect-src 'self' https://sandbox.web.squarecdn.com https://pci-connect.squareupsandbox.com "
        "https://o160250.ingest.sentry.io; frame-src https://sandbox.web.squarecdn.com; "
        "style-src 'self' 'unsafe-inline' https://sandbox.web.squarecdn.com; "
        "font-src 'self' https://square-fonts-production-f.squarecdn.com https://d1g145x70srn7h.cloudfront.net; "
        "img-src 'self' data: https://sandbox.web.squarecdn.com"
    )
    return response
