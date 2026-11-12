"""Canonical Sandbox evidence processing, with explicit unproven coverage.

No webhook event, customer email, ACTIVE status, mutable due date or latest
charged_through_date is an entitlement grant. Canonical I/O occurs outside row
locks; short leased commits reject stale owners and conflicting versions.
"""
from dataclasses import dataclass
from datetime import date, timedelta
from uuid import uuid4
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from django.views.decorators.debug import sensitive_variables

from .checkout import (CheckoutBusy, CheckoutRejected, acquire_intent, checkpoint, fingerprint,
                       release_intent, subscription_facts, validate_subscription, verify_provider_terms)
from .client import SquareClientError
from .configuration import (checkout_configuration, configured_client, provider_identifier,
                            assert_client_environment, environment_prefix, payment_environment)
from .models import (ParentContentEntitlement, SquareBillingTerm, SquareCheckoutIntent,
                     SquareInvoiceEvidence, SquareWebhookReceipt)


MAX_INVOICES_PER_RUN = 2
MAX_CANONICAL_CALLS = 40
SUPPORTED_EVENTS = {'subscription.created', 'subscription.updated', 'invoice.created', 'invoice.published',
                    'invoice.updated', 'invoice.payment_made', 'invoice.scheduled_charge_failed',
                    'invoice.canceled', 'invoice.refunded', 'payment.created', 'payment.updated',
                    'refund.created', 'refund.updated'}


@dataclass(frozen=True)
class CoverageResolution:
    state: str
    reason: str
    valid_from: object = None
    valid_until: object = None


def resolve_invoice_coverage(*, invoice_facts, subscription_facts):
    """Explicit adapter awaiting an immutable invoice-to-contract-term mapping.

    Square auto-generated invoices expose no documented service-period pair.
    due_date/created_at/array position/latest charged_through_date cannot prove
    which cycle an old late-paid invoice covers. Do not replace this with a
    calendar guess. A reviewed app-owned immutable term binding may extend this
    adapter later; it is deliberately not fabricated in the current gateway.
    """
    return CoverageResolution('review_required', 'invoice_coverage_unproven')


def invoice_source_reference(invoice_id):
    # Provider invoice IDs can exceed entitlement source_reference's192 limit.
    return 'square-invoice:' + fingerprint({'invoice_id': invoice_id})


class CanonicalReader:
    def __init__(self, client, deadline):
        self.client, self.deadline, self.calls = client, deadline, 0

    def __getattr__(self, name):
        if not name.startswith(('retrieve_', 'search_', 'list_')):
            raise AttributeError(name)
        def call(*args, **kwargs):
            if self.calls >= MAX_CANONICAL_CALLS or timezone.now() >= self.deadline:
                raise SquareClientError('Canonical reconciliation resource budget was exhausted.')
            self.calls += 1
            return getattr(self.client, name)(*args, **kwargs)
        return call


def _money(value):
    if (not isinstance(value, dict) or type(value.get('amount')) is not int
            or value['amount'] < 0 or value.get('currency') != 'USD'):
        raise CheckoutRejected('Canonical money is invalid or outside the confirmed currency.')
    return value['amount']


def _timestamp(value):
    if not isinstance(value, str):
        raise CheckoutRejected('Canonical update time is missing.')
    parsed = parse_datetime(value)
    if parsed is None or timezone.is_naive(parsed):
        raise CheckoutRejected('Canonical update time is invalid.')
    return parsed


def _invoice_identity(invoice):
    return {key: invoice.get(key) for key in ('id', 'version', 'location_id', 'subscription_id',
             'order_id', 'status', 'updated_at', 'created_at', 'timezone', 'payment_requests')}


def _payment_identity(payment):
    return {key: payment.get(key) for key in ('id', 'order_id', 'location_id', 'reference_id', 'customer_id', 'updated_at',
            'version_token', 'status', 'source_type', 'amount_money', 'total_money',
            'tip_money', 'refunded_money', 'refund_ids')}


