"""Parent-owned Sandbox checkout operations; no implicit network or grants."""
from datetime import timedelta
import hashlib
import json
from urllib.parse import urlsplit
from uuid import uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from django.db import IntegrityError, transaction
from django.utils import timezone
from django.views.decorators.debug import sensitive_variables

from .client import SquareClientError
from .configuration import checkout_configuration, configured_client, provider_identifier
from .models import SquareCheckoutIntent
from .plans import POLICY_SHA256, confirmed_content_plan
from .term_plans import content_term_plan, term_plan_for_policy


DISCLOSURE_VERSION = 'usd999-monthly-28-full-immediate-v1'
DISCLOSURE = ('You authorize $9.99 USD immediately and another $9.99 USD on the next 28th, '
              'then $9.99 USD on the 28th of every month. There is no free period or proration. '
              'The first two payments may be close together. You authorize Square to save your '
              'tokenized payment method for these recurring charges. This subscription covers all stories and games.')
LEASE_DURATION = timedelta(minutes=5)


class CheckoutRejected(Exception):
    pass


class CheckoutConflict(CheckoutRejected):
    pass


class CheckoutBusy(CheckoutRejected):
    pass


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     allow_nan=False).encode()).hexdigest()


def public_terms():
    plan = confirmed_content_plan()
    return {'policy_id': plan.policy_id, 'policy_sha256': POLICY_SHA256,
            'disclosure_version': DISCLOSURE_VERSION, 'disclosure': DISCLOSURE,
            'amount_minor': plan.amount_minor, 'currency': plan.currency, 'cadence': plan.cadence,
            'monthly_billing_anchor_date': plan.anchor_day, 'can_prorate': False,
            'free_period': False, 'environment': 'sandbox', 'country': 'US'}


@sensitive_variables()
def _check_parent(parent, password):
    if (not parent.is_active or not parent.email_verified_at
            or not isinstance(password, str) or not 1 <= len(password) <= 1024
            or not parent.check_password(password)):
        raise CheckoutRejected('Fresh parent password confirmation is required.')


@sensitive_variables()
def reserve_checkout(*, parent, password, disclosure_version, accepted, mode='direct',
                     billing_timezone='', disclosure_sha256='', billing_period='monthly'):
    if mode != 'payments':
        raise CheckoutRejected('Historical automatic-subscription checkout is retired and read-only.')
    config = checkout_configuration(terms=True)
    plan = content_term_plan(billing_period) if mode == 'payments' else confirmed_content_plan()
    policy_sha = plan.policy_sha256 if mode == 'payments' else POLICY_SHA256
    if mode not in {'direct', 'hosted', 'payments'}:
        raise CheckoutRejected('Unsupported checkout mode.')
    expected_version = DISCLOSURE_VERSION
    if mode == 'payments':
        expected_version = plan.disclosure_version
    if accepted is not True or disclosure_version != expected_version:
        raise CheckoutRejected('Accept the current billing disclosure before continuing.')
    digest = fingerprint({'policy': policy_sha, 'merchant': config.provider.merchant_id,
                          'location': config.location_id, 'variation': config.variation_id, 'mode': mode,
                          'billing_timezone': billing_timezone, 'disclosure_sha256': disclosure_sha256})
    with transaction.atomic():
        locked_parent = type(parent).objects.select_for_update().get(pk=parent.pk)
        _check_parent(locked_parent, password)
        existing_query = SquareCheckoutIntent.objects.filter(parent=locked_parent, is_open=True)
        existing = (existing_query.filter(checkout_mode='payments').first() if mode == 'payments'
            else existing_query.filter(policy_id=plan.policy_id).first())
        if existing:
            from .models import SquareContentAgreement
            from django.db.models import Q, Max
            agreement = SquareContentAgreement.objects.select_for_update().filter(intent_reference=existing.pk).first()
            if agreement and not agreement.renewals_enabled and term_plan_for_policy(existing.policy_id).purchasable:
                now = timezone.now()
                paid_end = agreement.terms.filter(captured_at__isnull=False).aggregate(end=Max('valid_until'))['end']
                unresolved = agreement.terms.filter(
                    ~Q(state__in=('paid','refunded','failed'))
                    | (Q(processing_lease__isnull=False) & Q(lease_until__gt=now))).exists()
                if paid_end is not None and paid_end <= now and not unresolved:
                    existing.is_open,existing.state = False,'closed_expired_paid'
                    existing.save(update_fields=('is_open','state','updated_at'))
                    existing = None
        if existing and existing.policy_id != plan.policy_id:
            raise CheckoutConflict('Finish or safely close the existing purchase before selecting another billing period.')
        if existing:
            if existing.request_sha256 != digest:
                raise CheckoutConflict('An existing purchase requires reconciliation before another checkout.')
            if mode == 'payments':
                from .models import SquareContentAgreement
                if not SquareContentAgreement.objects.filter(intent_reference=existing.pk).exists():
                    existing.consented_at, existing.reauthenticated_at = timezone.now(), timezone.now()
                    existing.save(update_fields=('consented_at', 'reauthenticated_at', 'updated_at'))
            return existing
        now = timezone.now()
        from .permissions import verified_paid_coverage_until
        if any(verified_paid_coverage_until(locked_parent,environment=environment,at=now) is not None
                for environment in ('sandbox','production')):
            raise CheckoutConflict('Existing verified paid coverage must end before another purchase.')
        return SquareCheckoutIntent.objects.create(parent=locked_parent,
            merchant_id=config.provider.merchant_id, location_id=config.location_id,
            variation_id=config.variation_id, policy_id=plan.policy_id, policy_sha256=policy_sha,
            disclosure_version=disclosure_version, disclosure_sha256=disclosure_sha256,
            billing_timezone=billing_timezone, consented_at=now, reauthenticated_at=now,
            request_sha256=digest, checkout_mode=mode)


