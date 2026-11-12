"""Operational tests: isolated test DB, synthetic identities and fake I/O only."""
from contextlib import contextmanager
from datetime import timedelta
from io import StringIO
import json
from types import SimpleNamespace
from unittest.mock import Mock, patch
from uuid import UUID, uuid4

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone

from apps.accounts.models import User
from . import jobs
from .configuration import SquareDisabled
from .job_models import SquareBillingJobState
from .models import ParentContentEntitlement, SquareBillingTerm, SquareContentAgreement, SquareWebhookReceipt
from .term_plans import content_term_plan
from .test_checkout import CHECKOUT_CONFIG, make_parent
from .test_modern_web import modern_fixture


@contextmanager
def available_lock(*_args):
    yield True


@contextmanager
def busy_lock(*_args):
    yield False


def config(environment='sandbox', merchant='private-test-merchant'):
    return SimpleNamespace(provider=SimpleNamespace(environment=environment, merchant_id=merchant))


class JobNoDatabaseTests(SimpleTestCase):
    def setUp(self):
        jobs._stop_requested = False

    def test_dry_run_has_no_database_provider_or_checkpoint_access(self):
        out = StringIO()
        with patch('apps.billing.management.commands.run_square_billing_jobs.run_jobs') as run:
            call_command('run_square_billing_jobs', environment='production', stage='renew', stdout=out)
        run.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['database_writes'], 0)

    @override_settings(SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED=False)
    def test_disabled_stage_rejects_before_configuration_or_database(self):
        with patch.object(jobs, 'term_configuration') as configure:
            with self.assertRaises(SquareDisabled):
                jobs.run_jobs(environment='production', stage='renew')
        configure.assert_not_called()

    @override_settings(SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED=True, SQUARE_PRODUCTION_RENEWALS_ENABLED=False)
    def test_job_flag_cannot_bypass_production_final_renewal_opt_in(self):
        with patch.object(jobs, 'term_configuration') as configure:
            with self.assertRaises(SquareDisabled):
                jobs.run_jobs(environment='production', stage='renew')
        configure.assert_not_called()

    @override_settings(SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED=True)
    def test_provider_environment_mismatch_fails_before_database_or_lock(self):
        with patch.object(jobs, 'term_configuration', return_value=config('sandbox')):
            with self.assertRaises(jobs.JobUnavailable):
                jobs.run_jobs(environment='production', stage='reconcile')

    def test_read_client_cannot_charge_store_card_refund_or_cancel(self):
        client = jobs._BudgetedClient(environment='production', charge=False,
            max_calls=5, max_seconds=120, monotonic=lambda: 0)
        for operation in ('create_term_payment', 'create_card', 'disable_card', 'refund_payment', 'cancel_subscription'):
            with self.subTest(operation=operation), self.assertRaises(jobs.JobUnavailable):
                getattr(client, operation)

    def test_provider_call_time_and_signal_budgets_stop_without_retry(self):
        fake = Mock(environment='production')
        factory = Mock(return_value=fake)
        clock = [0]
        client = jobs._BudgetedClient(environment='production', charge=False, max_calls=1,
            max_seconds=10, monotonic=lambda: clock[0], factory=factory)
        client.retrieve_payment('private-payment')
        with self.assertRaises(jobs.JobBudgetExhausted):
            client.retrieve_payment('private-payment')
        fake.retrieve_payment.assert_called_once()
        factory.assert_called_once_with(environment='production')
        def delayed_factory(**_kwargs):
            clock[0] = 10
            return fake
        client = jobs._BudgetedClient(environment='production', charge=False, max_calls=5,
            max_seconds=10, monotonic=lambda: clock[0], factory=delayed_factory)
        with self.assertRaises(jobs.JobBudgetExhausted):
            client.retrieve_payment('private-payment')
        fake.retrieve_payment.assert_called_once()
        clock[0] = 0
        jobs.request_stop()
        with self.assertRaises(jobs.JobBudgetExhausted):
            client.retrieve_payment('private-payment')

    def test_bound_client_cannot_mask_a_wrong_environment_delegate(self):
        fake = Mock(environment='sandbox')
        client = jobs._BudgetedClient(environment='production', charge=False, max_calls=5,
            max_seconds=120, monotonic=lambda: 0, factory=lambda **_kwargs: fake)
        for _ in range(2):
            with self.assertRaises(jobs.JobUnavailable):
                client.retrieve_payment('private-payment')
        fake.retrieve_payment.assert_not_called()

    def test_callable_read_prefix_cannot_allow_a_future_mutation(self):
        fake = Mock(environment='production')
        factory = Mock(return_value=fake)
        client = jobs._BudgetedClient(environment='production', charge=False, max_calls=5,
            max_seconds=120, monotonic=lambda: 0, factory=factory)
        for name in ('retrieve_and_charge', 'list_and_refund', 'search_and_cancel'):
            with self.subTest(name=name), self.assertRaises(jobs.JobUnavailable):
                getattr(client, name)()
            getattr(fake, name).assert_not_called()
        factory.assert_not_called()

    def test_postgresql_lock_uses_dedicated_session_and_unlocks_on_failure(self):
        cursor = Mock()
        cursor.fetchone.return_value = (True,)
        lock_connection = Mock()
        lock_connection.cursor.return_value.__enter__ = Mock(return_value=cursor)
        lock_connection.cursor.return_value.__exit__ = Mock(return_value=False)
        connection_context = Mock()
        connection_context.__enter__ = Mock(return_value=lock_connection)
        connection_context.__exit__ = Mock(return_value=False)
        database = SimpleNamespace(vendor='postgresql', get_connection_params=lambda: {'dbname': 'isolated'})
        with patch.object(jobs, 'connections', {'default': database}), patch(
                'psycopg.connect', return_value=connection_context) as connect:
            with self.assertRaises(RuntimeError):
                with jobs.billing_job_lock('production', 'private-test-merchant') as acquired:
                    self.assertTrue(acquired)
                    raise RuntimeError('private-detail-never-logged')
        connect.assert_called_once_with(dbname='isolated', autocommit=True)
        self.assertIn('pg_try_advisory_lock', cursor.execute.call_args_list[0].args[0])
        self.assertIn('pg_advisory_unlock', cursor.execute.call_args_list[-1].args[0])


