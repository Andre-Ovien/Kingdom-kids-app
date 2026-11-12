"""Bounded operational orchestration; financial authority remains in terms.py.

No unattended financial POST replay: only a never-dispatched saved-card term can
send its first request. An interrupted/uncertain operation is canonical-read-only
until an operator resolves it through the existing owned recovery flow.
"""
from contextlib import contextmanager
from hashlib import sha256
import time

from django.conf import settings
from django.db import connections
from django.db.models import Min, Q
from django.db.models.functions import Coalesce
from django.utils import timezone

from .configuration import SquareDisabled, configured_client, sandbox_test_parent_ids
from .job_models import SquareBillingJobState
from .models import SquareBillingTerm, SquareContentAgreement, SquareWebhookReceipt
from .reconciliation import process_receipt
from .term_plans import ACTIVE_POLICY_IDS
from .terms import dispatch_term_payment, prepare_due_term, reconcile_term, term_configuration


class JobBudgetExhausted(Exception):
    pass


class JobUnavailable(Exception):
    pass


_stop_requested = False
READ_OPERATIONS = frozenset({
    'retrieve_merchant', 'retrieve_location', 'retrieve_catalogue_object',
    'retrieve_subscription', 'retrieve_invoice', 'retrieve_order', 'retrieve_payment',
    'retrieve_refund', 'retrieve_card', 'retrieve_customer', 'search_subscriptions',
    'list_cards', 'list_payments',
})


def request_stop(*_args):
    global _stop_requested
    _stop_requested = True


def merchant_digest(merchant_id):
    return sha256(merchant_id.encode('utf-8')).hexdigest()


@contextmanager
def billing_job_lock(environment, merchant_id):
    """Dedicated PostgreSQL session: shared by both stages and all deployments."""
    database = connections['default']
    if database.vendor != 'postgresql':
        raise JobUnavailable('Billing jobs require PostgreSQL.')
    import psycopg
    key = int.from_bytes(sha256(
        ('kingdom-kids/billing-jobs/v1/' + environment + '/' + merchant_id).encode()
    ).digest()[:8], 'big') & ((1 << 63) - 1)
    with psycopg.connect(**database.get_connection_params(), autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute('SELECT pg_try_advisory_lock(%s)', (key,))
            acquired = bool(cursor.fetchone()[0])
            try:
                yield acquired
            finally:
                if acquired:
                    cursor.execute('SELECT pg_advisory_unlock(%s)', (key,))


class _BudgetedClient:
    def __init__(self, *, environment, charge, max_calls, max_seconds, monotonic, factory=None):
        self.environment, self.charge = environment, charge
        self.max_calls, self.deadline = max_calls, monotonic() + max_seconds
        self.monotonic, self.factory = monotonic, factory or configured_client
        self.client, self.calls, self.writes = None, 0, 0
        self.exhausted = False
        self.sent_terms = set()

    def check(self):
        if _stop_requested or self.calls >= self.max_calls or self.monotonic() >= self.deadline:
            self.exhausted = True
            raise JobBudgetExhausted

    def __getattr__(self, name):
        read = name in READ_OPERATIONS
        if not read and not (self.charge and name == 'create_term_payment'):
            raise JobUnavailable('This job cannot perform that provider operation.')

        def invoke(*args, **kwargs):
            self.check()
            if not read:
                # The core increments this counter at final authorization. If
                # another process already sent a request, even a race after our
                # selection must not turn this job into a financial POST retry.
                term = SquareBillingTerm.objects.get(pk=kwargs.get('term_id'), environment=self.environment)
                if (term.pk in self.sent_terms or term.buyer_present
                        or term.payment_source_mode != 'saved_card'
                        or term.dispatch_attempts != 1 or term.dispatched_at is None
                        or term.provider_idempotency_key != kwargs.get('idempotency_key')
                        or kwargs.get('buyer_present') is not False
                        or kwargs.get('verification_token') is not None
                        or kwargs.get('charge_source_id') is not None):
                    raise JobUnavailable('Unattended payment replay requires manual review.')
                self.sent_terms.add(term.pk)
            if self.client is None:
                self.client = self.factory(environment=self.environment)
            if getattr(self.client, 'environment', 'sandbox') != self.environment:
                raise JobUnavailable('The provider client belongs to another environment.')
            operation = getattr(self.client, name)
            # Lazy construction and the final ledger guard can consume time or
            # receive a stop signal. Recheck at the actual dispatch boundary.
            self.check()
            if not read:
                self.writes += 1
            self.calls += 1
            return operation(*args, **kwargs)
        return invoke


def _fair_batch(query, cursor, limit):
    """A durable keyset cursor advances on failed attempts too, then wraps."""
    if not cursor:
        identifiers = list(query.order_by('pk').values_list('pk', flat=True)[:limit + 1])
        complete_scan = len(identifiers) <= limit
        return [(identifier, complete_scan and index == len(identifiers) - 1)
            for index, identifier in enumerate(identifiers[:limit])]
    try:
        after = query.model._meta.pk.to_python(cursor)
    except Exception:
        raise JobUnavailable('The billing job checkpoint requires review.') from None
    identifiers = list(query.filter(pk__gt=after).order_by('pk').values_list('pk', flat=True)[:limit])
    result = [(identifier, False) for identifier in identifiers]
    if len(result) < limit:
        wrapped = query.filter(pk__lte=after).order_by('pk').values_list('pk', flat=True)[:limit - len(result)]
        result += [(identifier, True) for identifier in wrapped]
    return result


def _unleased(now):
    return Q(lease_until__isnull=True) | Q(lease_until__lte=now)


def _retry_due(now):
    return Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=now)


