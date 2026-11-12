"""Shared-staging enrollment boundaries; synthetic isolated DB/provider only."""
from io import StringIO
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from unittest.mock import patch

from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase, SimpleTestCase, TransactionTestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone
from rest_framework.test import APIClient

from .access_status import parent_content_access
from .checkout import CheckoutRejected
from .client import SquareClientError
from .configuration import (SquareConfigurationError, SquareDisabled,
                            sandbox_parent_allowed, sandbox_test_parent_ids)
from .models import ParentContentEntitlement, SquareBillingTerm, SquareCheckoutIntent
from .permissions import verified_paid_coverage_until
from .test_checkout import PASSWORD, make_parent
from .test_checkout_concurrency import isolated
from .test_modern_web import CHARGE_SOURCE, ModernWebFixture, modern_fixture
from .test_parent_checkout_web import WEB
from .test_terms import make_term_intent
from .terms import (activate_payment_card, confirm_term_checkout, dispatch_term_payment,
                    process_due_terms, reconcile_term, reserve_term_checkout,
                    restart_unpaid_checkout, term_disclosure)


class EnrollmentConfigurationTests(SimpleTestCase):
    def test_empty_is_closed_and_only_bounded_positive_parent_ids_are_accepted(self):
        with override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=''):
            self.assertEqual(sandbox_test_parent_ids(), frozenset())
        with override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS='1, 2,1'):
            self.assertEqual(sandbox_test_parent_ids(), frozenset({1, 2}))
        for value in ('*', '0', '-1', '1,', '01', '1.0', '9223372036854775808',
                      ','.join(str(i) for i in range(1, 102)), None):
            with self.subTest(value=value), override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=value):
                with self.assertRaises(SquareConfigurationError):
                    sandbox_test_parent_ids()


@override_settings(**WEB)
class SandboxEnrollmentTests(TestCase):
    base = '/api/billing/square/checkout-intents/'

    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        self.parent, self.other = make_parent('enrolled'), make_parent('unenrolled')
        self.enrollment = self.enterContext(override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=str(self.parent.pk)))

    def test_only_explicit_parent_is_enrolled_and_unlisted_api_cannot_call_provider(self):
        self.assertTrue(sandbox_parent_allowed(self.parent))
        self.assertFalse(sandbox_parent_allowed(self.other))
        client = APIClient(HTTP_HOST='checkout.example.test')
        client.force_authenticate(self.other)
        with patch('apps.billing.views.configured_client', side_effect=AssertionError('Unlisted provider call')):
            self.assertEqual(client.get(self.base).status_code, 404)
            for path in (self.base, self.base+'00000000-0000-0000-0000-000000000001/confirm/',
                         self.base+'00000000-0000-0000-0000-000000000001/prepare-card/',
                         self.base+'00000000-0000-0000-0000-000000000001/restart/'):
                self.assertEqual(client.post(path, {'password': PASSWORD}, format='json').status_code, 404)
        self.assertFalse(SquareCheckoutIntent.objects.exists())
        self.assertEqual(client.get('/api/accounts/me/').status_code, 200)

    def test_routing_is_parent_scoped_sandbox_only_and_unlisted_status_has_no_queries(self):
        allowed = parent_content_access(self.parent)
        self.assertTrue(allowed['parent_plan_routing_enabled'])
        self.assertEqual(allowed['checkout']['state'], 'available')
        with self.assertNumQueries(0):
            denied = parent_content_access(self.other)
        self.assertEqual(denied['access_state'], 'unknown')
        self.assertEqual(denied['reason_code'], 'not_enrolled')
        self.assertIsNone(denied['purchase_recovery'])
        self.assertFalse(denied['parent_plan_routing_enabled'])
        with override_settings(PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='production'):
            production = parent_content_access(self.parent)
        self.assertFalse(production['parent_plan_routing_enabled'])
        self.assertEqual(production['checkout']['state'], 'unavailable')

    def test_service_entry_points_reject_unlisted_before_any_provider_operation(self):
        provider = ModernWebFixture()
        quote = term_disclosure('America/New_York')
        arguments = dict(parent=self.other, password=PASSWORD, accepted=True,
                         disclosure_version=quote['disclosure_version'],
                         disclosure_sha256=quote['disclosure_sha256'], client=provider)
        with self.assertRaises(SquareDisabled):
            reserve_term_checkout(**arguments)
        with self.assertRaises(SquareDisabled):
            restart_unpaid_checkout(intent_id='00000000-0000-0000-0000-000000000001', **arguments)
        with self.assertRaises(SquareDisabled):
            confirm_term_checkout(parent=self.other, intent_id='00000000-0000-0000-0000-000000000001',
                                  password=PASSWORD, charge_source_id=CHARGE_SOURCE, client=provider)
        self.assertEqual(provider.calls, [])
        self.assertEqual(provider.modern_requests, [])

    def test_removal_prevents_final_dispatch_and_empty_worker_does_not_open_transport(self):
        provider = ModernWebFixture()
        intent = make_term_intent(self.parent, provider)
        with patch('apps.billing.terms.dispatch_term_payment', return_value='reserved'):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                                  charge_source_id=CHARGE_SOURCE, client=provider)
        term = SquareBillingTerm.objects.get()
        provider.calls.clear()
        with override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=''):
            with self.assertRaises(CheckoutRejected):
                dispatch_term_payment(term_id=term.pk, charge_source_id=CHARGE_SOURCE, client=provider)
            with patch('apps.billing.terms.configured_client', side_effect=AssertionError('Empty worker transport')):
                self.assertEqual(process_due_terms(), [])
        self.assertEqual(provider.calls, [])
        self.assertEqual(provider.modern_requests, [])

    def test_removed_parent_canonical_read_records_payment_without_grant_or_setup(self):
        provider = ModernWebFixture(); provider.timeout_payment = True
        intent = make_term_intent(self.parent, provider)
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                                  charge_source_id=CHARGE_SOURCE, client=provider)
        term = SquareBillingTerm.objects.get()
        with override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=''):
            self.assertEqual(reconcile_term(term_id=term.pk, client=provider), 'paid')
            provider.calls.clear()
            with self.assertRaises(CheckoutRejected):
                activate_payment_card(term_id=term.pk, client=provider)
            self.assertEqual(provider.calls, [])
        self.assertFalse(ParentContentEntitlement.objects.exists())
        self.assertIsNone(verified_paid_coverage_until(self.parent, environment='production', at=timezone.now()))

    def test_removed_parent_can_still_read_owned_status_and_stop_renewals(self):
        intent, provider, term = modern_fixture(self.parent)
        client = APIClient(HTTP_HOST='checkout.example.test'); client.force_authenticate(self.parent)
        with override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=''), patch(
                'apps.billing.views.configured_client', side_effect=AssertionError('Cancel provider call')):
            self.assertEqual(client.get(self.base+str(intent.pk)+'/').status_code, 200)
            response = client.post(self.base+str(intent.pk)+'/cancel/', {'password': PASSWORD}, format='json')
            self.assertEqual(response.status_code, 200)
            self.assertFalse(response.data['renewals_enabled'])
        grant = ParentContentEntitlement.objects.get()
        self.assertEqual(grant.valid_until, term.valid_until)
        self.assertEqual(grant.environment, 'sandbox')
        self.assertIsNone(verified_paid_coverage_until(self.parent, environment='production'))

    def test_term_receipt_command_uses_term_configuration_without_legacy_plan_or_checkout(self):
        from .models import SquareWebhookReceipt
        SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='enrollment-fixture-event',
            event_type='payment.updated', object_id='fixture-payment', body_sha256='a'*64)
        with override_settings(SQUARE_SANDBOX_RECONCILIATION_ENABLED=False,
                               SQUARE_SANDBOX_CHECKOUT_ENABLED=False, SQUARE_SANDBOX_PLAN_VARIATION_ID=''), patch(
                'apps.billing.management.commands.reconcile_square_sandbox.process_receipt', return_value='processed') as process:
            call_command('reconcile_square_sandbox', apply=True, limit=1, stdout=StringIO())
        self.assertEqual(process.call_count, 1)