@override_settings(SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED=True,
    SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED=True, SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED=True,
    SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED=True, SQUARE_PRODUCTION_RENEWALS_ENABLED=True,
    SQUARE_SANDBOX_TEST_PARENT_IDS='')
class JobOrchestrationTests(TestCase):
    def setUp(self):
        jobs._stop_requested = False

    def run_tick(self, *, environment='sandbox', stage='reconcile', **kwargs):
        with patch.object(jobs, 'term_configuration', return_value=config(environment)):
            return jobs.run_jobs(environment=environment, stage=stage, lock_factory=available_lock, **kwargs)

    def receipt(self, **changes):
        values = dict(environment='sandbox', merchant_id='private-test-merchant', event_id=str(uuid4()),
            event_type='payment.updated', object_id='private-provider-object', body_sha256='1'*64)
        values.update(changes)
        return SquareWebhookReceipt.objects.create(**values)

    def agreement(self, *, environment='sandbox', identifier=None):
        parent = User.objects.create(email=f'{uuid4()}@example.test', email_verified_at=timezone.now())
        plan = content_term_plan()
        return SquareContentAgreement.objects.create(id=identifier or uuid4(), environment=environment,
            parent=parent, intent_reference=uuid4(), merchant_id='private-test-merchant', location_id='private-location',
            customer_id='private-customer', card_id='private-card', policy_id=plan.policy_id,
            policy_sha256=plan.policy_sha256, disclosure_version=plan.disclosure_version,
            disclosure_sha256='2'*64, billing_timezone='America/New_York', consented_at=timezone.now(),
            next_term_start=timezone.now()-timedelta(minutes=1), activated_at=timezone.now())

    def term(self, *, environment='sandbox', identifier=None, state='paid', dispatched=True):
        agreement = self.agreement(environment=environment)
        return SquareBillingTerm.objects.create(id=identifier or uuid4(), agreement=agreement, environment=environment,
            customer_id=agreement.customer_id, card_id=agreement.card_id, location_id=agreement.location_id,
            amount_minor=999, currency='USD', cadence='DAYS_30', coverage_rule='elapsed_days_30',
            request_not_before=agreement.next_term_start, request_sha256='3'*64, state=state,
            dispatched_at=timezone.now() if dispatched else None, dispatch_attempts=1 if dispatched else 0)

    def test_lock_contention_is_no_provider_or_checkpoint_operation(self):
        self.receipt()
        with patch.object(jobs, 'term_configuration', return_value=config()), patch.object(
                jobs, 'configured_client') as client:
            report = jobs.run_jobs(environment='sandbox', stage='reconcile', lock_factory=busy_lock)
        self.assertEqual(report['status'], 'lock_busy')
        self.assertEqual(SquareBillingJobState.objects.count(), 0)
        client.assert_not_called()

    def test_receipt_cursor_rotates_past_failures_and_wraps_without_starvation(self):
        receipts = [self.receipt() for _ in range(7)]
        seen = []
        def process(*, receipt_id, **_kwargs):
            seen.append(receipt_id)
            if receipt_id == receipts[0].pk:
                raise RuntimeError('private-provider-error')
            return 'processed'
        with patch.object(jobs, 'process_receipt', side_effect=process):
            reports = [self.run_tick(limit=2) for _ in range(4)]
        self.assertEqual(set(seen), {receipt.pk for receipt in receipts})
        self.assertEqual(len(seen), 8)
        self.assertEqual(reports[0]['status'], 'attention')
        checkpoint = SquareBillingJobState.objects.get(lane='receipts')
        self.assertIsNotNone(checkpoint.last_full_scan_at)
        output = json.dumps(reports)
        for secret in ('private-provider-error', 'private-provider-object', 'private-test-merchant'):
            self.assertNotIn(secret, output)

    def test_receipt_environment_merchant_lease_and_backoff_are_isolated(self):
        good = self.receipt()
        self.receipt(environment='production')
        self.receipt(merchant_id='other-private-merchant')
        self.receipt(lease_until=timezone.now()+timedelta(minutes=1))
        self.receipt(next_attempt_at=timezone.now()+timedelta(minutes=1))
        with patch.object(jobs, 'process_receipt', return_value='processed') as process:
            self.run_tick(limit=20)
        self.assertEqual(process.call_count, 1)
        self.assertEqual(process.call_args.kwargs['receipt_id'], good.pk)
        self.assertEqual(process.call_args.kwargs['environment'], 'sandbox')

    def test_canonical_term_uuid_cursor_scans_beyond_first_twenty(self):
        terms = [self.term(identifier=UUID(int=index+1)) for index in range(23)]
        self.term(environment='production')
        seen = []
        def reconcile(*, term_id, environment, **_kwargs):
            self.assertEqual(environment, 'sandbox')
            seen.append(term_id)
            return 'paid'
        with patch.object(jobs, 'reconcile_term', side_effect=reconcile):
            self.run_tick(limit=20)
            self.run_tick(limit=20)
        self.assertEqual(set(seen), {term.pk for term in terms})

    def test_shared_call_budget_stops_and_checkpoints_interrupted_read(self):
        receipt = self.receipt()
        fake = Mock(environment='sandbox')
        def process(*, client, **_kwargs):
            client.retrieve_payment('private-payment')
            try:
                client.retrieve_payment('private-payment')
            except jobs.JobBudgetExhausted:
                # Existing receipt processing deliberately turns I/O errors
                # into retry outcomes; the outer tick must retain its budget.
                return 'retry'
            return 'processed'
        with patch.object(jobs, 'process_receipt', side_effect=process):
            report = self.run_tick(max_calls=1, client_factory=lambda **_kwargs: fake)
        self.assertEqual(report['status'], 'budget_exhausted')
        self.assertEqual(report['provider_calls'], 1)
        self.assertEqual(SquareBillingJobState.objects.get(lane='receipts').cursor, str(receipt.pk))
        fake.retrieve_payment.assert_called_once()

    def test_uncertain_term_is_never_dispatched_by_unattended_renewal(self):
        term = self.term(environment='production', state='uncertain')
        with patch.object(jobs, 'prepare_due_term', return_value=term), patch.object(
                jobs, 'dispatch_term_payment') as dispatch:
            report = self.run_tick(environment='production', stage='renew')
        self.assertEqual(report['status'], 'attention')
        self.assertEqual(report['payment_requests'], 0)
        dispatch.assert_not_called()

    def test_first_renewal_request_is_single_send_then_canonical_review_only(self):
        term = self.term(environment='production', state='reserved', dispatched=False)
        fake = Mock(environment='production')
        sent = []
        def dispatch(*, term_id, client, environment):
            self.assertEqual(environment, 'production')
            SquareBillingTerm.objects.filter(pk=term_id).update(
                dispatch_attempts=1, dispatched_at=timezone.now(), state='uncertain')
            client.create_term_payment(term_id=term_id, idempotency_key=term.provider_idempotency_key,
                buyer_present=False, verification_token=None)
            sent.append(term_id)
            raise RuntimeError('synthetic-lost-response')
        def prepare(**_kwargs):
            return SquareBillingTerm.objects.get(pk=term.pk)
        with patch.object(jobs, 'prepare_due_term', side_effect=prepare), patch.object(
                jobs, 'dispatch_term_payment', side_effect=dispatch):
            first = self.run_tick(environment='production', stage='renew', client_factory=lambda **_kwargs: fake)
            second = self.run_tick(environment='production', stage='renew', client_factory=lambda **_kwargs: fake)
        self.assertEqual(first['payment_requests'], 1)
        self.assertEqual(second['payment_requests'], 0)
        self.assertEqual(sent, [term.pk])
        fake.create_term_payment.assert_called_once()

    def test_final_client_guard_rejects_a_raced_second_authorization_and_new_key(self):
        term = self.term(environment='production', state='processing')
        fake = Mock(environment='production')
        client = jobs._BudgetedClient(environment='production', charge=True, max_calls=5,
            max_seconds=120, monotonic=lambda: 0, factory=lambda **_kwargs: fake)
        arguments = dict(term_id=term.pk, idempotency_key=term.provider_idempotency_key,
            buyer_present=False, verification_token=None)
        SquareBillingTerm.objects.filter(pk=term.pk).update(dispatch_attempts=2)
        with self.assertRaises(jobs.JobUnavailable):
            client.create_term_payment(**arguments)
        SquareBillingTerm.objects.filter(pk=term.pk).update(dispatch_attempts=1)
        with self.assertRaises(jobs.JobUnavailable):
            client.create_term_payment(**{**arguments, 'idempotency_key': uuid4()})
        client.create_term_payment(**arguments)
        with self.assertRaises(jobs.JobUnavailable):
            client.create_term_payment(**arguments)
        fake.create_term_payment.assert_called_once()

    def test_empty_tick_never_constructs_provider_transport(self):
        factory = Mock()
        report = self.run_tick(client_factory=factory)
        factory.assert_not_called()
        self.assertEqual(report['provider_calls'], 0)

    def test_health_is_readonly_numeric_and_stale_missing_state_fails(self):
        with override_settings(SQUARE_SANDBOX_MERCHANT_ID='private-test-merchant'):
            with self.assertRaises(CommandError):
                call_command('billing_jobs_status', environment='sandbox', stage='reconcile', stdout=StringIO())
            self.run_tick()
            out = StringIO()
            call_command('billing_jobs_status', environment='sandbox', stage='reconcile', stdout=out)
        report = json.loads(out.getvalue())
        self.assertEqual(report['status'], 'ok')
        self.assertNotIn('private-test-merchant', out.getvalue())
        self.assertEqual(len(report['lanes']), 2)
        self.assertTrue(all(lane['healthy'] for lane in report['lanes']))
        self.assertEqual(SquareBillingJobState.objects.count(), 2)

    def test_disabled_job_and_stale_heartbeat_fail_health_without_provider(self):
        self.run_tick()
        SquareBillingJobState.objects.update(last_completed_at=timezone.now()-timedelta(hours=1))
        with override_settings(SQUARE_SANDBOX_MERCHANT_ID='private-test-merchant'), patch.object(
                jobs, 'configured_client') as factory:
            with self.assertRaises(CommandError):
                call_command('billing_jobs_status', environment='sandbox', stage='reconcile', stdout=StringIO())
            SquareBillingJobState.objects.update(last_completed_at=timezone.now())
            with override_settings(SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED=False):
                with self.assertRaises(CommandError):
                    call_command('billing_jobs_status', environment='sandbox', stage='reconcile', stdout=StringIO())
        factory.assert_not_called()

    def test_normal_active_tick_preserves_health_after_prior_success_but_not_a_stalled_tick(self):
        self.run_tick()
        SquareBillingJobState.objects.update(outcome='running', heartbeat_at=timezone.now())
        with override_settings(SQUARE_SANDBOX_MERCHANT_ID='private-test-merchant'):
            call_command('billing_jobs_status', environment='sandbox', stage='reconcile', stdout=StringIO())
            SquareBillingJobState.objects.update(heartbeat_at=timezone.now()-timedelta(hours=1))
            with self.assertRaises(CommandError):
                call_command('billing_jobs_status', environment='sandbox', stage='reconcile', stdout=StringIO())