@sensitive_variables()
def acquire_intent(*, parent, intent_id, password=None, reconciliation=False, terms=False):
    config = checkout_configuration(reconciliation=reconciliation, terms=terms)
    with transaction.atomic():
        locked_parent = type(parent).objects.select_for_update().get(pk=parent.pk)
        if password is not None:
            _check_parent(locked_parent, password)
        elif not locked_parent.is_active or not locked_parent.email_verified_at:
            raise CheckoutRejected('A verified active parent is required.')
        intent = SquareCheckoutIntent.objects.select_for_update().get(pk=intent_id, parent=locked_parent)
        policy_sha = term_plan_for_policy(intent.policy_id).policy_sha256 if terms else POLICY_SHA256
        if (intent.merchant_id != config.provider.merchant_id or intent.location_id != config.location_id
                or intent.variation_id != config.variation_id or intent.policy_sha256 != policy_sha):
            raise CheckoutConflict('Checkout configuration no longer matches the reserved intent.')
        now = timezone.now()
        if intent.processing_lease and intent.lease_until and intent.lease_until > now:
            raise CheckoutBusy('Checkout is already being processed.')
        intent.processing_lease, intent.lease_until = uuid4(), now + LEASE_DURATION
        if password is not None:
            intent.reauthenticated_at = now
        intent.save(update_fields=('processing_lease', 'lease_until', 'reauthenticated_at', 'updated_at'))
        return intent, config


def checkpoint(intent, **changes):
    """A delayed worker cannot apply results after a newer worker owns lease."""
    with transaction.atomic():
        current = SquareCheckoutIntent.objects.select_for_update().get(pk=intent.pk)
        if (current.processing_lease != intent.processing_lease or not current.lease_until
                or current.lease_until <= timezone.now()):
            raise CheckoutBusy('Checkout ownership changed; retry reconciliation.')
        for key, value in changes.items():
            setattr(current, key, value)
        current.save(update_fields=(*changes, 'updated_at'))
    for key, value in changes.items():
        setattr(intent, key, value)
    return intent


def release_intent(intent, **changes):
    try:
        return checkpoint(intent, **changes, processing_lease=None, lease_until=None)
    except (CheckoutBusy, SquareCheckoutIntent.DoesNotExist):
        return None


