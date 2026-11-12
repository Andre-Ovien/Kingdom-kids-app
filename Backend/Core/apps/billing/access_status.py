"""Read-only parent access discovery, independent of the paid rollout bypass."""
from django.conf import settings
from apps.accounts.authentication import VerifiedEmailJWTAuthentication
from .checkout_auth import CheckoutSessionAuthentication
from django.db import DatabaseError
from django.utils import timezone
from django.utils.cache import patch_vary_headers
from django.views.decorators.debug import sensitive_variables
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle, UserRateThrottle
from rest_framework.views import APIView

from .models import SquareBillingTerm, SquareCheckoutIntent
from .permissions import verified_paid_coverage_until
from .configuration import sandbox_parent_allowed, active_billing_environment, SquareConfigurationError


def _base(parent, now):
    return {'schema_version': 1, 'parent_id': str(parent.pk),
            'environment': settings.PAID_CONTENT_ENTITLEMENT_ENVIRONMENT
                if settings.PAID_CONTENT_ENTITLEMENT_ENVIRONMENT in {'sandbox', 'production'} else None,
            'evaluated_at': now.isoformat(), 'access_state': 'unknown',
            'access_until': None, 'reason_code': 'not_qualified',
            'content_enforcement_enabled': settings.PAID_CONTENT_ENFORCEMENT_ENABLED is True,
            'parent_plan_routing_enabled': False,
            'checkout': {'state': 'unavailable', 'reason_code': 'not_configured',
                         'management_state': 'unavailable', 'management_reason_code': 'not_qualified',
                         'handoff_available': False, 'management_handoff_available': False,
                         'controlled_parent_eligible': False},
            'purchase_recovery': None, 'management_recovery': None, 'hosted_checkout_recovery': None}


def _owned_recovery(parent, *, environment='sandbox'):
    """Never create/reconcile a purchase while discovering existing work."""
    from .term_plans import term_plan_for_policy
    intents = list(SquareCheckoutIntent.objects.filter(parent=parent, is_open=True, environment=environment)
                   .only('id', 'policy_id', 'state', 'checkout_mode', 'processing_lease').order_by('-created_at')[:2])
    if not intents:
        return None
    if len(intents) != 1:
        return {'state': 'review_required', 'source_allowed': False, 'requires_review': True}
    intent = intents[0]
    try:
        plan = term_plan_for_policy(intent.policy_id)
    except ValueError:
        return {'state': 'review_required', 'source_allowed': False, 'requires_review': True}
    term = (SquareBillingTerm.objects.filter(environment=environment, agreement__environment=environment, agreement__parent=parent,
            agreement__intent_reference=intent.pk).select_related('agreement').order_by('-created_at').first())
    source_allowed = (term is None and intent.checkout_mode == 'payments'
                      and intent.state == 'reserved' and plan.purchasable
                      and intent.processing_lease is None)
    return {'intent_id': str(intent.pk), 'billing_period': plan.billing_period,
            'state': 'reserved' if source_allowed else 'existing_purchase',
            'source_allowed': source_allowed,
            'requires_review': term is None or term.state not in {'paid', 'failed', 'refunded'},
            'restart_allowed': bool(term and term.state == 'failed' and term.canonical_sha256
                and isinstance(term.payment_evidence, dict)
                and term.payment_id and term.payment_evidence.get('id') == term.payment_id
                and term.payment_evidence.get('status') in {'FAILED', 'CANCELED'}),
            'renewals_enabled': bool(term and term.agreement.renewals_enabled),
            'renewals_ready': bool(term and term.agreement.renewals_enabled and term.agreement.activated_at),
            'setup_required': bool(term and term.state == 'paid'
                and term.payment_source_mode == 'web_charge_and_store'
                and term.agreement.renewals_enabled and not term.agreement.activated_at)}


@sensitive_variables()
def parent_content_access(parent, *, at=None):
    now = at if at is not None else timezone.now()
    if timezone.is_naive(now):
        raise ValueError('Access evaluation requires an aware timestamp.')
    result = _base(parent, now)
    if getattr(settings, 'PARENT_CONTENT_ACCESS_STATUS_ENABLED', False) is not True:
        return result
    environment = settings.PAID_CONTENT_ENTITLEMENT_ENVIRONMENT
    if (environment not in {'sandbox', 'production'} or not parent.is_authenticated
            or not parent.is_active or not parent.is_email_verified):
        return result
    from .hosted_provider import hosted_enabled
    if environment == 'sandbox' and not hosted_enabled(environment) and not sandbox_parent_allowed(parent):
        result['reason_code'] = 'not_enrolled'
        result['checkout']['reason_code'] = 'not_enrolled'
        try:
            from .parent_checkout_web import checkout_capability
            result['checkout'] = checkout_capability(parent)
            result['management_recovery'] = result['checkout'].pop('management_recovery', None)
        except (DatabaseError, ValueError, SquareConfigurationError):
            result['checkout'].update(management_state='unknown', management_reason_code='temporarily_unavailable')
        return result
    try:
        end = verified_paid_coverage_until(parent, environment=environment, at=now)
        if end is not None:
            result.update(access_state='paid', access_until=end.isoformat(), reason_code='active_proof')
        result['purchase_recovery'] = _owned_recovery(parent, environment=environment)
        if result['access_state'] == 'paid' and result['purchase_recovery']:
            result['purchase_recovery']['restart_allowed'] = False
        if result['access_state'] != 'paid':
            if (result['purchase_recovery'] is not None
                    and result['purchase_recovery']['requires_review']):
                result['reason_code'] = 'purchase_requires_recovery'
            else:
                result.update(access_state='unpaid', reason_code='no_active_proof')
        from .parent_checkout_web import checkout_capability
        result['checkout'] = checkout_capability(parent)
        result['management_recovery'] = result['checkout'].pop('management_recovery', None)
        if hosted_enabled(environment) or result['checkout'].get('provider')=='square_hosted':
            from .hosted_checkout import recovery
            result['hosted_checkout_recovery'] = recovery(parent,environment)
            if result['access_state'] != 'paid' and result['hosted_checkout_recovery'] and result['hosted_checkout_recovery']['state'] in {'creating','pending','review_required'}:
                result.update(access_state='unknown',reason_code='purchase_requires_recovery')
        result['parent_plan_routing_enabled'] = bool(
            (environment == 'sandbox' and result['checkout']['state'] == 'available')
            or (environment == 'production' and active_billing_environment() == 'production'
                and settings.PAID_CONTENT_ENFORCEMENT_ENABLED is True))
    except (DatabaseError, ValueError, SquareConfigurationError):
        result = _base(parent, now)
        result['reason_code'] = 'temporarily_unavailable'
        result['checkout'].update(management_state='unknown', management_reason_code='temporarily_unavailable')
    return result


class ParentContentAccessView(APIView):
    authentication_classes = (CheckoutSessionAuthentication, VerifiedEmailJWTAuthentication)
    permission_classes = (IsAuthenticated,)
    throttle_classes = (ScopedRateThrottle, UserRateThrottle)
    throttle_scope = 'billing_status'

    @sensitive_variables()
    def get(self, request):
        return Response(parent_content_access(request.user))

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response['Cache-Control'] = 'no-store, private'
        patch_vary_headers(response, ['Authorization'])
        return response