def _payment_snapshot(payment, reader, order_id, location_id):
    payment_id = provider_identifier(payment.get('id'), 192)
    if payment.get('order_id') != order_id or payment.get('location_id') != location_id:
        raise CheckoutRejected('Canonical payment is not part of this invoice charge order.')
    _timestamp(payment.get('updated_at'))
    if (payment.get('status') not in {'APPROVED', 'PENDING', 'COMPLETED', 'CANCELED', 'FAILED'}
            or payment.get('source_type') not in {'CARD', 'BANK_ACCOUNT', 'WALLET', 'CASH', 'EXTERNAL', 'SQUARE_ACCOUNT', 'BUY_NOW_PAY_LATER'}):
        raise CheckoutRejected('Unknown canonical payment state requires review.')
    if payment.get('version_token') is not None:
        provider_identifier(payment['version_token'], 192)
    amount = _money(payment.get('amount_money'))
    if payment.get('total_money') is not None and _money(payment['total_money']) != amount:
        raise CheckoutRejected('Unexpected payment additions or adjustments require review.')
    if payment.get('tip_money') is not None and _money(payment['tip_money']) != 0:
        raise CheckoutRejected('Unexpected payment tip requires review.')
    refund_ids = payment.get('refund_ids', [])
    if (not isinstance(refund_ids, list) or len(refund_ids) > 8
            or any(not isinstance(identifier, str) for identifier in refund_ids)
            or len(set(refund_ids)) != len(refund_ids)):
        raise CheckoutRejected('Canonical refund list requires review.')
    refunds, refunded = [], 0
    for refund_id in refund_ids:
        provider_identifier(refund_id, 192)
        refund = reader.retrieve_refund(refund_id)
        if (refund.get('id') != refund_id or refund.get('payment_id') != payment_id
                or refund.get('location_id') != location_id):
            raise CheckoutRejected('Canonical refund does not belong to this payment.')
        _timestamp(refund.get('updated_at'))
        if refund.get('status') not in {'PENDING', 'COMPLETED', 'REJECTED', 'FAILED'}:
            raise CheckoutRejected('Unknown canonical refund state requires review.')
        refund_amount = _money(refund.get('amount_money'))
        if refund.get('status') == 'COMPLETED':
            refunded += refund_amount
        refunds.append({'id': refund_id, 'status': refund.get('status'), 'amount_minor': refund_amount,
                        'updated_at': refund['updated_at']})
    reported_refund = _money(payment.get('refunded_money', {'amount': 0, 'currency': 'USD'}))
    if reported_refund != refunded or refunded > amount:
        raise CheckoutRejected('Refund observations are incomplete or inconsistent; retry canonical reads.')
    return {'id': payment_id, 'status': payment.get('status'), 'source_type': payment.get('source_type'),
            'amount_minor': amount, 'refunded_minor': refunded, 'updated_at': payment['updated_at'],
            'provider_version': payment.get('version_token'),
            'payment_canonical_sha256': fingerprint(_payment_identity(payment)), 'refunds': refunds}


