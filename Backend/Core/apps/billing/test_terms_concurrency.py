"""Real PostgreSQL races with synthetic provider state, never a Square call."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier, Event
from unittest.mock import patch

from django.db import connections
from django.test import TransactionTestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone

from .checkout import CheckoutBusy, CheckoutRejected
from .client import SquareClientError
from .models import ParentContentEntitlement, SquareBillingTerm, SquareContentAgreement, SquareWebhookReceipt
from .reconciliation import process_receipt
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, make_parent
from .test_checkout_concurrency import isolated
from .test_terms import paid_term_fixture, prepare_term_fixture
from .terms import (cancel_agreement, confirm_term_checkout, dispatch_term_payment, prepare_due_term,
                    process_due_terms)


@override_settings(**CHECKOUT_CONFIG)
@skipUnlessDBFeature('has_select_for_update')
class ExactTermPostgresRaces(TransactionTestCase):
    def setUp(self): self.parent = make_parent()

    def test_parallel_confirmations_one_payment_one_grant_and_all_io_outside_transactions(self):
        intent, client = prepare_term_fixture(self.parent)
        atomic_states = []
        for name in [name for name in dir(client) if name.startswith(('retrieve_', 'create_', 'list_'))]:
            original = getattr(client, name)
            def checked(*args, _original=original, **kwargs):
                atomic_states.append(connections['default'].in_atomic_block)
                return _original(*args, **kwargs)
            setattr(client, name, checked)
        entered, proceed = Event(), Event(); original = client.create_term_payment
        def held(**kwargs):
            entered.set()
            if not proceed.wait(timeout=10): raise AssertionError('Timed out waiting for payment release')
            return original(**kwargs)
        client.create_term_payment = held
        def confirm(): return confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
            verification_token='verf:synthetic-test-only', client=client)
        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(isolated, confirm)
            self.assertTrue(entered.wait(timeout=10))
            try:
                with self.assertRaises(CheckoutBusy): confirm()
            finally: proceed.set()
            first.result(timeout=15)
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 1)
        self.assertEqual(ParentContentEntitlement.objects.count(), 1)
        self.assertTrue(atomic_states); self.assertFalse(any(atomic_states))

    def test_webhook_lease_takeover_after_remote_success_grants_once_before_old_response(self):
        intent, client = prepare_term_fixture(self.parent)
        entered, proceed = Event(), Event(); original = client.create_term_payment
        def held(**kwargs):
            result = original(**kwargs); entered.set()
            if not proceed.wait(timeout=10): raise AssertionError('Timed out waiting for old response')
            return result
        client.create_term_payment = held
        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(isolated, lambda: confirm_term_checkout(parent=self.parent, intent_id=intent.pk,
                password=PASSWORD, verification_token='verf:synthetic-test-only', client=client))
            self.assertTrue(entered.wait(timeout=10))
            try:
                term = SquareBillingTerm.objects.get()
                SquareBillingTerm.objects.filter(pk=term.pk).update(lease_until=timezone.now()-timedelta(seconds=1))
                receipt = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='term-takeover',
                    event_type='payment.updated', object_id='payment-'+str(term.pk), body_sha256='a'*64)
                self.assertEqual(process_receipt(receipt_id=receipt.pk, client=client), 'processed')
            finally: proceed.set()
            with self.assertRaises(CheckoutBusy): first.result(timeout=15)
        self.assertEqual(ParentContentEntitlement.objects.count(), 1)
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 1)

    def test_delete_during_authorized_payment_stops_future_billing_retains_proof_and_never_grants_deleted_parent(self):
        intent, client = prepare_term_fixture(self.parent)
        entered, proceed = Event(), Event(); original = client.create_term_payment
        def held(**kwargs):
            result = original(**kwargs); entered.set()
            if not proceed.wait(timeout=10): raise AssertionError('Timed out waiting for deleted-account payment')
            return result
        client.create_term_payment = held
        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(isolated, lambda: confirm_term_checkout(parent=self.parent, intent_id=intent.pk,
                password=PASSWORD, verification_token='verf:synthetic-test-only', client=client))
            self.assertTrue(entered.wait(timeout=10))
            try: type(self.parent).objects.get(pk=self.parent.pk).delete()
            finally: proceed.set()
            with self.assertRaises(SquareClientError): first.result(timeout=15)
        agreement = SquareContentAgreement.objects.get()
        self.assertIsNone(agreement.parent_id); self.assertFalse(agreement.renewals_enabled)
        self.assertEqual(SquareBillingTerm.objects.get().state, 'paid')
        self.assertFalse(ParentContentEntitlement.objects.exists())
        self.assertEqual(process_due_terms(client=client), [])
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 1)

    def test_cancel_wins_before_dispatch_authorization_no_financial_call(self):
        intent, client = prepare_term_fixture(self.parent)
        with patch('apps.billing.terms.dispatch_term_payment', return_value='reserved'):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        term = SquareBillingTerm.objects.get()
        from .terms import _authorize_dispatch
        def cancel_first(current):
            cancel_agreement(parent=self.parent, intent_id=intent.pk, password=PASSWORD)
            return _authorize_dispatch(current)
        with patch('apps.billing.terms._authorize_dispatch', side_effect=cancel_first), self.assertRaises(CheckoutRejected):
            dispatch_term_payment(term_id=term.pk, verification_token='verf:synthetic-test-only', client=client)
        self.assertFalse(any(c[0] == 'create-payment' for c in client.calls))

    def test_parallel_due_workers_create_only_one_new_term_and_payment(self):
        _intent, client, first = paid_term_fixture(self.parent)
        barrier = Barrier(2)
        def renew():
            barrier.wait(timeout=10)
            try:
                term = prepare_due_term(agreement_id=first.agreement_id)
                return dispatch_term_payment(term_id=term.pk, client=client)
            except CheckoutRejected: return 'not_due'
        with patch('apps.billing.terms.timezone.now', return_value=first.valid_until):
            with ThreadPoolExecutor(max_workers=2) as pool:
                result = list(pool.map(lambda _: isolated(renew), range(2)))
        self.assertCountEqual(result, ['paid', 'not_due'])
        self.assertEqual(SquareBillingTerm.objects.count(), 2)
        self.assertEqual(ParentContentEntitlement.objects.count(), 2)
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 2)
