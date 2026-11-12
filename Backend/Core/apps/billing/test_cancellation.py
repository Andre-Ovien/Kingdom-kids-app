from datetime import timedelta
from io import StringIO
from unittest.mock import Mock, patch

from django.core.management import call_command
from django.db import DatabaseError, transaction
from django.test import TestCase, override_settings
from django.utils import timezone

from .cancellation import process_cancellation
from .client import SquareClientError, SquareResourceNotFound
from .configuration import SquareDisabled
from .models import (SquareCancellationOutbox, SquareCheckoutIntent, SquareCustomerIdentity,
                     SquareSubscriptionIdentity)
from .test_checkout import CHECKOUT_CONFIG, FixtureSquare, confirmed_fixture, make_intent, make_parent


def cancellable_fixture(parent):
    intent, client = confirmed_fixture(parent)
    def cancel(identifier):
        client.calls.append(('cancel-subscription', identifier))
        client.subscription.update(canceled_date='2026-11-28', version=client.subscription['version']+1)
        return {'subscription': dict(client.subscription)}
    client.cancel_subscription = Mock(side_effect=cancel)
    return intent, client


@override_settings(**CHECKOUT_CONFIG)
class DeletedAccountCancellationTests(TestCase):
    def setUp(self): self.parent = make_parent()

    def test_deletion_captures_minimal_refs_even_flags_off_and_worker_verifies_scheduled_cancel(self):
        intent, client = cancellable_fixture(self.parent)
        with override_settings(SQUARE_SANDBOX_ENABLED=False, SQUARE_SANDBOX_CHECKOUT_ENABLED=False,
                               SQUARE_SANDBOX_CANCELLATION_ENABLED=False):
            self.parent.delete()
            job = SquareCancellationOutbox.objects.get()
            self.assertFalse(SquareCheckoutIntent.objects.exists())
            self.assertEqual(job.intent_reference, intent.pk)
            with self.assertRaises(SquareDisabled): process_cancellation(outbox_id=job.pk, client=client)
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        job.refresh_from_db()
        self.assertEqual(job.outcome_code, 'renewal_cancellation_scheduled_verified')
        self.assertIsNotNone(job.canceled_date); self.assertIsNotNone(job.verified_at)
        self.assertEqual((job.customer_id, job.card_id), ('', ''))
        self.assertEqual(client.subscription['status'], 'ACTIVE')  # scheduled, not yet terminated
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        self.assertEqual(client.cancel_subscription.call_count, 1)
        fields = {field.name for field in SquareCancellationOutbox._meta.fields}
        self.assertFalse(fields & {'parent', 'user', 'email', 'password', 'source_id', 'raw_payload'})

    def test_cancel_timeout_retries_canonical_get_without_repeating_successful_post(self):
        _intent, client = cancellable_fixture(self.parent); self.parent.delete()
        job = SquareCancellationOutbox.objects.get()
        original = client.cancel_subscription.side_effect
        def accepted_but_lost(identifier):
            original(identifier)
            raise SquareClientError('Synthetic lost cancellation response')
        client.cancel_subscription.side_effect = accepted_but_lost
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'retry')
        SquareCancellationOutbox.objects.filter(pk=job.pk).update(next_attempt_at=None)
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        self.assertEqual(client.cancel_subscription.call_count, 1)

    def test_changed_card_or_plan_does_not_block_cancellation_of_known_owned_subscription(self):
        _intent, client = cancellable_fixture(self.parent); self.parent.delete()
        client.subscription.update(card_id='replacement-card', plan_variation_id='replacement-plan')
        job = SquareCancellationOutbox.objects.get()
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        self.assertEqual(client.cancel_subscription.call_count, 1)

    def test_wrong_customer_cannot_cancel_another_owners_subscription(self):
        _intent, client = cancellable_fixture(self.parent); self.parent.delete()
        client.subscription['customer_id'] = 'foreign-customer'
        job = SquareCancellationOutbox.objects.get()
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'retry')
        client.cancel_subscription.assert_not_called()
        job.refresh_from_db(); self.assertEqual(job.customer_id, client.customer['id'])

    def test_unknown_inflight_response_is_recovered_after_deletion_not_marked_done_on_empty_search(self):
        intent, client = cancellable_fixture(self.parent)
        SquareCheckoutIntent.objects.filter(pk=intent.pk).update(subscription_id='')
        self.parent.delete(); job = SquareCancellationOutbox.objects.get()
        search = client.search_subscriptions
        client.search_subscriptions = Mock(return_value={'subscriptions': []})
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'retry')
        job.refresh_from_db(); self.assertIsNone(job.verified_at); self.assertNotEqual(job.card_id, '')
        client.cancel_subscription.assert_not_called()
        client.search_subscriptions = search
        SquareCancellationOutbox.objects.filter(pk=job.pk).update(next_attempt_at=None)
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        self.assertEqual(client.cancel_subscription.call_count, 1)

    def test_reservation_without_card_never_dispatched_subscription_and_has_no_financial_cancel(self):
        make_intent(self.parent); self.parent.delete(); job = SquareCancellationOutbox.objects.get()
        client = FixtureSquare(); client.cancel_subscription = Mock()
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        job.refresh_from_db(); self.assertEqual(job.outcome_code, 'no_subscription_dispatched')
        client.cancel_subscription.assert_not_called()

    def test_hosted_link_is_disabled_and_verified_before_owned_subscription_cancel(self):
        intent, client = cancellable_fixture(self.parent)
        intent.checkout_mode, intent.payment_link_id, intent.order_template_id = 'hosted', 'link-a', 'template-a'
        intent.save(); self.parent.delete(); job = SquareCancellationOutbox.objects.get()
        present = True
        def retrieve(identifier):
            if not present: raise SquareResourceNotFound('Absent synthetic link')
            return {'id': identifier, 'order_id': 'template-a'}
        def delete(identifier):
            nonlocal present
            present = False
            return {'id': identifier}
        client.retrieve_payment_link = Mock(side_effect=retrieve)
        client.delete_payment_link = Mock(side_effect=delete)
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        client.delete_payment_link.assert_called_once_with('link-a')
        job.refresh_from_db(); self.assertIsNotNone(job.link_disabled_at)

    def test_hosted_unknown_customer_and_subscription_recover_only_by_exact_template(self):
        intent, client = cancellable_fixture(self.parent)
        intent.checkout_mode, intent.payment_link_id, intent.order_template_id = 'hosted', 'link-a', 'template-a'
        intent.subscription_id, intent.customer_id, intent.card_id = '', '', ''
        intent.save(); self.parent.delete(); job = SquareCancellationOutbox.objects.get()
        client.subscription['phases'] = [{'ordinal': 0, 'order_template_id': 'template-a'}]
        client.retrieve_payment_link = Mock(side_effect=SquareResourceNotFound('Already absent'))
        client.delete_payment_link = Mock()
        self.assertEqual(process_cancellation(outbox_id=job.pk, client=client), 'verified')
        client.cancel_subscription.assert_called_once_with(client.subscription['id'])
        job.refresh_from_db(); self.assertEqual(job.subscription_id, client.subscription['id'])

    def test_durable_capture_is_atomic_with_account_deletion_and_legacy_refs_survive(self):
        intent, _client = cancellable_fixture(self.parent)
        with patch.object(SquareCancellationOutbox.objects, 'get_or_create', side_effect=DatabaseError('Synthetic outbox outage')):
            with self.assertRaises(DatabaseError), transaction.atomic(): self.parent.delete()
        self.assertTrue(SquareCheckoutIntent.objects.filter(pk=intent.pk).exists())
        customer = SquareCustomerIdentity.objects.create(parent=self.parent, merchant_id='merchant-test', customer_id='legacy-customer')
        SquareSubscriptionIdentity.objects.create(customer=customer, subscription_id='legacy-subscription')
        self.parent.delete()
        self.assertTrue(SquareCancellationOutbox.objects.filter(checkout_mode='legacy', subscription_id='legacy-subscription').exists())

    def test_dryrun_does_not_inject_transport_or_cancel_and_expired_jobs_are_eligible(self):
        _intent, client = cancellable_fixture(self.parent); self.parent.delete()
        job = SquareCancellationOutbox.objects.get()
        SquareCancellationOutbox.objects.filter(pk=job.pk).update(state='processing', lease_until=timezone.now()-timedelta(seconds=1))
        with patch('apps.billing.configuration.configured_client', side_effect=AssertionError('Dry run opened transport')):
            call_command('cancel_deleted_square_sandbox', stdout=StringIO())
        with patch('apps.billing.management.commands.cancel_deleted_square_sandbox.process_cancellation', return_value='verified') as process:
            call_command('cancel_deleted_square_sandbox', apply=True, stdout=StringIO())
        process.assert_called_once_with(outbox_id=job.pk)