@override_settings(**{**CHECKOUT_CONFIG, 'SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED': True,
    'SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED': True})
class RealCoreJobTests(TestCase):
    """Real core/DB transitions, fake provider only; no transport is constructed."""
    def setUp(self):
        jobs._stop_requested = False
        self.parent = make_parent('operational-tick')

    def tick(self, stage, client):
        return jobs.run_jobs(environment='sandbox', stage=stage, lock_factory=available_lock,
            client_factory=lambda **_kwargs: client)

    def test_lost_renewal_response_recovers_by_term_scan_without_another_post(self):
        _intent, client, initial = modern_fixture(self.parent)
        initial_requests = len(client.modern_requests)
        due = initial.valid_until + timedelta(seconds=1)
        client.timeout_payment = True
        # Time changes only inside this isolated fake-provider test. Coverage
        # fields and original keys are never changed to force a real charge.
        with patch('apps.billing.terms.timezone.now', return_value=due):
            lost = self.tick('renew', client)
        renewal = SquareBillingTerm.objects.exclude(pk=initial.pk).get()
        original_key = renewal.provider_idempotency_key
        self.assertEqual(lost['status'], 'attention')
        self.assertEqual(lost['payment_requests'], 1)
        self.assertEqual((renewal.state, renewal.dispatch_attempts), ('uncertain', 1))
        self.assertEqual(len(client.modern_requests), initial_requests + 1)
        self.assertEqual(ParentContentEntitlement.objects.count(), 1)
        client.timeout_payment = False
        with patch('apps.billing.terms.timezone.now', return_value=due + timedelta(seconds=31)):
            repeated = self.tick('renew', client)
            recovered = self.tick('reconcile', client)
        self.assertEqual(repeated['payment_requests'], 0)
        self.assertEqual(recovered['status'], 'ok')
        self.assertEqual(recovered['payment_requests'], 0)
        self.assertEqual(len(client.modern_requests), initial_requests + 1)
        renewal.refresh_from_db()
        self.assertEqual(renewal.state, 'paid')
        self.assertEqual(renewal.provider_idempotency_key, original_key)
        self.assertEqual(renewal.valid_from, due)
        self.assertEqual(renewal.valid_until - renewal.valid_from, timedelta(days=30))
        self.assertEqual(ParentContentEntitlement.objects.count(), 2)

    def test_signed_inbox_receipt_uses_real_core_reads_without_charge_or_card_setup(self):
        _intent, client, term = modern_fixture(self.parent)
        before = (len(client.modern_requests), len([call for call in client.calls if call[0] == 'store-payment-card']))
        receipt = SquareWebhookReceipt.objects.create(environment='sandbox', merchant_id='merchant-test',
            event_id='synthetic-jobs-payment-event', event_type='payment.updated',
            object_id=term.payment_id, body_sha256='4'*64)
        report = self.tick('reconcile', client)
        receipt.refresh_from_db()
        self.assertEqual(receipt.processing_state, 'processed')
        self.assertEqual(report['status'], 'ok')
        self.assertEqual(report['payment_requests'], 0)
        self.assertEqual(before, (len(client.modern_requests),
            len([call for call in client.calls if call[0] == 'store-payment-card'])))
        self.assertEqual(ParentContentEntitlement.objects.count(), 1)