@sensitive_variables()
def collect_invoice(reader, *, invoice_id, subscription, intent):
    invoice = reader.retrieve_invoice(invoice_id)
    if (invoice.get('id') != invoice_id or invoice.get('subscription_id') != subscription['id'] or invoice.get('location_id') != intent.location_id
            or type(invoice.get('version')) is not int or invoice['version'] < 0):
        raise CheckoutRejected('Canonical invoice is not part of the bound subscription.')
    provider_identifier(invoice.get('order_id'), 192)
    _timestamp(invoice.get('updated_at'))
    _timestamp(invoice.get('created_at'))
    if invoice.get('status') not in {'DRAFT', 'UNPAID', 'SCHEDULED', 'PARTIALLY_PAID', 'PAID',
                                   'PARTIALLY_REFUNDED', 'REFUNDED', 'CANCELED', 'FAILED', 'PAYMENT_PENDING'}:
        raise CheckoutRejected('Unknown canonical invoice state requires review.')
    try:
        ZoneInfo(invoice.get('timezone'))
    except (TypeError, ValueError, ZoneInfoNotFoundError):
        raise CheckoutRejected('Unknown canonical invoice timezone requires review.') from None
    requests = invoice.get('payment_requests')
    if (not isinstance(requests, list) or len(requests) != 1 or not isinstance(requests[0], dict)
            or requests[0].get('request_type') != 'BALANCE'
            or _money(requests[0].get('computed_amount_money')) != 999):
        raise CheckoutRejected('Nonstandard invoice payment schedule or amount requires review.')
    try:
        due_date = requests[0].get('due_date')
        if not isinstance(due_date, str) or date.fromisoformat(due_date).isoformat() != due_date:
            raise ValueError
    except (TypeError, ValueError):
        raise CheckoutRejected('Invalid canonical invoice due date requires review.') from None
    order = reader.retrieve_order(invoice['order_id'])
    if order.get('location_id') != intent.location_id or _money(order.get('total_money')) != 999:
        raise CheckoutRejected('Canonical invoice order does not match the confirmed price/location.')
    tenders = order.get('tenders', [])
    if not isinstance(tenders, list) or len(tenders) > 8:
        raise CheckoutRejected('Canonical invoice payment count requires review.')
    payments, payment_ids = [], set()
    for tender in tenders:
        if not isinstance(tender, dict):
            raise CheckoutRejected('Invalid canonical tender.')
        payment_id = provider_identifier(tender.get('payment_id') or tender.get('id'), 192)
        if payment_id in payment_ids:
            raise CheckoutRejected('Duplicate tender cannot be counted twice.')
        payment_ids.add(payment_id)
        payment = reader.retrieve_payment(payment_id)
        payments.append(_payment_snapshot(payment, reader, order['id'], intent.location_id))
    # Re-read identities after child object reads: an invoice/order can change
    # while fetching payment/refund data. No partially assembled snapshot commits.
    again = reader.retrieve_invoice(invoice_id)
    order_again = reader.retrieve_order(order['id'])
    if (fingerprint(_invoice_identity(again)) != fingerprint(_invoice_identity(invoice))
            or fingerprint({k: order_again.get(k) for k in ('id', 'version', 'tenders', 'total_money')})
            != fingerprint({k: order.get(k) for k in ('id', 'version', 'tenders', 'total_money')})):
        raise SquareClientError('Canonical objects changed during reconciliation.')
    for observed in payments:
        latest = reader.retrieve_payment(observed['id'])
        if fingerprint(_payment_identity(latest)) != observed['payment_canonical_sha256']:
            raise SquareClientError('Canonical payment changed during reconciliation.')
        for refund in observed['refunds']:
            latest_refund = reader.retrieve_refund(refund['id'])
            if (latest_refund.get('payment_id') != observed['id']
                    or latest_refund.get('location_id') != intent.location_id
                    or latest_refund.get('status') != refund['status']
                    or latest_refund.get('updated_at') != refund['updated_at']
                    or _money(latest_refund.get('amount_money')) != refund['amount_minor']):
                raise SquareClientError('Canonical refund changed during reconciliation.')
    completed = [payment for payment in payments if payment['status'] == 'COMPLETED'
                 and payment['source_type'] == 'CARD']
    amount = sum(payment['amount_minor'] for payment in completed)
    refunded = sum(payment['refunded_minor'] for payment in completed)
    billing = {'invoice': {key: invoice.get(key) for key in ('created_at', 'updated_at', 'timezone', 'status')},
               'due_date': requests[0].get('due_date'), 'request_type': 'BALANCE',
               'computed_amount_minor': 999}
    outcome = 'payment_pending'
    coverage = CoverageResolution('review_required', 'payment_pending')
    if amount == 999 and refunded == 999:
        outcome = 'payment_fully_refunded'
    elif refunded:
        outcome = 'partial_refund_review'
    elif invoice.get('status') == 'PAID' and amount == 999 and len(completed) == len(payments):
        coverage = resolve_invoice_coverage(invoice_facts=billing, subscription_facts=subscription_facts(subscription))
        outcome = coverage.reason
    elif amount > 999 or (invoice.get('status') == 'PAID' and amount != 999):
        outcome = 'payment_amount_review'
    snapshot = {'invoice_id': invoice_id, 'charge_order_id': order['id'], 'invoice_version': invoice['version'],
                'invoice_status': invoice.get('status', ''), 'subscription_version': subscription['version'],
                'payment_evidence': payments, 'billing_facts': billing, 'amount_minor': amount,
                'refunded_minor': refunded, 'currency': 'USD', 'outcome_code': outcome}
    snapshot['canonical_sha256'] = fingerprint(snapshot)
    # Coverage is currently deliberately unproven. Never populate dates from a
    # patched/client-supplied resolver result without the separate grant writer.
    if coverage.state != 'review_required' or coverage.valid_from is not None or coverage.valid_until is not None:
        raise CheckoutRejected('A verified coverage writer has not been qualified for this integration.')
    return snapshot


