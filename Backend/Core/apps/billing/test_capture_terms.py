"""Current user-confirmed durations:30elapsedDays/12calendarMonths after actual capture."""
from copy import deepcopy
from datetime import datetime,timedelta,timezone as utc
from unittest.mock import patch
from django.core.exceptions import ValidationError
from django.test import SimpleTestCase,TestCase,override_settings
from django.utils import timezone
from .coverage import coverage_end
from .checkout import CheckoutRejected,checkout_status
from .models import SquareBillingTerm,SquareContentAgreement,SquareCheckoutIntent,ParentContentEntitlement
from .term_plans import content_term_plan,ACTIVE_POLICY_IDS
from .test_checkout import CHECKOUT_CONFIG,PASSWORD,make_parent
from .test_modern_web import ModernWebFixture,CHARGE_SOURCE
from .terms import (reserve_term_checkout,term_disclosure,confirm_term_checkout,reconcile_term,
                    prepare_due_term,dispatch_term_payment)


def capture_intent(parent,client,period='monthly'):
    quote=term_disclosure('America/New_York',billing_period=period)
    return reserve_term_checkout(parent=parent,password=PASSWORD,accepted=True,billing_period=period,
        disclosure_version=quote['disclosure_version'],disclosure_sha256=quote['disclosure_sha256'],client=client)


class CaptureCalendarTests(SimpleTestCase):
    def test_30days_is_exact_elapsed_duration_across_dst_not_28_or_calendar_month(self):
        for stamp in ['2026-03-01T12:34:56-05:00','2026-10-20T12:34:56-04:00','2028-02-29T12:00:00+00:00']:
            start=datetime.fromisoformat(stamp)
            self.assertEqual(coverage_end(start,'elapsed_days_30','America/New_York')-start,timedelta(days=30))
    def test_annual_same_local_anniversary_leap_clamp_and_timezone_transition_rules(self):
        cases=[('2026-11-12T12:34:56-05:00','2027-11-12T17:34:56+00:00'),
               ('2028-02-29T12:34:56-05:00','2029-02-28T17:34:56+00:00'),
               ('2025-03-08T02:30:00-05:00','2026-03-08T07:30:00+00:00'),
               ('2025-11-01T01:30:00-04:00','2026-11-01T06:30:00+00:00')]
        for start,end in cases:
            self.assertEqual(coverage_end(datetime.fromisoformat(start),'calendar_year_1','America/New_York'),datetime.fromisoformat(end))
    def test_new_prices_relative_quote_has_no_guessed_renewal_timestamp(self):
        self.assertEqual(content_term_plan('monthly').amount_minor,999)
        self.assertEqual(content_term_plan('yearly').amount_minor,9990)
        for period,amount in [('monthly','9.99'),('yearly','99.90')]:
            quote=term_disclosure('America/New_York',billing_period=period)
            self.assertIsNone(quote['first_renewal_at']);self.assertEqual(quote['web_tokenization']['amount'],amount)
            self.assertIn(quote['policy_id'],ACTIVE_POLICY_IDS)
            self.assertNotIn('next 28th',quote['disclosure'])