def validate_variation(variation, *, variation_id, location_id):
    plan = confirmed_content_plan()
    if not isinstance(variation, dict):
        raise CheckoutRejected('Invalid canonical variation.')
    data = variation.get('subscription_plan_variation_data', {})
    if not isinstance(data, dict):
        raise CheckoutRejected('Invalid canonical variation data.')
    phases = data.get('phases', [])
    if (variation.get('id') != variation_id or variation.get('type') != 'SUBSCRIPTION_PLAN_VARIATION'
            or variation.get('is_deleted') is True
            or location_id in variation.get('absent_at_location_ids', [])
            or not (variation.get('present_at_all_locations') is True
                    or location_id in variation.get('present_at_location_ids', []))
            or type(data.get('monthly_billing_anchor_date')) is not int
            or data['monthly_billing_anchor_date'] != plan.anchor_day or data.get('can_prorate') is not False
            or not isinstance(phases, list) or len(phases) != 1):
        raise CheckoutRejected('The provider variation does not match the confirmed billing terms.')
    phase = phases[0]
    if (not isinstance(phase, dict) or type(phase.get('ordinal')) is not int or phase['ordinal'] != 0 or phase.get('cadence') != 'MONTHLY'
            or phase.get('periods') is not None
            or phase.get('pricing') != {'type': 'STATIC', 'price_money': {'amount': 999, 'currency': 'USD'}}):
        raise CheckoutRejected('The provider variation does not match the confirmed billing terms.')
    provider_identifier(data.get('subscription_plan_id'))
    return data['subscription_plan_id']


def verify_provider_terms(client, intent):
    """Read-only canonical verification before any financial dispatch."""
    merchant = client.retrieve_merchant(intent.merchant_id)
    location = client.retrieve_location(intent.location_id)
    if (merchant.get('id') != intent.merchant_id or merchant.get('country') != 'US'
            or location.get('id') != intent.location_id or location.get('country') != 'US'
            or location.get('currency') != 'USD' or location.get('status') != 'ACTIVE'):
        raise CheckoutRejected('The provider account/location is not the reviewed US/USD Sandbox.')
    try:
        ZoneInfo(location.get('timezone'))
    except (TypeError, ValueError, ZoneInfoNotFoundError):
        raise CheckoutRejected('The provider billing timezone is unknown.') from None
    variation = client.retrieve_catalogue_object(intent.variation_id)
    plan_id = validate_variation(variation, variation_id=intent.variation_id, location_id=intent.location_id)
    plan = client.retrieve_catalogue_object(plan_id)
    if (plan.get('id') != plan_id or plan.get('type') != 'SUBSCRIPTION_PLAN'
            or plan.get('is_deleted') is True):
        raise CheckoutRejected('The provider subscription plan is unavailable.')
    return location


def subscription_facts(subscription):
    """Only canonical structural fields, never buyer self-management tokens."""
    fields = ('id', 'location_id', 'customer_id', 'card_id', 'plan_variation_id', 'version',
              'status', 'start_date', 'timezone', 'monthly_billing_anchor_date', 'invoice_ids',
              'phases', 'canceled_date', 'completed_date', 'price_override_money', 'tax_percentage')
    return {key: subscription.get(key) for key in fields}


def validate_subscription(subscription, intent, *, direct=False):
    provider_identifier(subscription.get('id'))
    provider_identifier(subscription.get('customer_id'), 192)
    if (subscription.get('location_id') != intent.location_id
            or subscription.get('plan_variation_id') != intent.variation_id
            or type(subscription.get('version')) is not int or subscription['version'] < 1
            or subscription.get('monthly_billing_anchor_date') != 28
            or subscription.get('status') not in {'PENDING', 'ACTIVE', 'CANCELED', 'DEACTIVATED', 'PAUSED', 'COMPLETED'}
            or subscription.get('price_override_money') is not None
            or subscription.get('tax_percentage') not in (None, '0', '0.0')):
        raise CheckoutRejected('The canonical subscription does not match the reserved terms.')
    if direct:
        if (subscription.get('customer_id') != intent.customer_id
                or subscription.get('card_id') != intent.card_id):
            raise CheckoutRejected('The subscription customer/card ownership did not match.')
    else:
        phases = subscription.get('phases')
        if not isinstance(phases, list) or not any(isinstance(phase, dict)
                and phase.get('order_template_id') == intent.order_template_id for phase in phases):
            raise CheckoutRejected('The subscription lacks the exact reserved checkout template.')
    return subscription_facts(subscription)