def _not_older_payments(new, old):
    latest = {p['id']: p for p in new}
    for previous in old:
        current = latest.get(previous['id'])
        if current is None or _timestamp(current['updated_at']) < _timestamp(previous['updated_at']):
            return False
        if (_timestamp(current['updated_at']) == _timestamp(previous['updated_at'])
                and current.get('payment_canonical_sha256') != previous.get('payment_canonical_sha256')):
            return False
        if previous['status'] == 'COMPLETED' and current['status'] != 'COMPLETED':
            return False
        old_refunds = {r['id']: r for r in previous.get('refunds', [])}
        new_refunds = {r['id']: r for r in current.get('refunds', [])}
        for identifier, refund in old_refunds.items():
            if identifier not in new_refunds or _timestamp(new_refunds[identifier]['updated_at']) < _timestamp(refund['updated_at']):
                return False
            if (_timestamp(new_refunds[identifier]['updated_at']) == _timestamp(refund['updated_at'])
                    and new_refunds[identifier] != refund):
                return False
            if refund['status'] == 'COMPLETED' and new_refunds[identifier]['status'] != 'COMPLETED':
                return False
    return True


def _hosted_subscription(reader, intent):
    candidates, cursor, seen = [], None, set()
    for _page in range(3):
        response = reader.search_subscriptions(location_id=intent.location_id, cursor=cursor)
        subscriptions = response.get('subscriptions', [])
        if not isinstance(subscriptions, list) or len(subscriptions) > 100:
            raise CheckoutRejected('Invalid canonical subscription page.')
        for item in subscriptions:
            if not isinstance(item, dict):
                raise CheckoutRejected('Invalid canonical subscription.')
            phases = item.get('phases', [])
            if isinstance(phases, list) and any(isinstance(phase, dict)
                    and phase.get('order_template_id') == intent.order_template_id for phase in phases):
                if item.get('id') not in {candidate.get('id') for candidate in candidates}:
                    candidates.append(item)
        cursor = response.get('cursor')
        if not cursor:
            break
        if not isinstance(cursor, str) or len(cursor) > 4096 or cursor in seen:
            raise CheckoutRejected('Invalid canonical subscription pagination.')
        seen.add(cursor)
    else:
        raise CheckoutRejected('Subscription search budget exhausted; exact uniqueness is unproven.')
    if len(candidates) != 1:
        raise CheckoutRejected('Exact checkout-template subscription match is missing or ambiguous.')
    return reader.retrieve_subscription(candidates[0]['id'])


def _direct_subscription(reader, intent):
    """Recover an uncertain response without repeating a financial mutation.

    This is not arbitrary customer discovery: the customer was created only
    for this server intent, its immutable reference is our UUID, and the stored
    card must canonically belong to it. Shared/reused/customer-supplied IDs are
    not accepted. Multiple subscriptions are quarantined, not auto-refunded.
    """
    if not intent.customer_id or not intent.card_id:
        raise CheckoutRejected('Direct customer/card identity is not established yet.')
    customer = reader.retrieve_customer(intent.customer_id)
    card = reader.retrieve_card(intent.card_id)
    if customer.get('reference_id') != str(intent.pk) or card.get('customer_id') != intent.customer_id:
        raise CheckoutRejected('The dedicated direct customer/card ownership is unproven.')
    candidates, cursor, seen = {}, None, set()
    for _page in range(3):
        response = reader.search_subscriptions(location_id=intent.location_id,
            customer_id=intent.customer_id, cursor=cursor)
        rows = response.get('subscriptions', [])
        if not isinstance(rows, list) or len(rows) > 100:
            raise CheckoutRejected('Invalid canonical subscription page.')
        for row in rows:
            if not isinstance(row, dict) or row.get('customer_id') != intent.customer_id:
                raise CheckoutRejected('Canonical subscription ownership is inconsistent.')
            candidates[provider_identifier(row.get('id'))] = row
        cursor = response.get('cursor')
        if not cursor:
            break
        if not isinstance(cursor, str) or len(cursor) > 4096 or cursor in seen:
            raise CheckoutRejected('Invalid canonical subscription pagination.')
        seen.add(cursor)
    else:
        raise CheckoutRejected('Direct subscription uniqueness is unproven within the read budget.')
    if len(candidates) != 1:
        raise CheckoutRejected('A unique direct subscription is missing or duplicated.')
    candidate_id = next(iter(candidates))
    if intent.subscription_id and candidate_id != intent.subscription_id:
        raise CheckoutRejected('The canonical direct subscription changed identity.')
    return reader.retrieve_subscription(candidate_id)