@override_settings(**CHECKOUT_CONFIG)
class CapturePeriodTests(TestCase):
    def setUp(self):self.parent=make_parent()
    def test_delayed_checkout_binds_full_period_from_actual_capture_once_not_reservation(self):
        client=ModernWebFixture();intent=capture_intent(self.parent,client)
        start=timezone.now();captured=start+timedelta(minutes=3);original=client.create_term_payment
        clock=[start]
        def delayed(**kw):
            clock[0]=captured
            return original(**kw)
        client.create_term_payment=delayed
        with patch('apps.billing.terms.timezone.now',side_effect=lambda:clock[0]):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        term=SquareBillingTerm.objects.get();grant=ParentContentEntitlement.objects.get()
        self.assertEqual(term.valid_from,captured);self.assertEqual(term.valid_until,captured+timedelta(days=30))
        self.assertEqual((grant.valid_from,grant.valid_until),(term.valid_from,term.valid_until))
        self.assertTrue(term.coverage_sha256);self.assertEqual(term.coverage_rule,'elapsed_days_30')
        before=(term.valid_from,term.valid_until,term.coverage_sha256)
        with patch('apps.billing.terms.timezone.now',return_value=captured+timedelta(hours=1)):
            reconcile_term(term_id=term.pk,client=client)
        term.refresh_from_db();self.assertEqual(before,(term.valid_from,term.valid_until,term.coverage_sha256))
        term.valid_until+=timedelta(seconds=1)
        with self.assertRaises(ValidationError):term.save()
    def test_pending_payment_has_no_fabricated_dates_or_grant(self):
        client=ModernWebFixture();client.payment_status='PENDING';intent=capture_intent(self.parent,client)
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        term=SquareBillingTerm.objects.get();self.assertIsNone(term.valid_from);self.assertIsNone(term.valid_until)
        self.assertIsNone(term.captured_at);self.assertFalse(ParentContentEntitlement.objects.exists())
        self.assertEqual(checkout_status(SquareCheckoutIntent.objects.get(pk=intent.pk))['current_term']['coverage_state'],'awaiting_canonical_capture')
    def test_missing_naive_future_or_contradictory_capture_never_grants(self):
        for label in ['missing','naive','future','before_authorized']:
            parent=make_parent(label);client=ModernWebFixture();intent=capture_intent(parent,client);original=client.create_term_payment
            def broken(_label=label,_original=original,**kw):
                result=_original(**kw);payment=client.payments[result['payment']['id']];timeline=payment['card_details']['card_payment_timeline']
                if _label=='missing':timeline.pop('captured_at')
                if _label=='naive':timeline['captured_at']='2026-11-12T01:00:00'
                if _label=='future':timeline['captured_at']=(timezone.now()+timedelta(days=1)).isoformat()
                if _label=='before_authorized':timeline['captured_at']=(timezone.now()-timedelta(seconds=5)).isoformat()
                return result
            client.create_term_payment=broken
            with self.assertRaises(CheckoutRejected):
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        self.assertFalse(ParentContentEntitlement.objects.exists())
    def test_yearly9990_full_year_and_renewal_starts_only_after_old_coverage(self):
        client=ModernWebFixture();intent=capture_intent(self.parent,client,'yearly')
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        first=SquareBillingTerm.objects.get();self.assertEqual(first.amount_minor,9990)
        self.assertEqual(first.valid_until,coverage_end(first.captured_at,'calendar_year_1','America/New_York'))
        with self.assertRaises(CheckoutRejected):prepare_due_term(agreement_id=first.agreement_id)
        with patch('apps.billing.terms.timezone.now',return_value=first.valid_until):
            next_term=prepare_due_term(agreement_id=first.agreement_id)
            self.assertIsNone(next_term.valid_from);self.assertIsNone(next_term.valid_until)
            self.assertEqual(dispatch_term_payment(term_id=next_term.pk,client=client),'paid')
        next_term.refresh_from_db();self.assertEqual(next_term.valid_from,first.valid_until)
        self.assertEqual(next_term.valid_until,coverage_end(next_term.captured_at,'calendar_year_1','America/New_York'))
        self.assertEqual(ParentContentEntitlement.objects.count(),2)

    def test_pending_renewal_status_is_deterministic_and_recovery_targets_initial_payment(self):
        client=ModernWebFixture();intent=capture_intent(self.parent,client)
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        first=SquareBillingTerm.objects.get();client.payment_status='PENDING'
        with patch('apps.billing.terms.timezone.now',return_value=first.valid_until):
            pending=prepare_due_term(agreement_id=first.agreement_id)
            dispatch_term_payment(term_id=pending.pk,client=client)
            status=checkout_status(SquareCheckoutIntent.objects.get(pk=intent.pk))
            self.assertEqual(status['current_term']['id'],str(pending.pk))
            self.assertIsNone(status['current_term']['valid_until'])
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client)
        self.assertEqual(len(client.modern_requests),2)
        self.assertEqual(SquareBillingTerm.objects.get(pk=first.pk).captured_at,first.captured_at)
        self.assertEqual(ParentContentEntitlement.objects.count(),1)

    def test_existing_appstore_or_historical_paid_proof_blocks_reserve_and_dispatch(self):
        from .plans import ALL_CONTENT_FEATURE
        from .checkout import CheckoutConflict
        for provider,environment in [('app_store','production'),('square','sandbox')]:
            parent=make_parent(provider);client=ModernWebFixture();now=timezone.now()
            grant=ParentContentEntitlement.objects.create(parent=parent,feature_code=ALL_CONTENT_FEATURE,
                provider=provider,environment=environment,provider_account_id='verified-account',source_reference='verified-source',
                valid_from=now-timedelta(days=1),valid_until=now+timedelta(days=1),payment_verified_at=now)
            with self.assertRaises(CheckoutConflict):capture_intent(parent,client)
            grant.revoked_at=now;grant.save()
            intent=capture_intent(parent,client)
            # Another confirmed provider proof arrived after quote/reservation.
            ParentContentEntitlement.objects.filter(pk=grant.pk).update(revoked_at=None)
            with self.assertRaises(CheckoutRejected):
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
            self.assertFalse(client.modern_requests)

    def test_cancelled_expired_paid_contract_can_make_fresh_purchase_without_reusing_charge_key(self):
        from .terms import cancel_agreement
        client=ModernWebFixture();intent=capture_intent(self.parent,client)
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        first=SquareBillingTerm.objects.get();cancel_agreement(parent=self.parent,intent_id=intent.pk,password=PASSWORD)
        # Still-paid coverage cannot turn the same intent into a second charge.
        self.assertEqual(capture_intent(self.parent,client).pk,intent.pk)
        with patch('apps.billing.terms.timezone.now',return_value=first.valid_until+timedelta(seconds=1)):
            new=capture_intent(self.parent,client)
        self.assertNotEqual(new.pk,intent.pk)
        self.assertNotEqual(new.provider_idempotency_key,intent.provider_idempotency_key)
        self.assertEqual(len(client.modern_requests),1)

    def test_newer_canonical_capture_cannot_extend_frozen_period_and_late_renewal_is_full_duration(self):
        client=ModernWebFixture();intent=capture_intent(self.parent,client)
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        first=SquareBillingTerm.objects.get();old=(first.valid_from,first.valid_until,first.coverage_sha256)
        payment=client.payments[first.payment_id];capture=payment['card_details']['card_payment_timeline']['captured_at']
        payment['card_details']['card_payment_timeline']['captured_at']=(first.captured_at+timedelta(seconds=10)).isoformat()
        payment.update(updated_at=(timezone.now()+timedelta(seconds=10)).isoformat(),version_token='v2')
        with patch('apps.billing.terms.timezone.now',return_value=timezone.now()+timedelta(minutes=1)):
            with self.assertRaises(CheckoutRejected):reconcile_term(term_id=first.pk,client=client)
        first.refresh_from_db();self.assertEqual((first.valid_from,first.valid_until,first.coverage_sha256),old)
        payment['card_details']['card_payment_timeline']['captured_at']=capture
        late=first.valid_until+timedelta(days=2)
        with patch('apps.billing.terms.timezone.now',return_value=late):
            reconcile_term(term_id=first.pk,client=client)
            second=prepare_due_term(agreement_id=first.agreement_id)
            dispatch_term_payment(term_id=second.pk,client=client)
        second.refresh_from_db();self.assertEqual(second.valid_from,late)
        self.assertEqual(second.valid_until,late+timedelta(days=30))
        self.assertGreater(second.valid_from,first.valid_until)
        self.assertEqual(SquareContentAgreement.objects.get().next_term_start,second.valid_until)

    def test_canonical_capture_change_between_reads_never_commits_partial_coverage(self):
        client=ModernWebFixture();intent=capture_intent(self.parent,client);original=client.retrieve_payment;count=[0]
        def conflicting(identifier):
            result=original(identifier);count[0]+=1
            if count[0]==2:
                result['card_details']['card_payment_timeline']['captured_at']=(timezone.now()+timedelta(seconds=1)).isoformat()
            return result
        client.retrieve_payment=conflicting
        from .client import SquareClientError
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        term=SquareBillingTerm.objects.get();self.assertIsNone(term.captured_at);self.assertIsNone(term.valid_until)
        self.assertFalse(ParentContentEntitlement.objects.exists())
