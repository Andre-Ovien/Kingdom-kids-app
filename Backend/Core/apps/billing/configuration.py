"""Explicit environment-bound configuration; production activation defaults off."""
from dataclasses import dataclass, field
from datetime import date
import re
from urllib.parse import urlsplit

from django.conf import settings
from django.views.decorators.debug import sensitive_variables


class SquareDisabled(Exception):
    pass


class SquareConfigurationError(Exception):
    pass


def payment_environment(environment):
    if environment not in {'sandbox', 'production'}:
        raise SquareConfigurationError('A known payment environment is required.')
    return environment


def active_billing_environment():
    """Server configuration only; never a request/query/body selector."""
    return payment_environment(getattr(settings, 'SQUARE_ENVIRONMENT', 'sandbox'))


def environment_prefix(environment):
    return 'SQUARE_' + payment_environment(environment).upper()


def parent_allowed(parent, *, environment='sandbox'):
    payment_environment(environment)
    if environment == 'sandbox':
        return sandbox_parent_allowed(parent)
    return bool(parent is not None and parent.is_authenticated and parent.is_active and parent.is_email_verified)


def require_payment_parent(parent, *, environment='sandbox'):
    if not parent_allowed(parent, environment=environment):
        raise SquareDisabled('Payment parent is not eligible in this environment.')


def assert_client_environment(client, *, environment='sandbox'):
    # Historical synthetic clients without a tag are Sandbox only.
    if getattr(client, 'environment', 'sandbox') != payment_environment(environment):
        raise SquareConfigurationError('Payment client environment does not match the operation.')


def require_production_qualified():
    if (getattr(settings, 'SQUARE_PRODUCTION_RELEASE_QUALIFIED', False) is not True
            or getattr(settings, 'PAID_CONTENT_ENFORCEMENT_ENABLED', False) is not True
            or getattr(settings, 'PARENT_CONTENT_ACCESS_STATUS_ENABLED', False) is not True
            or getattr(settings, 'PAID_CONTENT_ENTITLEMENT_ENVIRONMENT', '') != 'production'):
        raise SquareDisabled('Production billing is not explicitly release-qualified.')


def require_checkout_enabled(*, environment='sandbox'):
    if environment == 'production':
        require_production_qualified()
        if (getattr(settings, 'SQUARE_PRODUCTION_CHECKOUT_ENABLED', False) is not True
                or getattr(settings, 'PARENT_CHECKOUT_PRODUCTION_ENABLED', False) is not True):
            raise SquareDisabled('Production checkout is not explicitly release-qualified.')
    payment_environment(environment)


def sandbox_test_parent_ids():
    """Bounded operator enrollment, independent of signup or client claims."""
    raw = getattr(settings, 'SQUARE_SANDBOX_TEST_PARENT_IDS', '')
    if not isinstance(raw, str) or len(raw) > 2100:
        raise SquareConfigurationError('Invalid Sandbox test-parent enrollment.')
    if not raw.strip():
        return frozenset()
    values = raw.split(',')
    if len(values) > 100:
        raise SquareConfigurationError('Invalid Sandbox test-parent enrollment.')
    result = set()
    for value in values:
        value = value.strip()
        if not re.fullmatch(r'[1-9][0-9]{0,18}', value) or int(value) > 9223372036854775807:
            raise SquareConfigurationError('Invalid Sandbox test-parent enrollment.')
        result.add(int(value))
    return frozenset(result)


def sandbox_parent_allowed(parent):
    try:
        return bool(parent is not None and parent.is_authenticated and parent.is_active
                    and parent.is_email_verified and parent.pk in sandbox_test_parent_ids())
    except SquareConfigurationError:
        return False


def require_sandbox_test_parent(parent):
    if not sandbox_parent_allowed(parent):
        raise SquareDisabled('Sandbox test parent is not enrolled.')


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
    environment: str = 'sandbox'


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
def checkout_configuration(*, reconciliation=False, terms=False, environment='sandbox'):
    payment_environment(environment)
    if environment == 'production' and not terms:
        raise SquareDisabled('Historical automatic-subscription operations are Sandbox only.')
    flag = (environment_prefix(environment) + '_TERM_BILLING_ENABLED' if terms else
            'SQUARE_SANDBOX_RECONCILIATION_ENABLED' if reconciliation else 'SQUARE_SANDBOX_CHECKOUT_ENABLED')
    if not getattr(settings, flag, False):
        raise SquareDisabled('Square sandbox checkout or reconciliation is disabled.')
    if not reconciliation and not terms and not getattr(settings, 'SQUARE_SANDBOX_CANCELLATION_ENABLED', False):
        raise SquareConfigurationError('Renewal cancellation must be explicitly configured before checkout.')
    provider = square_configuration(environment=environment)
    return SquareCheckoutConfiguration(provider=provider,
        location_id=provider_identifier(getattr(settings, environment_prefix(environment) + '_LOCATION_ID', ''), 192),
        variation_id='' if terms else provider_identifier(settings.SQUARE_SANDBOX_PLAN_VARIATION_ID))


@sensitive_variables()
def configured_client(*, environment='sandbox'):
    """Explicit fixed-environment client/transport; no credential fallback."""
    from .client import SquareProductionClient, SquareSandboxClient
    square_configuration(environment=environment)
    prefix = environment_prefix(environment)
    factory = getattr(settings, prefix + '_TRANSPORT_FACTORY', None)
    try:
        if factory is not None:
            if not callable(factory): raise ValueError
            transport = factory()
        elif getattr(settings, prefix + '_HTTP_TRANSPORT_ENABLED', False) is True:
            from .http_transport import ProductionTransport, SandboxTransport
            transport = ProductionTransport() if environment == 'production' else SandboxTransport()
        else:
            raise ValueError
        if not callable(getattr(transport, 'send', None)):
            raise ValueError
        bound_environment = getattr(transport, 'environment', environment)
        if isinstance(bound_environment, str) and bound_environment != environment:
            raise ValueError
        return (SquareProductionClient if environment == 'production' else SquareSandboxClient)(transport)
    except Exception:
        raise SquareConfigurationError('No valid explicit Square sandbox transport factory is configured.') from None


@sensitive_variables()
def square_configuration(*, webhook=False, environment='sandbox'):
    prefix = environment_prefix(environment)
    if getattr(settings, prefix + '_ENABLED', False) is not True:
        raise SquareDisabled('Square sandbox is disabled.')
    if active_billing_environment() != environment:
        raise SquareConfigurationError('Payment operation does not match the server environment.')
    merchant = getattr(settings, prefix + '_MERCHANT_ID', '')
    token = getattr(settings, prefix + '_ACCESS_TOKEN', '')
    key = getattr(settings, prefix + '_WEBHOOK_SIGNATURE_KEY', '')
    url = getattr(settings, prefix + '_WEBHOOK_NOTIFICATION_URL', '')
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
        max_response_bytes=1_048_576, max_webhook_bytes=settings.SQUARE_WEBHOOK_MAX_BODY_BYTES,
        environment=environment)
