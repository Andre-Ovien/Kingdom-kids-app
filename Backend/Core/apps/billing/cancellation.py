"""Durable post-deletion renewal cancellation, never network in account locks."""
from contextlib import closing
from datetime import date, timedelta
from uuid import NAMESPACE_URL, uuid4, uuid5

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from django.views.decorators.debug import sensitive_variables

from .checkout import CheckoutRejected, fingerprint
from .client import SquareClientError, SquareResourceNotFound
from .configuration import SquareDisabled, configured_client, provider_identifier, square_configuration
from .models import (SquareCancellationOutbox, SquareCheckoutIntent, SquareSubscriptionIdentity,
                     SquareContentAgreement)
from .reconciliation import CanonicalReader, _direct_subscription, _hosted_subscription


@sensitive_variables()
def enqueue_account_cancellations(parent):
    """Runs in the same deletion transaction before cascades remove identities.

    Flags/secrets are intentionally irrelevant to durable retention. Deletion
    does not wait for a provider, but database persistence must be atomic with
    deletion so a DB outage cannot erase the only recurring-billing reference.
    """
    # App-owned recurring contracts stop in this same transaction. Their frozen
    # terms retain only provider/evidence refs for an already in-flight payment;
    # no autonomous remote subscription exists for this mode.
    SquareContentAgreement.objects.filter(parent=parent).update(renewals_enabled=False,
        canceled_at=timezone.now(), outcome_code='account_deleted', customer_id='', card_id='')
    query = SquareCheckoutIntent.objects.select_for_update().filter(parent=parent, environment='sandbox').exclude(checkout_mode='payments')
    with closing(query.iterator(chunk_size=100)) as rows:
        for intent in rows:
            SquareCancellationOutbox.objects.get_or_create(intent_reference=intent.pk, environment='sandbox', defaults={
                'checkout_mode': intent.checkout_mode, 'merchant_id': intent.merchant_id,
                'location_id': intent.location_id, 'variation_id': intent.variation_id,
                'customer_id': intent.customer_id, 'card_id': intent.card_id,
                'subscription_id': intent.subscription_id, 'payment_link_id': intent.payment_link_id,
                'order_template_id': intent.order_template_id})
    # Preserve the original server-only observation/binding seam as well.
    legacy = SquareSubscriptionIdentity.objects.filter(customer__parent=parent, environment='sandbox', customer__environment='sandbox').select_related('customer')
    with closing(legacy.iterator(chunk_size=100)) as rows:
        for identity in rows:
            reference = uuid5(NAMESPACE_URL, 'kingdom-kids/deleted-subscription/'
                             + identity.customer.merchant_id + '/' + identity.subscription_id)
            SquareCancellationOutbox.objects.get_or_create(intent_reference=reference, environment='sandbox', defaults={
                'checkout_mode': 'legacy', 'merchant_id': identity.customer.merchant_id,
                'customer_id': identity.customer.customer_id, 'subscription_id': identity.subscription_id})


def cancellation_configuration():
    if not getattr(settings, 'SQUARE_SANDBOX_CANCELLATION_ENABLED', False):
        raise SquareDisabled('Square Sandbox cancellation is disabled.')
    return square_configuration()


def _checkpoint(job, **changes):
    with transaction.atomic():
        current = SquareCancellationOutbox.objects.select_for_update().get(pk=job.pk, environment='sandbox')
        if (current.processing_lease != job.processing_lease or not current.lease_until
                or current.lease_until <= timezone.now()):
            raise CheckoutRejected('Cancellation lease ownership changed.')
        for key, value in changes.items(): setattr(current, key, value)
        current.save(update_fields=tuple(changes))
    for key, value in changes.items(): setattr(job, key, value)


def _verify_subscription_owner(subscription, job, *, recovered=False):
    if (subscription.get('id') != job.subscription_id or not job.customer_id
            or subscription.get('customer_id') != job.customer_id
            or (job.location_id and subscription.get('location_id') != job.location_id)
            or (recovered and job.variation_id and subscription.get('plan_variation_id') != job.variation_id)
            or (recovered and job.checkout_mode == 'direct' and subscription.get('card_id') != job.card_id)):
        raise CheckoutRejected('Cancellation provider identity does not match retained ownership.')
    if recovered and job.checkout_mode == 'hosted':
        phases = subscription.get('phases', [])
        if not isinstance(phases, list) or not any(isinstance(phase, dict)
                and phase.get('order_template_id') == job.order_template_id for phase in phases):
            raise CheckoutRejected('The deleted hosted checkout template does not match.')


def _cancellation_proof(subscription):
    if subscription.get('status') in {'CANCELED', 'COMPLETED'}:
        return None, 'cancellation_terminal_verified'
    canceled = subscription.get('canceled_date')
    try:
        if isinstance(canceled, str) and date.fromisoformat(canceled).isoformat() == canceled:
            return date.fromisoformat(canceled), 'renewal_cancellation_scheduled_verified'
    except ValueError:
        pass
    return None, None


