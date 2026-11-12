from copy import deepcopy
from datetime import timedelta
from io import StringIO
from unittest.mock import Mock, patch
from uuid import uuid4

from django.core.management import call_command
from django.db import transaction
from django.test import TestCase, override_settings
from django.utils import timezone

from .checkout import CheckoutBusy, CheckoutRejected, confirm_direct_checkout
from .client import SquareClientError
from .models import ParentContentEntitlement, SquareCheckoutIntent, SquareInvoiceEvidence, SquareWebhookReceipt
from .reconciliation import (invoice_source_reference, process_receipt, reconcile_intent, resolve_invoice_coverage)
from .test_checkout import (CHECKOUT_CONFIG, PASSWORD, STAMP, FixtureSquare, confirmed_fixture,
                            make_intent, make_parent)


@override_settings(**CHECKOUT_CONFIG)
class ReconciliationTests(TestCase):
    def setUp(self):
        self.parent = make_parent()
        self.intent, self.client = confirmed_fixture(self.parent)

    def run_reconcile(self, **kwargs):
        return reconcile_intent(parent=self.parent, intent_id=self.intent.pk, client=self.client, **kwargs)

    def test_paid_invoice_records_canonical_chain_but_unproven_coverage_never_grants(self):
        self.assertEqual(self.run_reconcile(), 'review_required')
        row = SquareInvoiceEvidence.objects.get()
        self.assertEqual((row.invoice_id, row.charge_order_id, row.amount_minor), ('invoice-a', 'charge-order-a', 999))
        self.assertEqual(row.outcome_code, 'invoice_coverage_unproven')
        self.assertIsNone(row.valid_from); self.assertIsNone(row.valid_until)
        self.assertFalse(ParentContentEntitlement.objects.exists())
        self.run_reconcile()
        self.assertEqual(SquareInvoiceEvidence.objects.count(), 1)

    def test_late_old_invoice_and_latest_charged_through_never_widen_dates(self):
        self.client.subscription['charged_through_date'] = '2027-12-31'
        self.client.payments['payment-a']['updated_at'] = '2026-12-15T08:00:00Z'
        self.run_reconcile()
        row = SquareInvoiceEvidence.objects.get()
        self.assertEqual(row.billing_facts['due_date'], '2026-11-11')
        self.assertIsNone(row.valid_until)
        self.assertEqual(resolve_invoice_coverage(invoice_facts=row.billing_facts,
            subscription_facts=self.client.subscription).reason, 'invoice_coverage_unproven')
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_timeout_after_remote_subscription_recovers_via_owned_customer_card_without_second_mutation(self):
        self.intent.delete()
        # Seed a historical accepted-but-lost response locally. The retired
        # financial entry point is never invoked to manufacture new history.
        intent, client = confirmed_fixture(self.parent)
        intent.subscription_id='';intent.state='uncertain';intent.save()
        intent.refresh_from_db(); self.assertEqual(intent.subscription_id, '')
        # An old uncertain purchase is resolved using reads, not another charge.
        SquareCheckoutIntent.objects.filter(pk=intent.pk).update(consented_at=timezone.now() - timedelta(days=2))
        receipt = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='lost-response',
            event_type='subscription.created', object_id=client.subscription['id'], body_sha256='a' * 64)
        self.assertEqual(process_receipt(receipt_id=receipt.pk, client=client), 'processed')
        intent.refresh_from_db(); self.assertEqual(intent.subscription_id, client.subscription['id'])
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-subscription']), 1)
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_direct_recovery_rejects_customer_reference_card_parent_and_duplicate_subscriptions(self):
        for mutate in ['reference', 'card', 'duplicate']:
            client = deepcopy(self.client)
            if mutate == 'reference': client.customer['reference_id'] = str(uuid4())
            elif mutate == 'card': client.card['customer_id'] = 'other-parent-customer'
            else:
                duplicate = {**client.subscription, 'id': 'second-subscription'}
                client.search_subscriptions = Mock(return_value={'subscriptions': [client.subscription, duplicate]})
            with self.subTest(mutate=mutate), self.assertRaises(CheckoutRejected):
                reconcile_intent(parent=self.parent, intent_id=self.intent.pk, client=client)
            self.intent.refresh_from_db(); self.assertIsNone(self.intent.processing_lease)
        self.assertFalse(SquareInvoiceEvidence.objects.exists())

    def test_wrong_invoice_subscription_payment_order_or_currency_never_commits(self):
        for mutate in ['invoice', 'order', 'currency']:
            client = deepcopy(self.client)
            if mutate == 'invoice': client.invoices['invoice-a']['subscription_id'] = 'foreign-subscription'
            elif mutate == 'order': client.payments['payment-a']['order_id'] = 'foreign-order'
            else: client.payments['payment-a']['amount_money']['currency'] = 'EUR'
            with self.subTest(mutate=mutate), self.assertRaises(CheckoutRejected):
                reconcile_intent(parent=self.parent, intent_id=self.intent.pk, client=client)
        self.assertFalse(SquareInvoiceEvidence.objects.exists())

    def test_same_version_changed_facts_and_older_snapshots_do_not_overwrite(self):
        self.run_reconcile(); before = SquareInvoiceEvidence.objects.get().canonical_sha256
        self.client.payments['payment-a']['status'] = 'FAILED'
        with self.assertRaises(CheckoutRejected): self.run_reconcile()
        self.assertEqual(SquareInvoiceEvidence.objects.get().canonical_sha256, before)
        self.client.payments['payment-a']['status'] = 'COMPLETED'
        self.client.invoices['invoice-a']['version'] = 0
        with self.assertRaises(CheckoutRejected): self.run_reconcile()
        self.assertEqual(SquareInvoiceEvidence.objects.get().canonical_sha256, before)

    def test_mid_fetch_mutation_retries_without_partial_commit(self):
        original = self.client.retrieve_payment
        calls = 0
        def changed(identifier):
            nonlocal calls
            calls += 1
            data = original(identifier)
            if calls > 1: data['status'] = 'FAILED'
            return data
        self.client.retrieve_payment = changed
        with self.assertRaises(SquareClientError): self.run_reconcile()
        self.assertFalse(SquareInvoiceEvidence.objects.exists())

    def refund(self, amount=999):
        self.client.payments['payment-a'].update(refund_ids=['refund-a'], updated_at='2026-11-11T09:00:00Z',
            version_token='payment-version2', refunded_money={'amount': amount, 'currency': 'USD'})
        self.client.refunds['refund-a'] = {'id': 'refund-a', 'payment_id': 'payment-a',
            'location_id': 'location-test', 'status': 'COMPLETED', 'amount_money': {'amount': amount, 'currency': 'USD'},
            'updated_at': '2026-11-11T09:00:00Z'}
        self.client.invoices['invoice-a'].update(version=2, status='REFUNDED' if amount == 999 else 'PARTIALLY_REFUNDED',
                                                 updated_at='2026-11-11T09:00:00Z')

    def test_full_refund_revokes_only_that_exact_existing_fixture_proof_not_other_period(self):
        self.run_reconcile()
        now = timezone.now()
        # Existing isolated fixture, not a gateway-issued grant.
        first = ParentContentEntitlement.objects.create(parent=self.parent, feature_code='all_stories_and_games',
            provider='square', environment='sandbox', provider_account_id='merchant-test',
            source_reference=invoice_source_reference('invoice-a'), valid_from=now-timedelta(days=1),
            valid_until=now+timedelta(days=1), payment_verified_at=now)
        other = ParentContentEntitlement.objects.create(parent=self.parent, feature_code='all_stories_and_games',
            provider='square', environment='sandbox', provider_account_id='merchant-test',
            source_reference=invoice_source_reference('different-invoice'), valid_from=now-timedelta(days=1),
            valid_until=now+timedelta(days=1), payment_verified_at=now)
        self.refund(); self.run_reconcile()
        first.refresh_from_db(); other.refresh_from_db()
        self.assertIsNotNone(first.revoked_at); self.assertIsNone(other.revoked_at)
        self.assertIsNotNone(SquareInvoiceEvidence.objects.get().revoked_at)
        # A later stale paid delivery must not resurrect this proof.
        self.client.payments['payment-a'].update(refund_ids=[], refunded_money={'amount': 0, 'currency': 'USD'})
        self.client.invoices['invoice-a'].update(version=3, status='PAID')
        with self.assertRaises(CheckoutRejected): self.run_reconcile()
        self.assertIsNotNone(SquareInvoiceEvidence.objects.get().revoked_at)

    def test_partial_refund_cancellation_and_unpaid_states_do_not_invent_coverage(self):
        self.refund(amount=100); self.run_reconcile()
        row = SquareInvoiceEvidence.objects.get(); self.assertEqual(row.outcome_code, 'partial_refund_review')
        self.assertIsNone(row.revoked_at); self.assertFalse(ParentContentEntitlement.objects.exists())
        self.client.subscription.update(version=2, status='CANCELED')
        self.run_reconcile(); self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_unpaid_pending_external_or_inconsistent_refunds_never_count_as_paid_access(self):
        original_invoice = deepcopy(self.client.invoices['invoice-a'])
        original_payment = deepcopy(self.client.payments['payment-a'])
        for state in ('unpaid', 'pending', 'external', 'inconsistent-refund'):
            self.client.invoices['invoice-a'] = deepcopy(original_invoice)
            self.client.payments['payment-a'] = deepcopy(original_payment)
            SquareInvoiceEvidence.objects.all().delete()
            if state == 'unpaid': self.client.invoices['invoice-a']['status'] = 'UNPAID'
            elif state == 'pending': self.client.payments['payment-a']['status'] = 'PENDING'
            elif state == 'external': self.client.payments['payment-a']['source_type'] = 'EXTERNAL'
            else: self.client.payments['payment-a']['refunded_money']['amount'] = 999
            with self.subTest(state=state):
                if state == 'inconsistent-refund':
                    with self.assertRaises(CheckoutRejected): self.run_reconcile()
                else:
                    self.run_reconcile()
                    self.assertNotEqual(SquareInvoiceEvidence.objects.get().outcome_code, 'invoice_coverage_unproven')
                self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_receipt_dedupe_processing_and_out_of_order_payment_waits_for_real_invoice_binding(self):
        receipt = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='payment-first',
            event_type='payment.updated', object_id='payment-a', body_sha256='a' * 64)
        self.assertEqual(process_receipt(receipt_id=receipt.pk, client=self.client), 'retry')
        self.assertFalse(SquareInvoiceEvidence.objects.exists())
        invoice_receipt = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='invoice-after',
            event_type='invoice.payment_made', object_id='invoice-a', body_sha256='b' * 64)
        self.assertEqual(process_receipt(receipt_id=invoice_receipt.pk, client=self.client), 'processed')
        self.assertEqual(process_receipt(receipt_id=invoice_receipt.pk, client=self.client), 'processed')
        SquareWebhookReceipt.objects.filter(pk=receipt.pk).update(next_attempt_at=None)
        self.assertEqual(process_receipt(receipt_id=receipt.pk, client=self.client), 'processed')
        self.assertEqual(SquareInvoiceEvidence.objects.count(), 1)
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_lease_replacement_rejects_delayed_response_and_disabled_reconciliation_does_no_io(self):
        original = self.client.retrieve_subscription
        once = False
        def replace(identifier):
            nonlocal once
            if not once:
                once = True
                SquareCheckoutIntent.objects.filter(pk=self.intent.pk).update(processing_lease=uuid4())
            return original(identifier)
        self.client.retrieve_subscription = replace
        with self.assertRaises(CheckoutBusy): self.run_reconcile()
        self.assertFalse(SquareInvoiceEvidence.objects.exists())
        with override_settings(SQUARE_SANDBOX_RECONCILIATION_ENABLED=False), self.assertRaises(Exception):
            self.run_reconcile()

    def test_history_sweep_rotates_boundedly_and_manual_old_invoice_target_is_exact(self):
        original = deepcopy(self.client.invoices['invoice-a'])
        ids = ['invoice-a', 'invoice-b', 'invoice-c']
        for identifier in ids:
            self.client.invoices[identifier] = {**original, 'id': identifier, 'order_id': 'charge-' + identifier}
            self.client.orders['charge-' + identifier] = {**deepcopy(self.client.orders['charge-order-a']),
                'id': 'charge-' + identifier, 'tenders': [{'id': 'payment-' + identifier}]}
            self.client.payments['payment-' + identifier] = {**deepcopy(self.client.payments['payment-a']),
                'id': 'payment-' + identifier, 'order_id': 'charge-' + identifier}
        self.client.subscription.update(version=2, invoice_ids=ids)
        self.run_reconcile(); self.assertEqual(SquareInvoiceEvidence.objects.count(), 2)
        self.run_reconcile(); self.assertEqual(SquareInvoiceEvidence.objects.count(), 3)
        self.run_reconcile(invoice_id='invoice-c')
        self.assertEqual(SquareInvoiceEvidence.objects.count(), 3)
        with self.assertRaises(CheckoutRejected): self.run_reconcile(invoice_id='foreign-invoice')

    def test_operator_dry_run_no_network_and_expired_processing_lease_is_requeued(self):
        now = timezone.now()
        expired = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='expired',
            body_sha256='a'*64, event_type='invoice.payment_made', object_id='invoice-a',
            processing_state='processing', processing_lease=uuid4(), lease_until=now-timedelta(seconds=1))
        live = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='live',
            body_sha256='b'*64, event_type='invoice.payment_made', object_id='invoice-a',
            processing_state='processing', processing_lease=uuid4(), lease_until=now+timedelta(minutes=1))
        with patch('apps.billing.configuration.configured_client', side_effect=AssertionError('No transport')):
            call_command('reconcile_square_sandbox', stdout=StringIO())
        with patch('apps.billing.management.commands.reconcile_square_sandbox.process_receipt', return_value='processed') as process:
            call_command('reconcile_square_sandbox', apply=True, stdout=StringIO())
        process.assert_called_once_with(receipt_id=expired.pk)

    def test_hosted_exact_template_binding_duplicate_detection_and_distinct_invoice_order(self):
        self.intent.checkout_mode = 'hosted'; self.intent.order_template_id = 'checkout-template'
        self.intent.subscription_id = ''; self.intent.subscription_sha256 = ''; self.intent.subscription_version = 0
        self.intent.save()
        self.client.subscription['phases'] = [{'ordinal': 0, 'order_template_id': 'checkout-template'}]
        self.run_reconcile()
        self.assertNotEqual(SquareInvoiceEvidence.objects.get().charge_order_id, self.intent.order_template_id)
        other = {**deepcopy(self.client.subscription), 'id': 'duplicate-sub'}
        self.client.search_subscriptions = Mock(return_value={'subscriptions': [self.client.subscription, other]})
        with self.assertRaises(CheckoutRejected): self.run_reconcile()
        self.assertFalse(ParentContentEntitlement.objects.exists())