def _receipt_candidates(environment, merchant_id, now):
    return SquareWebhookReceipt.objects.filter(environment=environment, merchant_id=merchant_id).filter(
        Q(processing_state__in=('pending', 'retry')) | Q(processing_state='processing')
    ).filter(_unleased(now), _retry_due(now))


def _term_candidates(environment, merchant_id, now):
    return SquareBillingTerm.objects.filter(environment=environment,
        agreement__environment=environment, agreement__merchant_id=merchant_id).filter(
        Q(dispatched_at__isnull=False) | (Q(payment_id__isnull=False) & ~Q(payment_id=''))
    ).filter(_unleased(now), _retry_due(now))


def _renewal_candidates(environment, merchant_id, now):
    query = SquareContentAgreement.objects.filter(environment=environment, merchant_id=merchant_id,
        policy_id__in=ACTIVE_POLICY_IDS, renewals_enabled=True, activated_at__isnull=False,
        parent__is_active=True, parent__email_verified_at__isnull=False, next_term_start__lte=now)
    if environment == 'sandbox':
        query = query.filter(parent_id__in=sandbox_test_parent_ids())
    return query


def _lane(*, environment, digest, lane, query, limit, operation, client):
    state, _ = SquareBillingJobState.objects.get_or_create(
        environment=environment, merchant_sha256=digest, lane=lane)
    state.started_at = state.heartbeat_at = timezone.now()
    state.outcome, state.counts = 'running', {'attempted': 0, 'completed': 0, 'review': 0, 'retry': 0}
    state.save(update_fields=('started_at', 'heartbeat_at', 'outcome', 'counts'))
    stopped = False
    candidates = _fair_batch(query, state.cursor, limit)
    if not candidates:
        state.last_full_scan_at = timezone.now()
    for identifier, wrapped in candidates:
        try:
            client.check()
        except JobBudgetExhausted:
            stopped = True
            break
        state.counts['attempted'] += 1
        try:
            outcome = operation(identifier)
            if outcome in {'retry', 'busy'}:
                state.counts['retry'] += 1
            elif outcome in {'paid', 'refunded', 'processed', 'ignored'}:
                state.counts['completed'] += 1
            else:
                state.counts['review'] += 1
        except JobBudgetExhausted:
            state.counts['review'] += 1
            stopped = True
        except Exception:
            # No identifiers, raw exception text or provider payload enters logs.
            state.counts['review'] += 1
        stopped = stopped or client.exhausted
        state.cursor, state.heartbeat_at = str(identifier), timezone.now()
        if wrapped:
            state.last_full_scan_at = state.heartbeat_at
        state.save(update_fields=('cursor', 'heartbeat_at', 'last_full_scan_at', 'counts'))
        if stopped:
            break
    state.finished_at = state.heartbeat_at = timezone.now()
    state.outcome = 'budget_exhausted' if stopped else 'attention' if state.counts['review'] else 'ok'
    if not stopped:
        state.last_completed_at = state.finished_at
    state.last_finished_outcome = state.outcome
    state.save(update_fields=('finished_at', 'heartbeat_at', 'outcome', 'last_completed_at', 'last_finished_outcome'))
    return {'lane': lane, 'status': state.outcome, **state.counts}