@sensitive_variables()
def process_cancellation(*, outbox_id, client=None):
    config = cancellation_configuration()
    client = client or configured_client()
    now = timezone.now()
    with transaction.atomic():
        job = SquareCancellationOutbox.objects.select_for_update().get(pk=outbox_id, environment='sandbox',
                                                                      merchant_id=config.merchant_id)
        if job.state == 'verified': return 'verified'
        if job.processing_lease and job.lease_until and job.lease_until > now: return 'busy'
        if job.next_attempt_at and job.next_attempt_at > now: return 'retry'
        job.processing_lease, job.lease_until = uuid4(), now + timedelta(minutes=5)
        job.state, job.attempts = 'processing', job.attempts + 1
        job.save()
    reader = CanonicalReader(client, job.lease_until)
    recovered = not bool(job.subscription_id)
    try:
        merchant = reader.retrieve_merchant(job.merchant_id)
        if merchant.get('id') != job.merchant_id or merchant.get('country') != 'US':
            raise CheckoutRejected('Cancellation merchant identity does not match.')
        if job.checkout_mode == 'hosted' and job.payment_link_id and not job.link_disabled_at:
            try:
                link = reader.retrieve_payment_link(job.payment_link_id)
            except SquareResourceNotFound:
                link = None
            if link is not None:
                if link.get('order_id') != job.order_template_id:
                    raise CheckoutRejected('Hosted cancellation link/template identity is inconsistent.')
                client.delete_payment_link(job.payment_link_id)
                try:
                    reader.retrieve_payment_link(job.payment_link_id)
                except SquareResourceNotFound:
                    pass
                else:
                    raise SquareClientError('Hosted checkout link deletion is not verified yet.')
            _checkpoint(job, link_disabled_at=timezone.now())
        if not job.subscription_id:
            if job.checkout_mode == 'direct' and not job.card_id:
                # The pipeline checkpoints its card BEFORE any subscription
                # POST. An in-flight card/customer response cannot later pass
                # its deleted intent checkpoint and start financial dispatch.
                _checkpoint(job, state='verified', verified_at=timezone.now(),
                    outcome_code='no_subscription_dispatched', customer_id='', card_id='',
                    processing_lease=None, lease_until=None)
                return 'verified'
            # The helper expects pk to be the original intent UUID, not job PK.
            class RetainedIntent:
                pass
            retained = RetainedIntent()
            for key in ('customer_id', 'card_id', 'location_id', 'variation_id', 'order_template_id', 'subscription_id'):
                setattr(retained, key, getattr(job, key))
            retained.pk = job.intent_reference
            subscription = (_direct_subscription(reader, retained) if job.checkout_mode == 'direct'
                            else _hosted_subscription(reader, retained))
            customer_id = provider_identifier(subscription.get('customer_id'), 192)
            if job.customer_id and job.customer_id != customer_id:
                raise CheckoutRejected('Recovered cancellation customer conflicts with retained ownership.')
            _checkpoint(job, subscription_id=provider_identifier(subscription.get('id')), customer_id=customer_id)
        else:
            subscription = reader.retrieve_subscription(job.subscription_id)
        _verify_subscription_owner(subscription, job, recovered=recovered)
        canceled, outcome = _cancellation_proof(subscription)
        if outcome is None:
            # No automatic retry and no invented idempotency parameter. After
            # an uncertain POST the next job attempt first reads canonical state.
            client.cancel_subscription(job.subscription_id)
            subscription = reader.retrieve_subscription(job.subscription_id)
            _verify_subscription_owner(subscription, job, recovered=recovered)
            canceled, outcome = _cancellation_proof(subscription)
            if outcome is None:
                raise SquareClientError('Provider cancellation is not canonically verified yet.')
        proof = {key: subscription.get(key) for key in ('id', 'version', 'status', 'canceled_date',
                                                       'location_id', 'plan_variation_id')}
        _checkpoint(job, state='verified', verified_at=timezone.now(), canceled_date=canceled,
            canonical_sha256=fingerprint(proof), outcome_code=outcome, customer_id='', card_id='',
            payment_link_id='', order_template_id='', processing_lease=None, lease_until=None,
            next_attempt_at=None)
        return 'verified'
    except Exception:
        try:
            _checkpoint(job, state='retry', outcome_code='cancellation_retry_required',
                next_attempt_at=timezone.now() + timedelta(seconds=min(3600, 15 * 2 ** min(job.attempts, 8))),
                processing_lease=None, lease_until=None)
        except (CheckoutRejected, SquareCancellationOutbox.DoesNotExist):
            pass
        return 'retry'