@sensitive_variables()
def reconcile_intent(*, parent, intent_id, client=None, invoice_id=None):
    checkout_configuration(reconciliation=True)
    client = client or configured_client()
    intent, _ = acquire_intent(parent=parent, intent_id=intent_id, reconciliation=True)
    reader = CanonicalReader(client, intent.lease_until)
    try:
        verify_provider_terms(reader, intent)
        if intent.checkout_mode == 'direct':
            subscription = _direct_subscription(reader, intent)
        else:
            if not intent.order_template_id:
                raise CheckoutRejected('The hosted checkout template is not durably bound.')
            subscription = _hosted_subscription(reader, intent)
        facts = validate_subscription(subscription, intent, direct=intent.checkout_mode == 'direct')
        ids = subscription.get('invoice_ids', [])
        if not isinstance(ids, list) or len(ids) > 2000 or any(not isinstance(value, str) for value in ids):
            raise CheckoutRejected('Canonical invoice history requires review.')
        ids = list(dict.fromkeys(ids))
        if invoice_id is not None and invoice_id not in ids:
            raise CheckoutRejected('The target invoice does not belong to this subscription.')
        if invoice_id is not None:
            selected = [invoice_id]
        else:
            known = set(intent.invoice_evidence.values_list('invoice_id', flat=True))
            unseen = [identifier for identifier in ids if identifier not in known]
            if unseen:
                selected = unseen[:MAX_INVOICES_PER_RUN]
            else:
                start = (ids.index(intent.reconciliation_invoice_cursor) + 1) if intent.reconciliation_invoice_cursor in ids else 0
                rotated = ids[start:] + ids[:start]
                selected = rotated[:MAX_INVOICES_PER_RUN]
        snapshots = [collect_invoice(reader, invoice_id=identifier, subscription=subscription, intent=intent)
                     for identifier in selected]
        final_subscription = reader.retrieve_subscription(subscription['id'])
        if fingerprint(subscription_facts(final_subscription)) != fingerprint(facts):
            raise SquareClientError('Canonical subscription changed during reconciliation.')
        with transaction.atomic():
            locked_parent = type(parent).objects.select_for_update().get(pk=parent.pk)
            current = SquareCheckoutIntent.objects.select_for_update().get(pk=intent.pk, parent=locked_parent, environment='sandbox')
            if (not locked_parent.is_active or not locked_parent.email_verified_at
                    or current.processing_lease != intent.processing_lease or not current.lease_until
                    or current.lease_until <= timezone.now()):
                raise CheckoutBusy('The reconciliation owner is no longer current.')
            digest = fingerprint(facts)
            if (subscription['version'] < current.subscription_version
                    or (subscription['version'] == current.subscription_version and current.subscription_sha256
                        and digest != current.subscription_sha256)):
                raise CheckoutRejected('A conflicting or older canonical subscription was rejected.')
            # Validate every row before applying any observations or revocations.
            old_rows = {row.invoice_id: row for row in SquareInvoiceEvidence.objects.select_for_update().filter(
                environment='sandbox', intent__environment='sandbox', merchant_id=intent.merchant_id,
                invoice_id__in=[s['invoice_id'] for s in snapshots])}
            for snapshot in snapshots:
                old = old_rows.get(snapshot['invoice_id'])
                if old and (old.intent_id != current.pk or old.charge_order_id != snapshot['charge_order_id']
                        or snapshot['invoice_version'] < old.invoice_version
                        or not _not_older_payments(snapshot['payment_evidence'], old.payment_evidence)
                        or (snapshot['invoice_version'] == old.invoice_version and old.billing_facts != snapshot['billing_facts'])):
                    raise CheckoutRejected('An older, conflicting or cross-parent invoice proof was rejected.')
            for snapshot in snapshots:
                old = old_rows.get(snapshot['invoice_id'])
                revoked_at = old.revoked_at if old else None
                if snapshot['outcome_code'] == 'payment_fully_refunded':
                    revoked_at = revoked_at or timezone.now()
                if revoked_at:
                    snapshot['outcome_code'] = 'payment_fully_refunded'
                SquareInvoiceEvidence.objects.update_or_create(environment='sandbox', merchant_id=current.merchant_id,
                    invoice_id=snapshot['invoice_id'], defaults={
                        **{k: v for k, v in snapshot.items() if k != 'invoice_id'}, 'intent': current,
                        'observed_at': timezone.now(), 'revoked_at': revoked_at})
                if revoked_at:
                    # Revoke only this exact proof, never all parent periods.
                    ParentContentEntitlement.objects.filter(parent=locked_parent, provider='square',
                        environment='sandbox', provider_account_id=current.merchant_id,
                        source_reference=invoice_source_reference(snapshot['invoice_id']),
                        revoked_at__isnull=True).update(revoked_at=revoked_at)
            current.subscription_id, current.customer_id = subscription['id'], subscription['customer_id']
            current.subscription_version, current.subscription_sha256 = subscription['version'], digest
            current.provider_status = subscription.get('status', '')
            current.state, current.outcome_code = 'review_required', (
                snapshots[0]['outcome_code'] if snapshots else 'invoice_payment_pending')
            current.processing_lease, current.lease_until = None, None
            if selected and invoice_id is None:
                current.reconciliation_invoice_cursor = selected[-1]
            current.save()
        return 'review_required'
    except Exception as error:
        release_intent(intent, state='review_required', outcome_code='canonical_review_required')
        if isinstance(error, (SquareClientError, CheckoutRejected)):
            raise
        raise SquareClientError('Canonical Square evidence is unavailable or inconsistent.') from None


