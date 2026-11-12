"""Real PostgreSQL row-lock races; explicit skips on SQLite, no provider calls."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
from threading import Barrier, Event
from unittest.mock import patch

from django.db import close_old_connections, connections
from django.test import TransactionTestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone

from .checkout import CheckoutBusy, CheckoutRejected, confirm_direct_checkout
from .models import ParentContentEntitlement, SquareCheckoutIntent, SquareInvoiceEvidence, SquareWebhookReceipt
from .reconciliation import process_receipt, reconcile_intent
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, FixtureSquare, confirmed_fixture, make_intent, make_parent
from .models import SquareCancellationOutbox
from .cancellation import process_cancellation


def isolated(function):
    close_old_connections()
    try:
        return function()
    finally:
        connections.close_all()


@override_settings(**CHECKOUT_CONFIG)
@skipUnlessDBFeature('has_select_for_update')
class CheckoutPostgresRaceTests(TransactionTestCase):
    def setUp(self): self.parent = make_parent()

    def test_parallel_first_taps_reserve_one_intent_and_stable_financial_key(self):
        barrier = Barrier(2)
        def attempt():
            barrier.wait(timeout=10)
            from .test_capture_terms import capture_intent
            from .test_modern_web import ModernWebFixture
            intent=capture_intent(self.parent,ModernWebFixture())
            return intent.pk,intent.provider_idempotency_key
        with ThreadPoolExecutor(max_workers=2) as pool:
            values = list(pool.map(lambda _: isolated(attempt), range(2)))
        self.assertEqual(values[0], values[1])
        self.assertEqual(SquareCheckoutIntent.objects.count(), 1)

    def test_parallel_retired_subscription_confirmations_never_dispatch(self):
        intent,client=make_intent(self.parent),FixtureSquare();barrier=Barrier(2)
        def confirm():
            barrier.wait(10)
            try:confirm_direct_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,
                source_id='cnon:historical-never-sent',client=client)
            except CheckoutRejected:return 'retired'
            raise AssertionError('Historical financial entry point unexpectedly accepted')
        with ThreadPoolExecutor(max_workers=2) as pool:
            values=list(pool.map(lambda _:isolated(confirm),range(2)))
        self.assertEqual(values,['retired','retired']);self.assertEqual(client.calls,[])

    def test_duplicate_receipt_workers_hold_one_lease_and_one_canonical_proof(self):
        intent, client = confirmed_fixture(self.parent)
        receipt = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='same-event',
            event_type='invoice.payment_made', object_id='invoice-a', body_sha256='a' * 64)
        entered, proceed = Event(), Event()
        original = client.retrieve_invoice
        first_call = True
        def held(identifier):
            nonlocal first_call
            if first_call:
                first_call = False; entered.set()
                if not proceed.wait(timeout=10): raise AssertionError('Timed out waiting for receipt release')
            self.assertFalse(connections['default'].in_atomic_block)
            return original(identifier)
        client.retrieve_invoice = held
        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(isolated, lambda: process_receipt(receipt_id=receipt.pk, client=client))
            self.assertTrue(entered.wait(timeout=10))
            try: self.assertEqual(process_receipt(receipt_id=receipt.pk, client=client), 'busy')
            finally: proceed.set()
            self.assertEqual(first.result(timeout=15), 'processed')
        receipt.refresh_from_db(); self.assertEqual(receipt.processing_attempts, 1)
        self.assertEqual(SquareInvoiceEvidence.objects.count(), 1)
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_expired_slow_owner_cannot_overwrite_newer_worker_evidence(self):
        intent, old_client = confirmed_fixture(self.parent)
        new_client = deepcopy(old_client)
        new_client.subscription['version'] = 2
        new_client.invoices['invoice-a'].update(version=2, updated_at='2026-11-11T10:00:00Z')
        new_client.payments['payment-a'].update(updated_at='2026-11-11T10:00:00Z', version_token='v2')
        entered, proceed = Event(), Event(); original = old_client.retrieve_subscription
        first_call = True
        def held(identifier):
            nonlocal first_call
            if first_call:
                first_call = False; entered.set()
                if not proceed.wait(timeout=10): raise AssertionError('Timed out waiting for old owner')
            return original(identifier)
        old_client.retrieve_subscription = held
        with ThreadPoolExecutor(max_workers=1) as pool:
            old = pool.submit(isolated, lambda: reconcile_intent(parent=self.parent, intent_id=intent.pk, client=old_client))
            self.assertTrue(entered.wait(timeout=10))
            try:
                SquareCheckoutIntent.objects.filter(pk=intent.pk).update(lease_until=timezone.now()-timedelta(seconds=1))
                reconcile_intent(parent=self.parent, intent_id=intent.pk, client=new_client)
            finally: proceed.set()
            with self.assertRaises(CheckoutBusy): old.result(timeout=15)
        self.assertEqual(SquareInvoiceEvidence.objects.get().invoice_version, 2)
        intent.refresh_from_db(); self.assertEqual(intent.subscription_version, 2)
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_two_cancellation_workers_schedule_once_and_provider_calls_are_outside_locks(self):
        _intent, client = confirmed_fixture(self.parent)
        self.parent.delete(); job = SquareCancellationOutbox.objects.get()
        entered, proceed = Event(), Event(); cancels = []
        def cancel(identifier):
            self.assertFalse(connections['default'].in_atomic_block)
            cancels.append(identifier); entered.set()
            if not proceed.wait(timeout=10): raise AssertionError('Timed out waiting for cancel release')
            client.subscription.update(canceled_date='2026-11-28', version=2)
            return {'subscription': dict(client.subscription)}
        client.cancel_subscription = cancel
        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(isolated, lambda: process_cancellation(outbox_id=job.pk, client=client))
            self.assertTrue(entered.wait(timeout=10))
            try: self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'busy')
            finally: proceed.set()
            self.assertEqual(first.result(timeout=15), 'verified')
        self.assertEqual(len(cancels), 1)

    def test_account_deletion_retains_and_cancels_historical_accepted_unbound_subscription(self):
        intent,client=confirmed_fixture(self.parent)
        intent.subscription_id='';intent.state='uncertain';intent.save()
        client.calls.clear();cancels=[]
        def cancel(identifier):
            self.assertFalse(connections['default'].in_atomic_block)
            cancels.append(identifier);client.subscription.update(canceled_date='2026-11-28',version=2)
            return {'subscription':dict(client.subscription)}
        client.cancel_subscription=cancel
        type(self.parent).objects.get(pk=self.parent.pk).delete()
        job=SquareCancellationOutbox.objects.get();self.assertEqual(job.subscription_id,'')
        self.assertNotEqual(job.card_id,'')
        self.assertEqual(process_cancellation(outbox_id=job.pk,client=client),'verified')
        self.assertEqual(len(cancels),1)
        self.assertFalse(any(call[0]=='create-subscription' for call in client.calls))
        self.assertFalse(SquareCheckoutIntent.objects.exists())
