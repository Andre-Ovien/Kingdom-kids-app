"""Disabled-by-default, sandbox-only backend configuration."""
from dataclasses import dataclass, field
from datetime import date
from urllib.parse import urlsplit

from django.conf import settings
from django.views.decorators.debug import sensitive_variables


class SquareDisabled(Exception):
    pass


class SquareConfigurationError(Exception):
    pass


@dataclass(frozen=True)
class SquareConfiguration:
    merchant_id: str
    api_version: str
    access_token: str = field(repr=False)
    signature_key: str = field(repr=False)
    notification_url: str
    timeout_seconds: int
    max_response_bytes: int
    max_webhook_bytes: int


@dataclass(frozen=True)
class SquareCheckoutConfiguration:
    provider: SquareConfiguration
    location_id: str
    variation_id: str


def provider_identifier(value, maximum=255):
    if (not isinstance(value, str) or not 1 <= len(value) <= maximum
            or any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value)):
        raise SquareConfigurationError('Invalid Square identifier.')
    try:
        value.encode('utf-8')
    except UnicodeEncodeError:
        raise SquareConfigurationError('Invalid Square identifier.') from None
    return value


@sensitive_variables()
def checkout_configuration(*, reconciliation=False, terms=False):
    flag = ('SQUARE_SANDBOX_TERM_BILLING_ENABLED' if terms else
            'SQUARE_SANDBOX_RECONCILIATION_ENABLED' if reconciliation else 'SQUARE_SANDBOX_CHECKOUT_ENABLED')
    if not getattr(settings, flag, False):
        raise SquareDisabled('Square sandbox checkout or reconciliation is disabled.')
    if not reconciliation and not terms and not getattr(settings, 'SQUARE_SANDBOX_CANCELLATION_ENABLED', False):
        raise SquareConfigurationError('Renewal cancellation must be explicitly configured before checkout.')
    provider = square_configuration()
    return SquareCheckoutConfiguration(provider=provider,
        location_id=provider_identifier(settings.SQUARE_SANDBOX_LOCATION_ID, 192),
        variation_id='' if terms else provider_identifier(settings.SQUARE_SANDBOX_PLAN_VARIATION_ID))


@sensitive_variables()
def configured_client():
    """Explicit callable injection or separately enabled builtin SANDBOX TLS."""
    from .client import SquareSandboxClient
    square_configuration()  # Refuse disabled/production even before constructing a factory.
    factory = getattr(settings, 'SQUARE_SANDBOX_TRANSPORT_FACTORY', None)
    try:
        if factory is not None:
            if not callable(factory): raise ValueError
            transport = factory()
        elif getattr(settings, 'SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED', False) is True:
            from .http_transport import SandboxTransport
            transport = SandboxTransport()
        else:
            raise ValueError
        if not callable(getattr(transport, 'send', None)):
            raise ValueError
        return SquareSandboxClient(transport)
    except Exception:
        raise SquareConfigurationError('No valid explicit Square sandbox transport factory is configured.') from None


@sensitive_variables()
def square_configuration(*, webhook=False):
    if not settings.SQUARE_SANDBOX_ENABLED:
        raise SquareDisabled('Square sandbox is disabled.')
    if settings.SQUARE_ENVIRONMENT != 'sandbox':
        raise SquareConfigurationError('Only Square sandbox is supported.')
    merchant = settings.SQUARE_SANDBOX_MERCHANT_ID
    token = settings.SQUARE_SANDBOX_ACCESS_TOKEN
    key = settings.SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY
    url = settings.SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL
    version = settings.SQUARE_API_VERSION
    try:
        if (type(settings.SQUARE_HTTP_TIMEOUT_SECONDS) is not int
                or not 1 <= settings.SQUARE_HTTP_TIMEOUT_SECONDS <= 15
                or type(settings.SQUARE_WEBHOOK_MAX_BODY_BYTES) is not int
                or not 1024 <= settings.SQUARE_WEBHOOK_MAX_BODY_BYTES <= 1_048_576):
            raise ValueError
        if date.fromisoformat(version).isoformat() != version:
            raise ValueError
        if (not isinstance(merchant, str) or not merchant or len(merchant) > 192
                or any(ord(char) <= 32 for char in merchant)):
            raise ValueError
        if webhook:
            parsed = urlsplit(url)
            if (not isinstance(key, str) or not key or any(ord(char) <= 32 for char in key)
                    or not url or any(char in url for char in '\\?#') or any(ord(char) <= 32 for char in url)
                    or parsed.scheme != 'https' or not parsed.hostname
                    or parsed.username or parsed.password or parsed.query or parsed.fragment
                    or parsed.port not in {None, 443}):
                raise ValueError
        elif (not isinstance(token, str) or not token or any(ord(char) <= 32 for char in token)):
            raise ValueError
    except (ValueError, TypeError, AttributeError):
        raise SquareConfigurationError('Square sandbox configuration is incomplete or invalid.') from None
    return SquareConfiguration(merchant_id=merchant, api_version=version,
        access_token=token, signature_key=key, notification_url=url,
        timeout_seconds=settings.SQUARE_HTTP_TIMEOUT_SECONDS,
        max_response_bytes=1_048_576, max_webhook_bytes=settings.SQUARE_WEBHOOK_MAX_BODY_BYTES)