def backlog(environment, merchant_id, now=None):
    now = now or timezone.now()
    terms = SquareBillingTerm.objects.filter(environment=environment,
        agreement__environment=environment, agreement__merchant_id=merchant_id)
    uncertain = terms.filter(state__in=('uncertain', 'review_required', 'processing', 'payment_pending'))
    oldest = uncertain.aggregate(value=Min(Coalesce('dispatched_at', 'created_at')))['value']
    receipts = SquareWebhookReceipt.objects.filter(environment=environment,
        merchant_id=merchant_id, processing_state__in=('pending', 'retry', 'processing'))
    oldest_receipt = receipts.aggregate(value=Min('received_at'))['value']
    return {'receipts_due': _receipt_candidates(environment, merchant_id, now).count(),
        'receipts_pending': receipts.count(),
        'oldest_receipt_seconds': max(0, int((now - oldest_receipt).total_seconds())) if oldest_receipt else 0,
        'terms_to_scan': _term_candidates(environment, merchant_id, now).count(),
        'uncertain_terms': uncertain.count(),
        'oldest_uncertain_seconds': max(0, int((now - oldest).total_seconds())) if oldest else 0,
        'renewals_due': _renewal_candidates(environment, merchant_id, now).count()}


def run_jobs(*, environment, stage, limit=5, max_calls=80, max_seconds=120, lock_factory=None,
             client_factory=None, monotonic=time.monotonic):
    if environment not in {'sandbox', 'production'} or stage not in {'reconcile', 'renew'}:
        raise ValueError('Choose an exact billing environment and stage.')
    if (type(limit) is not int or not 1 <= limit <= 20 or type(max_calls) is not int
            or not 1 <= max_calls <= 200 or type(max_seconds) is not int or not 1 <= max_seconds <= 600):
        raise ValueError('The billing job budget is invalid.')
    flag = f'SQUARE_{environment.upper()}_{"RECONCILIATION" if stage == "reconcile" else "RENEWAL"}_JOBS_ENABLED'
    if getattr(settings, flag, False) is not True:
        raise SquareDisabled('This billing job stage is disabled.')
    if environment == 'production' and stage == 'renew' and getattr(
            settings, 'SQUARE_PRODUCTION_RENEWALS_ENABLED', False) is not True:
        raise SquareDisabled('Production renewal authorization is disabled.')
    config = term_configuration(environment=environment, readonly=stage == 'reconcile')
    if config.provider.environment != environment:
        raise JobUnavailable('The billing job environment does not match provider configuration.')
    merchant = config.provider.merchant_id
    report = {'environment': environment, 'stage': stage, 'status': 'lock_busy', 'lanes': []}
    with (lock_factory or billing_job_lock)(environment, merchant) as acquired:
        if not acquired:
            return report
        client = _BudgetedClient(environment=environment, charge=stage == 'renew', max_calls=max_calls,
            max_seconds=max_seconds, monotonic=monotonic, factory=client_factory)
        now, digest = timezone.now(), merchant_digest(merchant)
        if stage == 'reconcile':
            report['lanes'].append(_lane(environment=environment, digest=digest, lane='receipts',
                query=_receipt_candidates(environment, merchant, now), limit=limit, client=client,
                operation=lambda identifier: process_receipt(receipt_id=identifier, client=client, environment=environment)))
            report['lanes'].append(_lane(environment=environment, digest=digest, lane='terms',
                query=_term_candidates(environment, merchant, now), limit=limit, client=client,
                operation=lambda identifier: reconcile_term(term_id=identifier, client=client, environment=environment)))
        else:
            def renew(identifier):
                term = prepare_due_term(agreement_id=identifier, environment=environment)
                if (term.buyer_present or term.state != 'reserved' or term.dispatched_at is not None
                        or term.dispatch_attempts != 0 or term.payment_id):
                    return 'review'
                return dispatch_term_payment(term_id=term.pk, client=client, environment=environment)
            report['lanes'].append(_lane(environment=environment, digest=digest, lane='renewals',
                query=_renewal_candidates(environment, merchant, now), limit=limit, client=client, operation=renew))
        report.update(provider_calls=client.calls, payment_requests=client.writes,
            backlog=backlog(environment, merchant))
        report['status'] = ('budget_exhausted' if any(row['status'] == 'budget_exhausted' for row in report['lanes'])
            else 'attention' if any(row['status'] == 'attention' for row in report['lanes']) else 'ok')
    return report
