"""App-owned exact-period tests; all provider responses are synthetic mocks."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone as dt_timezone
from io import StringIO
from unittest.mock import Mock, patch
from uuid import uuid4

from django.core.exceptions import ValidationError
from django.core.management import call_command
from django.db import transaction
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone

from .checkout import CheckoutConflict, CheckoutRejected
from .client import SquareClientError
from .models import (ParentContentEntitlement, SquareBillingTerm, SquareCheckoutIntent, SquareContentAgreement,
                     SquareWebhookReceipt)
from .permissions import has_paid_content_access, paid_content_access_until
from .reconciliation import process_receipt
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, FixtureSquare, make_parent
from .coverage import coverage_end
from .terms import (TERM_DISCLOSURE_VERSION, cancel_agreement, confirm_term_checkout, dispatch_term_payment,
                    next_anchor, prepare_due_term, process_due_terms, reconcile_term, reserve_term_checkout,
                    restart_unpaid_checkout, term_disclosure, term_reference)


class TermFixtureSquare(FixtureSquare):
    def __init__(self):
        super().__init__(); self.timeout_payment = False; self.payment_status = 'COMPLETED'

    def create_term_payment(self, **kwargs):
        self.calls.append(('create-payment', kwargs['idempotency_key'], kwargs['buyer_present']))
        identifier = 'payment-' + str(kwargs['term_id'])
        stamp = timezone.now().isoformat()
        self.payments[identifier] = {'id': identifier, 'reference_id': str(kwargs['term_id']),
            'location_id': kwargs['location_id'], 'customer_id': kwargs['customer_id'],
            'source_type': 'CARD', 'status': self.payment_status, 'version_token': 'term-v1',
            'created_at': stamp, 'updated_at': stamp, 'amount_money': {'amount': kwargs.get('amount_minor', 999), 'currency': 'USD'},
            'total_money': {'amount': kwargs.get('amount_minor', 999), 'currency': 'USD'}, 'refunded_money': {'amount': 0, 'currency': 'USD'},
            'refund_ids': [], 'order_id': 'order-' + str(kwargs['term_id']),
            'card_details': {'status':'CAPTURED' if self.payment_status == 'COMPLETED' else 'AUTHORIZED',
                'entry_method':'ON_FILE','card_payment_timeline':{'authorized_at':stamp,
                    **({'captured_at':stamp} if self.payment_status == 'COMPLETED' else {})}}}
        if self.timeout_payment: raise SquareClientError('Synthetic accepted-but-lost payment response')
        return {'payment': deepcopy(self.payments[identifier])}

    def list_payments(self, **kwargs):
        self.calls.append(('list-payments', kwargs['location_id']))
        return {'payments': deepcopy(list(self.payments.values()))}


def make_term_intent(parent, client=None):
    client = client or TermFixtureSquare()
    quote = term_disclosure('America/New_York')
    return reserve_term_checkout(parent=parent, password=PASSWORD, disclosure_version=TERM_DISCLOSURE_VERSION,
        disclosure_sha256=quote['disclosure_sha256'], accepted=True, client=client)


def prepare_term_fixture(parent, client=None):
    client = client or TermFixtureSquare(); intent = make_term_intent(parent, client)
    confirm_term_checkout(parent=parent, intent_id=intent.pk, password=PASSWORD,
        source_id='cnon:card-nonce-ok', prepare_only=True, client=client)
    return SquareCheckoutIntent.objects.get(pk=intent.pk), client


def paid_term_fixture(parent):
    intent, client = prepare_term_fixture(parent)
    confirm_term_checkout(parent=parent, intent_id=intent.pk, password=PASSWORD,
        verification_token='verf:synthetic-test-only', client=client)
    return intent, client, SquareBillingTerm.objects.get(agreement__intent_reference=intent.pk)


@override_settings(**CHECKOUT_CONFIG)
class TermCalendarTests(SimpleTestCase):
    def test_anchor_calendar_join27_join28_year_leap_and_dst(self):
        cases = [
            ('2026-11-27T23:00:00-05:00', '2026-11-28T05:00:00+00:00'),
            ('2026-11-28T12:00:00-05:00', '2026-12-28T05:00:00+00:00'),
            ('2026-12-28T00:00:00-05:00', '2027-01-28T05:00:00+00:00'),
            ('2028-02-28T00:00:00-05:00', '2028-03-28T04:00:00+00:00'),
            ('2026-03-01T12:00:00-05:00', '2026-03-28T04:00:00+00:00'),
            ('2026-10-28T00:00:00-04:00', '2026-11-28T05:00:00+00:00')]
        for start, end in cases:
            with self.subTest(start=start):
                self.assertEqual(next_anchor(datetime.fromisoformat(start), 'America/New_York'), datetime.fromisoformat(end))


@override_settings(**CHECKOUT_CONFIG)
class ExactTermTests(TestCase):
    def setUp(self): self.parent = make_parent()

    def test_prepare_then_verified_payment_grants_only_exact_frozen_contract_term(self):
        intent, client, term = paid_term_fixture(self.parent)
        agreement = term.agreement
        grant = ParentContentEntitlement.objects.get()
        self.assertEqual((grant.valid_from, grant.valid_until), (term.valid_from, term.valid_until))
        self.assertEqual(grant.source_reference, term_reference(term.pk))
        self.assertEqual(grant.environment, 'sandbox')
        self.assertEqual(term.state, 'paid'); self.assertIsNotNone(agreement.activated_at)
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 1)
        self.assertFalse(any(c[0] == 'create-subscription' for c in client.calls))
        with override_settings(PAID_CONTENT_ENFORCEMENT_ENABLED=True, PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='sandbox'):
            self.assertTrue(has_paid_content_access(self.parent, at=grant.payment_verified_at))
            self.assertFalse(has_paid_content_access(self.parent, at=term.valid_until))
            self.assertEqual(paid_content_access_until(self.parent), term.valid_until)

    def test_disclosure_timezone_hash_fresh_password_and_prepared_buyer_verification_required(self):
        client = TermFixtureSquare(); quote = term_disclosure('America/New_York')
        with self.assertRaises(CheckoutRejected):
            reserve_term_checkout(parent=self.parent, password=PASSWORD, disclosure_version=TERM_DISCLOSURE_VERSION,
                disclosure_sha256='0'*64, accepted=True, client=client)
        intent = make_term_intent(self.parent, client)
        with self.assertRaises(CheckoutRejected):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                source_id='cnon:card-nonce-ok', client=client)
        self.assertFalse(any(c[0].startswith('create-') for c in client.calls))
        intent, client = prepare_term_fixture(self.parent, client)
        with self.assertRaises(CheckoutRejected):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD, client=client)
        self.assertFalse(SquareBillingTerm.objects.exists())
        self.assertFalse(any(c[0] == 'create-payment' for c in client.calls))

    def test_repeated_confirmation_and_canonical_reconciliation_never_create_another_charge_or_grant(self):
        intent, client, term = paid_term_fixture(self.parent)
        confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD, client=client)
        reconcile_term(term_id=term.pk, client=client)
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 1)
        self.assertEqual(ParentContentEntitlement.objects.count(), 1)
        self.assertEqual(SquareBillingTerm.objects.count(), 1)

    def test_accepted_lost_response_recovers_by_exact_reference_from_webhook_without_another_post(self):
        intent, client = prepare_term_fixture(self.parent); client.timeout_payment = True
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        term = SquareBillingTerm.objects.get(); self.assertIsNone(term.payment_id)
        payment_id = 'payment-' + str(term.pk)
        receipt = SquareWebhookReceipt.objects.create(merchant_id='merchant-test', event_id='term-lost-response',
            event_type='payment.updated', object_id=payment_id, body_sha256='a'*64)
        self.assertEqual(process_receipt(receipt_id=receipt.pk, client=client), 'processed')
        self.assertEqual(ParentContentEntitlement.objects.get().source_reference, term_reference(term.pk))
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 1)

    def test_wrong_reference_customer_currency_or_location_never_grants_another_term(self):
        intent, client = prepare_term_fixture(self.parent); client.payment_status = 'PENDING'
        confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
            verification_token='verf:synthetic-test-only', client=client)
        term = SquareBillingTerm.objects.get(); payment = client.payments[term.payment_id]
        for field, value in [('reference_id', str(uuid4())), ('customer_id', 'foreign-customer'),
                             ('location_id', 'foreign-location')]:
            original = payment[field]; payment[field] = value
            with self.subTest(field=field), self.assertRaises(CheckoutRejected):
                reconcile_term(term_id=term.pk, client=client)
            payment[field] = original
        payment['amount_money']['currency'] = 'EUR'
        with self.assertRaises(CheckoutRejected): reconcile_term(term_id=term.pk, client=client)
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_approved_pending_failed_or_external_payments_do_not_grant(self):
        for status, source in [('PENDING', 'CARD'), ('APPROVED', 'CARD'), ('FAILED', 'CARD'), ('COMPLETED', 'EXTERNAL')]:
            parent = make_parent(status.lower()+source.lower())
            intent, client = prepare_term_fixture(parent); client.payment_status = status
            original = client.create_term_payment
            def create(_original=original, _source=source, **kwargs):
                result = _original(**kwargs)
                client.payments[result['payment']['id']]['source_type'] = _source
                return result
            client.create_term_payment = create
            confirm_term_checkout(parent=parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        self.assertFalse(ParentContentEntitlement.objects.exists())
        self.assertFalse(SquareContentAgreement.objects.filter(activated_at__isnull=False).exists())

    def test_late_notification_uses_original_capture_not_receipt_clock_or_reservation(self):
        start=timezone.now()-timedelta(days=50)
        with patch('apps.billing.terms.timezone.now',return_value=start):
            intent,client=prepare_term_fixture(self.parent);client.payment_status='PENDING'
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,
                verification_token='verf:synthetic-test-only',client=client)
        term=SquareBillingTerm.objects.get();self.assertIsNone(term.valid_until)
        term.valid_until=timezone.now()+timedelta(days=50)
        with self.assertRaises(ValidationError):term.save()
        term.refresh_from_db();captured=start+timedelta(minutes=2)
        payment=client.payments[term.payment_id]
        payment.update(status='COMPLETED',updated_at=timezone.now().isoformat(),version_token='v2')
        payment['card_details']['status']='CAPTURED'
        payment['card_details']['card_payment_timeline']['captured_at']=captured.isoformat()
        reconcile_term(term_id=term.pk,client=client)
        grant=ParentContentEntitlement.objects.get()
        self.assertEqual(grant.valid_until,captured+timedelta(days=30))
        self.assertLess(grant.valid_until,timezone.now())
        with override_settings(PAID_CONTENT_ENFORCEMENT_ENABLED=True,PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='sandbox'):
            self.assertFalse(has_paid_content_access(self.parent))

    def test_cancel_stops_new_terms_preserves_paid_current_and_delete_stops_scheduler_without_remote_sub(self):
        intent, client, term = paid_term_fixture(self.parent)
        cancel_agreement(parent=self.parent, intent_id=intent.pk, password=PASSWORD)
        self.assertIsNone(ParentContentEntitlement.objects.get().revoked_at)
        with self.assertRaises(CheckoutRejected): prepare_due_term(agreement_id=term.agreement_id)
        self.parent.delete()
        agreement = SquareContentAgreement.objects.get(); self.assertIsNone(agreement.parent_id)
        self.assertFalse(agreement.renewals_enabled); self.assertEqual(agreement.card_id, '')
        self.assertFalse(SquareCheckoutIntent.objects.exists())
        self.assertTrue(SquareBillingTerm.objects.exists())
        with self.assertRaises(CheckoutRejected): dispatch_term_payment(term_id=term.pk, client=client)
        self.assertEqual(len([c for c in client.calls if c[0] == 'create-payment']), 1)

    def test_renewal_uses_one_new_exact_calendar_term_and_no_buyer_present_or_native_subscription(self):
        intent, client, first = paid_term_fixture(self.parent)
        boundary = first.valid_until
        with patch('apps.billing.terms.timezone.now', return_value=boundary):
            second = prepare_due_term(agreement_id=first.agreement_id)
            self.assertEqual(second.request_not_before,boundary)
            self.assertIsNone(second.valid_from);self.assertIsNone(second.valid_until)
            self.assertFalse(second.buyer_present)
            self.assertEqual(dispatch_term_payment(term_id=second.pk, client=client), 'paid')
            with self.assertRaises(CheckoutRejected): prepare_due_term(agreement_id=first.agreement_id)
        self.assertEqual(ParentContentEntitlement.objects.count(), 2)
        self.assertEqual([c[2] for c in client.calls if c[0] == 'create-payment'], [True, False])
        self.assertFalse(any(c[0] == 'create-subscription' for c in client.calls))

    def test_missed_expired_cycle_is_not_backcharged_or_rolled_into_new_period(self):
        _intent, client, term = paid_term_fixture(self.parent)
        missed = coverage_end(term.valid_until,term.coverage_rule,term.agreement.billing_timezone)+timedelta(days=1)
        with patch('apps.billing.terms.timezone.now', return_value=missed), self.assertRaises(CheckoutRejected):
            prepare_due_term(agreement_id=term.agreement_id)
        agreement = SquareContentAgreement.objects.get(); self.assertFalse(agreement.renewals_enabled)
        self.assertEqual(agreement.outcome_code, 'missed_cycle_requires_review')
        self.assertEqual(SquareBillingTerm.objects.count(), 1)

    def test_full_refund_revokes_only_its_term_and_future_revocation_caps_media_ttl(self):
        _intent, client, term = paid_term_fixture(self.parent)
        payment = client.payments[term.payment_id]
        stamp = (timezone.now()+timedelta(seconds=1)).isoformat()
        payment.update(refund_ids=['refund-term'], refunded_money={'amount': 999, 'currency': 'USD'}, updated_at=stamp, version_token='v2')
        client.refunds['refund-term'] = {'id': 'refund-term', 'payment_id': term.payment_id,
            'location_id': term.location_id, 'status': 'COMPLETED', 'amount_money': {'amount': 999, 'currency': 'USD'}, 'updated_at': stamp}
        self.assertEqual(reconcile_term(term_id=term.pk, client=client), 'refunded')
        self.assertIsNotNone(ParentContentEntitlement.objects.get().revoked_at)
        # An independent current proof cannot mint URLs past a scheduled revoke.
        now = timezone.now(); revoke = now+timedelta(seconds=40)
        ParentContentEntitlement.objects.create(parent=self.parent, provider='square', environment='sandbox',
            provider_account_id='merchant-test', source_reference='independent-proof', feature_code='all_stories_and_games',
            valid_from=now-timedelta(seconds=1), valid_until=now+timedelta(days=10), payment_verified_at=now, revoked_at=revoke)
        with override_settings(PAID_CONTENT_ENFORCEMENT_ENABLED=True, PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='sandbox'):
            self.assertEqual(paid_content_access_until(self.parent, at=now), revoke)

    def test_commands_default_dry_run_no_transport_and_automatic_subscription_collision_rejects(self):
        with patch('apps.billing.configuration.configured_client', side_effect=AssertionError('Dry run opened transport')):
            call_command('renew_square_terms', stdout=StringIO())
            call_command('reconcile_square_terms', stdout=StringIO())
        intent, client = prepare_term_fixture(self.parent)
        intent.subscription_id = 'autonomous-subscription'; intent.save()
        with self.assertRaises(CheckoutConflict):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        self.assertFalse(any(c[0] == 'create-payment' for c in client.calls))

    def test_stale_initial_consent_before_first_dispatch_can_restart_without_resetting_uncertain_charge(self):
        intent, client = prepare_term_fixture(self.parent)
        with patch('apps.billing.terms.dispatch_term_payment', return_value='reserved'):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        term = SquareBillingTerm.objects.get()
        SquareContentAgreement.objects.filter(pk=term.agreement_id).update(consented_at=timezone.now()-timedelta(hours=1))
        with self.assertRaises(CheckoutRejected):
            dispatch_term_payment(term_id=term.pk, verification_token='verf:synthetic-test-only', client=client)
        self.assertFalse(any(c[0] == 'create-payment' for c in client.calls))
        quote = term_disclosure('America/New_York')
        fresh = restart_unpaid_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
            disclosure_version=TERM_DISCLOSURE_VERSION, disclosure_sha256=quote['disclosure_sha256'], accepted=True, client=client)
        self.assertNotEqual(fresh.pk, intent.pk)
        self.assertNotEqual(fresh.provider_idempotency_key, intent.provider_idempotency_key)
        self.assertEqual(SquareBillingTerm.objects.count(), 1)  # old frozen history retained

    def test_canonical_failed_payment_allows_fresh_consent_but_unknown_outcome_never_rotates_key(self):
        intent, client = prepare_term_fixture(self.parent); client.payment_status = 'FAILED'
        confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
            verification_token='verf:synthetic-test-only', client=client)
        quote = term_disclosure('America/New_York')
        fresh = restart_unpaid_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
            disclosure_version=TERM_DISCLOSURE_VERSION, disclosure_sha256=quote['disclosure_sha256'], accepted=True, client=client)
        self.assertNotEqual(fresh.pk, intent.pk)
        self.assertEqual(SquareBillingTerm.objects.get().state, 'failed')
        # A different parent's accepted-but-lost payment is never reset by retry.
        other = make_parent('uncertain')
        uncertain, other_client = prepare_term_fixture(other); other_client.timeout_payment = True
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=other, intent_id=uncertain.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=other_client)
        with self.assertRaises(CheckoutConflict):
            restart_unpaid_checkout(parent=other, intent_id=uncertain.pk, password=PASSWORD,
                disclosure_version=TERM_DISCLOSURE_VERSION, disclosure_sha256=quote['disclosure_sha256'], accepted=True, client=other_client)
        self.assertEqual(SquareCheckoutIntent.objects.filter(parent=other).count(), 1)

    def test_changed_second_read_identity_same_version_cannot_grant(self):
        intent, client = prepare_term_fixture(self.parent)
        original = client.retrieve_payment; calls = 0
        def changed(identifier):
            nonlocal calls
            calls += 1; data = original(identifier)
            if calls == 2: data['customer_id'] = 'foreign-customer'
            return data
        client.retrieve_payment = changed
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_multiple_reference_payments_are_quarantined_not_combined(self):
        intent, client = prepare_term_fixture(self.parent); client.timeout_payment = True
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        term = SquareBillingTerm.objects.get()
        original = deepcopy(client.payments['payment-'+str(term.pk)])
        client.payments['duplicate-payment'] = {**original, 'id': 'duplicate-payment'}
        with self.assertRaises(CheckoutRejected): reconcile_term(term_id=term.pk, client=client)
        self.assertFalse(ParentContentEntitlement.objects.exists())

    def test_foreign_existing_proof_cannot_be_revoked_by_this_terms_refund(self):
        _intent, client, term = paid_term_fixture(self.parent)
        ParentContentEntitlement.objects.all().delete()
        foreign = make_parent('foreign-proof')
        forged = ParentContentEntitlement.objects.create(parent=foreign, provider='square', environment='sandbox',
            provider_account_id='merchant-test', source_reference=term_reference(term.pk),
            feature_code='all_stories_and_games', valid_from=term.valid_from, valid_until=term.valid_until,
            payment_verified_at=timezone.now())
        stamp = (timezone.now()+timedelta(seconds=1)).isoformat()
        client.payments[term.payment_id].update(refund_ids=['refund-foreign'], refunded_money={'amount': 999, 'currency': 'USD'},
                                               updated_at=stamp, version_token='v2')
        client.refunds['refund-foreign'] = {'id': 'refund-foreign', 'payment_id': term.payment_id,
            'location_id': term.location_id, 'status': 'COMPLETED', 'amount_money': {'amount': 999, 'currency': 'USD'}, 'updated_at': stamp}
        with self.assertRaises(CheckoutRejected): reconcile_term(term_id=term.pk, client=client)
        forged.refresh_from_db(); self.assertIsNone(forged.revoked_at)

    def test_frozen_agreement_cannot_reassign_parent_or_timezone(self):
        _intent, _client, term = paid_term_fixture(self.parent)
        agreement = term.agreement
        agreement.parent = make_parent('reassigned')
        with self.assertRaises(ValidationError): agreement.save()
        agreement.refresh_from_db(); agreement.billing_timezone = 'UTC'
        with self.assertRaises(ValidationError): agreement.save()

    def test_uncertain_initial_request_that_never_arrived_cannot_charge_after_consent_expired(self):
        intent, client = prepare_term_fixture(self.parent)
        client.create_term_payment = Mock(side_effect=SquareClientError('Synthetic request never reached provider'))
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent, intent_id=intent.pk, password=PASSWORD,
                verification_token='verf:synthetic-test-only', client=client)
        term = SquareBillingTerm.objects.get()
        self.assertIsNotNone(term.dispatched_at)
        SquareContentAgreement.objects.filter(pk=term.agreement_id).update(consented_at=timezone.now()-timedelta(minutes=11))
        SquareBillingTerm.objects.filter(pk=term.pk).update(next_attempt_at=None)
        with self.assertRaises(CheckoutRejected):
            dispatch_term_payment(term_id=term.pk, verification_token='verf:synthetic-test-only', client=client)
        self.assertEqual(client.create_term_payment.call_count, 1)
        self.assertFalse(ParentContentEntitlement.objects.exists())