@sensitive_variables()
def confirm_direct_checkout(*, parent, intent_id, password, source_id=None, client=None):
    """Testable direct API path. Card numbers never enter this service.

    A transport timeout keeps the same intent/keys. A later changed token cannot
    turn an uncertain operation into another card/subscription purchase.
    """
    raise CheckoutRejected('Historical automatic-subscription checkout is retired and read-only.')


def approved_hosted_url(value):
    if not isinstance(value, str) or len(value) > 2048 or any(ord(char) <= 32 for char in value):
        raise CheckoutRejected('Invalid provider checkout URL.')
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or parsed.hostname != 'sandbox.square.link'
            or parsed.port not in (None, 443) or parsed.username or parsed.password
            or parsed.query or parsed.fragment or not parsed.path.startswith('/u/') or '\\' in value):
        raise CheckoutRejected('Invalid provider checkout URL.')
    return value


@sensitive_variables()
def dispatch_hosted_checkout(*, parent, intent_id, password, client=None):
    """Limited adapter, not the primary API route or full Sandbox E2E claim."""
    raise CheckoutRejected('Historical hosted-subscription checkout is retired and read-only.')


def checkout_status(intent):
    # Own authenticated parent only. No card/token/customer/provider bodies.
    if intent.checkout_mode == 'payments':
        from .terms import term_disclosure
        from .models import SquareContentAgreement, ParentContentEntitlement
        from .plans import ALL_CONTENT_FEATURE
        from django.db.models import Q
        agreement = SquareContentAgreement.objects.filter(intent_reference=intent.pk, parent_id=intent.parent_id).first()
        from django.db.models.functions import Coalesce
        term = agreement.terms.order_by(Coalesce('request_not_before','valid_from','created_at').desc(),
            '-created_at','-pk').first() if agreement else None
        now = timezone.now()
        paid = ParentContentEntitlement.objects.filter(parent_id=intent.parent_id, provider='square',
            environment='sandbox', provider_account_id=intent.merchant_id, feature_code=ALL_CONTENT_FEATURE,
            source_reference__startswith='square-term:', payment_verified_at__lte=now,
            valid_from__lte=now, valid_until__gt=now).filter(Q(revoked_at__isnull=True) | Q(revoked_at__gt=now)).exists()
        plan = term_plan_for_policy(intent.policy_id)
        terms = (term_disclosure(intent.billing_timezone,billing_period=plan.billing_period) if plan.purchasable else
            {'policy_id':intent.policy_id,'policy_sha256':intent.policy_sha256,'disclosure_version':intent.disclosure_version,
             'disclosure_sha256':intent.disclosure_sha256,'amount_minor':plan.amount_minor,'currency':'USD',
             'cadence':plan.cadence,'billing_period':plan.billing_period,'purchasable':False,
             'detail':'Historical contract: read/refund only; no new grant or renewal.'})
        return {'id': str(intent.pk), 'state': term.state if term else intent.state,
            'outcome_code': term.outcome_code if term else intent.outcome_code,
            'terms':terms, 'access_granted':paid,
            'renewals_enabled': agreement.renewals_enabled if agreement else False,
            'renewals_ready': bool(agreement and agreement.renewals_enabled and agreement.activated_at),
            'card_storage_state': ('verified' if agreement and agreement.activated_at else
                'pending' if term and term.payment_source_mode == 'web_charge_and_store' and term.state == 'paid'
                else 'not_ready'),
            'current_term': {'id':str(term.pk), 'valid_from':term.valid_from.isoformat() if term.valid_from else None,
                'valid_until':term.valid_until.isoformat() if term.valid_until else None,
                'captured_at':term.captured_at.isoformat() if term.captured_at else None,
                'coverage_state':'bound' if term.valid_until else 'awaiting_canonical_capture', 'amount_minor': term.amount_minor, 'currency': term.currency,
                'cadence': term.cadence} if term else None}
    return {'id': str(intent.pk), 'state': intent.state, 'outcome_code': intent.outcome_code,
            'terms':{**public_terms(),'purchasable':False},'historical_read_only':True,'access_granted':False,
            'checkout_url': intent.checkout_url if intent.checkout_mode == 'hosted' else None,
            'verified_payment_count': intent.invoice_evidence.filter(
                outcome_code='invoice_coverage_unproven', revoked_at__isnull=True).count()}
