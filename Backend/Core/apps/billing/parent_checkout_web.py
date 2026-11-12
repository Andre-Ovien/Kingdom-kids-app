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
                            checkout_configuration, provider_identifier,
                            sandbox_parent_allowed, sandbox_test_parent_ids)


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
def public_checkout_configuration(*, purpose='purchase'):
    from .configuration import active_billing_environment, environment_prefix, require_checkout_enabled
    environment = active_billing_environment()
    if (purpose not in {'purchase', 'manage'}
            or getattr(settings, 'PARENT_CONTENT_ACCESS_STATUS_ENABLED', False) is not True
            or settings.PAID_CONTENT_ENTITLEMENT_ENVIRONMENT != environment):
        raise ParentCheckoutUnavailable
    public = {'environment': environment, 'origin': _origin(settings.PARENT_CHECKOUT_ORIGIN),
              'purpose': purpose, 'application_id': '', 'location_id': ''}
    if purpose == 'manage':
        # Local owned status/cancellation survives a new-payment pause and does
        # not require provider credentials, card setup or a transport.
        return public
    if getattr(settings, 'PARENT_CHECKOUT_' + environment.upper() + '_ENABLED', False) is not True:
        raise ParentCheckoutUnavailable
    require_checkout_enabled(environment=environment)
    config = checkout_configuration(terms=True, environment=environment)
    if environment == 'sandbox' and not sandbox_test_parent_ids():
        raise ParentCheckoutUnavailable
    prefix = environment_prefix(environment)
    application_id = getattr(settings, prefix + '_APPLICATION_ID', '')
    pattern = r'sandbox-[A-Za-z0-9_-]{8,160}' if environment == 'sandbox' else r'sq0id[pb]-[A-Za-z0-9_-]{8,160}'
    if not isinstance(application_id, str) or not re.fullmatch(pattern, application_id):
        raise ParentCheckoutUnavailable
    if (getattr(settings, prefix + '_HTTP_TRANSPORT_ENABLED', False) is not True
            and not callable(getattr(settings, prefix + '_TRANSPORT_FACTORY', None))):
        raise ParentCheckoutUnavailable
    return {**public, 'application_id': application_id, 'location_id': provider_identifier(config.location_id, 192)}


@sensitive_variables()
def checkout_capability(parent, *, purpose='purchase'):
    from .configuration import active_billing_environment, parent_allowed
    from .models import SquareContentAgreement
    environment = active_billing_environment()
    result = {'state': 'unavailable', 'reason_code': 'not_configured',
              'management_state': 'unavailable', 'management_reason_code': 'no_owned_purchase',
              'handoff_available': False, 'management_handoff_available': False,
              'management_recovery': None}
    # Management is owner-bound, independent of new-charge enrollment/flags.
    try:
        public_checkout_configuration(purpose='manage')
        owned = SquareContentAgreement.objects.filter(parent=parent, environment=environment).order_by(
            '-renewals_enabled', '-created_at', '-pk').values('intent_reference', 'policy_id', 'renewals_enabled').first()
        if owned:
            from .term_plans import term_plan_for_policy
            period = term_plan_for_policy(owned['policy_id']).billing_period
            result.update(management_state='available', management_reason_code='owned_purchase')
            result['management_recovery'] = {'intent_id': str(owned['intent_reference']),
                'billing_period': period,
                'source_allowed': False, 'requires_review': False,
                'renewals_enabled': owned['renewals_enabled'], 'setup_required': False}
    except (ParentCheckoutUnavailable, SquareDisabled, SquareConfigurationError, ValueError):
        pass
    eligible = parent_allowed(parent, environment=environment)
    if not eligible:
        result['reason_code'] = 'not_enrolled' if environment == 'sandbox' else 'not_qualified'
    else:
        try:
            public_checkout_configuration()
            result.update(state='available', reason_code='sandbox_only' if environment == 'sandbox' else 'production_qualified')
        except (ParentCheckoutUnavailable, SquareDisabled, SquareConfigurationError):
            pass
    available = result['management_state'] == 'available' if purpose == 'manage' else result['state'] == 'available'
    result['handoff_available'] = bool(available and getattr(settings, 'PARENT_CHECKOUT_HANDOFF_ENABLED', False) is True)
    result['management_handoff_available'] = bool(result['management_state'] == 'available'
        and getattr(settings, 'PARENT_CHECKOUT_HANDOFF_ENABLED', False) is True)
    if purpose == 'manage':
        result.update(state=result['management_state'], reason_code=result['management_reason_code'])
    return result


@require_GET
@never_cache
@sensitive_variables()
def parent_checkout(request):
    try:
        purpose = 'manage' if request.GET.get('purpose') == 'manage' else 'purchase'
        public = public_checkout_configuration(purpose=purpose)
        selected_plan = None
        if request.GET:
            if purpose == 'manage':
                if set(request.GET) != {'purpose'} or request.GET.getlist('purpose') != ['manage']:
                    raise ParentCheckoutUnavailable
            else:
                if set(request.GET) != {'plan'} or len(request.GET.getlist('plan')) != 1:
                    raise ParentCheckoutUnavailable
                selected_plan = request.GET['plan']
                if selected_plan not in {'monthly', 'yearly'}:
                    raise ParentCheckoutUnavailable
        if (not request.is_secure() or f'https://{request.get_host()}' != public['origin']):
            raise ParentCheckoutUnavailable
    except (ParentCheckoutUnavailable, SquareDisabled, SquareConfigurationError):
        raise Http404 from None
    response = render(request, 'billing/parent_checkout.html', {
        'runtime': {**public, 'selected_plan': selected_plan}, 'selected_plan': selected_plan, 'manage_only': purpose == 'manage'})
    response['Cache-Control'] = 'no-store, private'
    response['Referrer-Policy'] = 'no-referrer'
    response['X-Frame-Options'] = 'DENY'
    response['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
    sdk_origin = ('https://sandbox.web.squarecdn.com' if public['environment'] == 'sandbox'
                  else 'https://web.squarecdn.com')
    pci_origin = ('https://pci-connect.squareupsandbox.com' if public['environment'] == 'sandbox'
                  else 'https://pci-connect.squareup.com')
    response['Content-Security-Policy'] = (
        "default-src 'none'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; "
        f"form-action 'none'; script-src 'self' {sdk_origin}; "
        f"connect-src 'self' {sdk_origin} {pci_origin} "
        f"https://o160250.ingest.sentry.io; frame-src {sdk_origin}; "
        f"style-src 'self' 'unsafe-inline' {sdk_origin}; "
        "font-src 'self' https://square-fonts-production-f.squarecdn.com https://d1g145x70srn7h.cloudfront.net; "
        f"img-src 'self' data: {sdk_origin}"
    )
    return response