def _event_target(reader, receipt):
    """Only canonical object IDs; no webhook parent/customer ownership claims."""
    if receipt.event_type.startswith('subscription.'):
        return receipt.object_id, None
    if receipt.event_type.startswith('invoice.'):
        invoice = reader.retrieve_invoice(receipt.object_id)
        return provider_identifier(invoice.get('subscription_id')), invoice.get('id')
    if receipt.event_type.startswith('refund.'):
        refund = reader.retrieve_refund(receipt.object_id)
        payment = reader.retrieve_payment(provider_identifier(refund.get('payment_id'), 192))
    else:
        payment = reader.retrieve_payment(receipt.object_id)
    order_id = provider_identifier(payment.get('order_id'), 192)
    proof = SquareInvoiceEvidence.objects.filter(environment=receipt.environment, intent__environment=receipt.environment,
                                               merchant_id=receipt.merchant_id,
                                               charge_order_id=order_id).select_related('intent').first()
    if proof is None:
        raise CheckoutRejected('Invoice binding is not available yet; retry after subscription/invoice receipt.')
    return proof.intent.subscription_id, proof.invoice_id


@sensitive_variables()
def process_receipt(*, receipt_id, client=None, environment='sandbox'):
    from django.conf import settings
    payment_environment(environment)
    if getattr(settings, environment_prefix(environment) + '_TERM_RECONCILIATION_ENABLED', False):
        from .terms import term_configuration
        config = term_configuration(readonly=True, environment=environment)
    else:
        config = checkout_configuration(reconciliation=True, environment=environment)
    client = client or configured_client(environment=environment)
    assert_client_environment(client, environment=environment)
    now, lease = timezone.now(), uuid4()
    with transaction.atomic():
        receipt = SquareWebhookReceipt.objects.select_for_update().get(pk=receipt_id,
            environment=environment, merchant_id=config.provider.merchant_id)
        if receipt.processing_state in {'processed', 'ignored'}:
            return receipt.processing_state
        if receipt.processing_lease and receipt.lease_until and receipt.lease_until > now:
            return 'busy'
        if receipt.next_attempt_at and receipt.next_attempt_at > now:
            return 'retry'
        receipt.processing_lease, receipt.lease_until = lease, now + timedelta(minutes=10)
        receipt.processing_state, receipt.processing_attempts = 'processing', receipt.processing_attempts + 1
        receipt.save()
    state, code = 'retry', 'canonical_retry_required'
    try:
        if receipt.event_type not in SUPPORTED_EVENTS or not receipt.object_id:
            state, code = 'ignored', 'unsupported_event'
        else:
            reader = CanonicalReader(client, receipt.lease_until)
            # App-owned terms have an exact documented Payment.reference_id.
            # Fetch canonical payment first; the signed body never grants.
            if receipt.event_type.startswith(('payment.', 'refund.')):
                if receipt.event_type.startswith('refund.'):
                    refund = reader.retrieve_refund(receipt.object_id)
                    payment = reader.retrieve_payment(provider_identifier(refund.get('payment_id'), 192))
                else:
                    payment = reader.retrieve_payment(receipt.object_id)
                try: term_id = UUID(payment.get('reference_id', ''))
                except (ValueError, TypeError, AttributeError): term_id = None
                term = SquareBillingTerm.objects.filter(pk=term_id,
                    environment=environment, agreement__environment=environment,
                    agreement__merchant_id=receipt.merchant_id).first() if term_id else None
                if term:
                    from .terms import reconcile_term
                    reconcile_term(term_id=term.pk, payment_id=payment['id'], client=client, environment=environment)
                    state, code = 'processed', 'exact_term_payment_recorded'
                    return state
            if environment != 'sandbox':
                # Historical autonomous subscriptions are never production adapters.
                state, code = 'ignored', 'no_owned_environment_term'
                return state
            subscription_id, invoice_id = _event_target(reader, receipt)
            subscription = reader.retrieve_subscription(subscription_id)
            intent = SquareCheckoutIntent.objects.filter(environment='sandbox', merchant_id=receipt.merchant_id,
                subscription_id=subscription_id).select_related('parent').first()
            if intent is None:
                # Lost direct POST responses can be recovered only through the
                # server-created unique customer/card pair; the next stage
                # rechecks its exact customer.reference_id and canonical card.
                intent = SquareCheckoutIntent.objects.filter(environment='sandbox', merchant_id=receipt.merchant_id,
                    checkout_mode='direct', customer_id=subscription.get('customer_id'),
                    card_id=subscription.get('card_id')).exclude(customer_id='').exclude(card_id='').select_related('parent').first()
            if intent is None:
                phases = subscription.get('phases', [])
                templates = [phase.get('order_template_id') for phase in phases if isinstance(phase, dict)] if isinstance(phases, list) else []
                matches = list(SquareCheckoutIntent.objects.filter(environment='sandbox', merchant_id=receipt.merchant_id,
                    checkout_mode='hosted', order_template_id__in=[t for t in templates if t]).select_related('parent')[:2])
                if len(matches) != 1:
                    raise CheckoutRejected('No unique server-owned checkout intent exists for this subscription.')
                intent = matches[0]
            reconcile_intent(parent=intent.parent, intent_id=intent.pk, client=client, invoice_id=invoice_id)
            state, code = 'processed', 'canonical_observation_recorded'
    except Exception:
        # No raw error/body or user-provided identifier reaches logs/rows.
        pass
    finally:
        with transaction.atomic():
            current = SquareWebhookReceipt.objects.select_for_update().get(pk=receipt_id, environment=environment)
            if current.processing_lease == lease:
                current.processing_state, current.outcome_code = state, code
                current.processing_lease, current.lease_until = None, None
                current.processed_at = timezone.now() if state in {'processed', 'ignored'} else None
                current.next_attempt_at = (timezone.now() + timedelta(seconds=min(3600, 15 * 2 ** min(current.processing_attempts, 8)))) if state == 'retry' else None
                current.save()
    return state