@override_settings(**WEB)
@skipUnlessDBFeature('has_select_for_update')
class EnrollmentWithdrawalPostgresRaces(TransactionTestCase):
    def setUp(self):
        self.parent = make_parent('withdrawal-race')
        self.enterContext(override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=str(self.parent.pk)))

    def test_withdrawal_before_final_authorization_prevents_payment(self):
        from .terms import _authorize_dispatch
        provider = ModernWebFixture(); intent = make_term_intent(self.parent, provider)
        entered, proceed = Event(), Event()
        def held_authorization(term):
            entered.set()
            if not proceed.wait(timeout=10):
                raise AssertionError('Timed out waiting for enrollment withdrawal')
            return _authorize_dispatch(term)
        with patch('apps.billing.terms._authorize_dispatch', side_effect=held_authorization):
            with ThreadPoolExecutor(max_workers=1) as pool:
                first = pool.submit(isolated, lambda: confirm_term_checkout(parent=self.parent,
                    intent_id=intent.pk, password=PASSWORD, charge_source_id=CHARGE_SOURCE, client=provider))
                self.assertTrue(entered.wait(timeout=10))
                with override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=''):
                    proceed.set()
                    with self.assertRaises(CheckoutRejected):
                        first.result(timeout=15)
        self.assertEqual(provider.modern_requests, [])
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_withdrawal_after_provider_capture_retains_proof_without_grant_or_card_setup(self):
        provider = ModernWebFixture(); intent = make_term_intent(self.parent, provider)
        entered, proceed = Event(), Event(); original = provider.create_term_payment
        def held_payment(**kwargs):
            result = original(**kwargs)
            entered.set()
            if not proceed.wait(timeout=10):
                raise AssertionError('Timed out waiting for captured-payment withdrawal')
            return result
        provider.create_term_payment = held_payment
        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(isolated, lambda: confirm_term_checkout(parent=self.parent,
                intent_id=intent.pk, password=PASSWORD, charge_source_id=CHARGE_SOURCE, client=provider))
            self.assertTrue(entered.wait(timeout=10))
            with override_settings(SQUARE_SANDBOX_TEST_PARENT_IDS=''):
                proceed.set()
                with self.assertRaises(CheckoutRejected):
                    first.result(timeout=15)
        self.assertEqual(len(provider.modern_requests), 1)
        self.assertEqual(SquareBillingTerm.objects.get().state, 'paid')
        self.assertFalse(ParentContentEntitlement.objects.exists())
        self.assertEqual(provider.stored_cards, {})
