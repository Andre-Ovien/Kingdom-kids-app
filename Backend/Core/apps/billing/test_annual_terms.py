"""Confirmed annual policy and exact-term billing; no real provider calls."""
from datetime import datetime, timedelta, timezone as utc
from decimal import Decimal, ROUND_HALF_UP
from unittest.mock import patch
from django.core.exceptions import ValidationError
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient
from .checkout import CheckoutConflict, CheckoutRejected, checkout_status
from .models import SquareCheckoutIntent, SquareBillingTerm, SquareContentAgreement, ParentContentEntitlement
from .term_plans import content_term_plan
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, make_parent
from .test_modern_web import ModernWebFixture, CHARGE_SOURCE
from .test_terms import make_term_intent
from .coverage import coverage_end
from .terms import (reserve_term_checkout, confirm_term_checkout, term_disclosure, next_term_anchor,
    prepare_due_term, dispatch_term_payment, reconcile_term, restart_unpaid_checkout)


def annual_intent(parent,client):
    quote=term_disclosure('America/New_York',billing_period='yearly')
    return reserve_term_checkout(parent=parent,password=PASSWORD,accepted=True,billing_period='yearly',
        disclosure_version=quote['disclosure_version'],disclosure_sha256=quote['disclosure_sha256'],client=client)


class AnnualPolicyCalendarTests(SimpleTestCase):
    def test_immutable_price_discount_cadence_and_plan_identity(self):
        monthly,yearly=content_term_plan('monthly'),content_term_plan('yearly')
        self.assertEqual(monthly.amount_minor,999);self.assertEqual(yearly.amount_minor,9990)
        self.assertEqual(yearly.amount_display,'99.90');self.assertEqual(yearly.cadence,'ANNUAL')
        self.assertEqual(int(Decimal(999)*10),9990)
        self.assertNotEqual(monthly.policy_id,yearly.policy_id);self.assertNotEqual(monthly.policy_sha256,yearly.policy_sha256)
        with self.assertRaises(ValueError):content_term_plan('custom')
    def test_yearly_is_capture_anniversary_not_an_earlier_28th(self):
        for start,end in [('2026-11-12T12:00:00-05:00','2027-11-12T17:00:00+00:00'),
                          ('2026-11-29T12:00:00-05:00','2027-11-29T17:00:00+00:00'),
                          ('2028-02-29T12:00:00-05:00','2029-02-28T17:00:00+00:00')]:
            self.assertEqual(coverage_end(datetime.fromisoformat(start),'calendar_year_1','America/New_York'),datetime.fromisoformat(end))
    def test_relative_quote_amount_and_modern_sdk_inputs_are_hash_bound(self):
        instant=datetime(2026,11,12,12,tzinfo=utc.utc)
        monthly=term_disclosure('America/New_York',at=instant)
        yearly=term_disclosure('America/New_York',billing_period='yearly',at=instant)
        self.assertIsNone(monthly['first_renewal_at']);self.assertIsNone(yearly['first_renewal_at'])
        self.assertEqual(yearly['web_tokenization']['amount'],'99.90')
        self.assertNotEqual(monthly['disclosure_sha256'],yearly['disclosure_sha256'])
        self.assertNotIn('monthly_billing_anchor_date',yearly)
        self.assertEqual(yearly['coverage_rule'],'calendar_year_1')


@override_settings(**CHECKOUT_CONFIG)
class AnnualExactTermsTests(TestCase):
    def setUp(self):self.parent=make_parent()
    def test_initial_annual_payment_and_future_renewal_have_exact_amount_bounds_and_same_saved_card(self):
        client=ModernWebFixture();intent=annual_intent(self.parent,client)
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        first=SquareBillingTerm.objects.get();agreement=first.agreement;grant=ParentContentEntitlement.objects.get()
        self.assertEqual((first.amount_minor,first.cadence),(9990,'ANNUAL'))
        self.assertEqual(grant.valid_until,coverage_end(first.captured_at,'calendar_year_1',agreement.billing_timezone))
        self.assertEqual(client.modern_requests[0]['amount_minor'],9990)
        self.assertEqual(checkout_status(SquareCheckoutIntent.objects.get(pk=intent.pk))['current_term']['amount_minor'],9990)
        with patch('apps.billing.terms.timezone.now',return_value=first.valid_until):
            second=prepare_due_term(agreement_id=agreement.pk)
            self.assertEqual(dispatch_term_payment(term_id=second.pk,client=client),'paid')
        self.assertEqual((second.amount_minor,second.cadence),(9990,'ANNUAL'))
        second.refresh_from_db()
        self.assertEqual(second.valid_until,coverage_end(second.captured_at,'calendar_year_1',agreement.billing_timezone))
        self.assertFalse(client.modern_requests[-1]['buyer_present']);self.assertTrue(second.card_id)
        self.assertEqual(ParentContentEntitlement.objects.count(),2)
        first.amount_minor=999
        with self.assertRaises(ValidationError):first.save()
    def test_wrong_monthly_amount_for_annual_never_grants(self):
        client=ModernWebFixture();intent=annual_intent(self.parent,client);original=client.create_term_payment
        def wrong(**kw):
            result=original(**kw)
            for key in ('amount_money','total_money'):client.payments[result['payment']['id']][key]['amount']=999
            return result
        client.create_term_payment=wrong
        with self.assertRaises(CheckoutRejected):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        self.assertFalse(ParentContentEntitlement.objects.exists());self.assertIsNone(SquareContentAgreement.objects.get().activated_at)
    def test_full_annual_refund_revokes_exact_annual_proof(self):
        client=ModernWebFixture();intent=annual_intent(self.parent,client)
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        term=SquareBillingTerm.objects.get();payment=client.payments[term.payment_id];stamp=(timezone.now()+timedelta(seconds=1)).isoformat()
        payment.update(refund_ids=['annual-refund'],refunded_money={'amount':9990,'currency':'USD'},updated_at=stamp,version_token='v2')
        client.refunds['annual-refund']={'id':'annual-refund','payment_id':term.payment_id,'location_id':term.location_id,
            'status':'COMPLETED','amount_money':{'amount':9990,'currency':'USD'},'updated_at':stamp}
        self.assertEqual(reconcile_term(term_id=term.pk,client=client),'refunded')
        self.assertIsNotNone(ParentContentEntitlement.objects.get().revoked_at)
    def test_one_unresolved_purchase_across_plans_and_safe_never_charged_duration_restart(self):
        client=ModernWebFixture();intent=annual_intent(self.parent,client)
        with self.assertRaises(CheckoutConflict):make_term_intent(self.parent,client)
        quote=term_disclosure('America/New_York')
        restarted=restart_unpaid_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,accepted=True,
            billing_period='monthly',disclosure_version=quote['disclosure_version'],disclosure_sha256=quote['disclosure_sha256'],client=client)
        intent.refresh_from_db();self.assertFalse(intent.is_open)
        self.assertEqual(restarted.policy_id,content_term_plan('monthly').policy_id)
        self.assertEqual(SquareCheckoutIntent.objects.count(),2);self.assertFalse(SquareBillingTerm.objects.exists())
        self.assertFalse(any(c[0]=='create-payment' for c in client.calls))
    def test_month_rollover_preserves_relative_consent_and_starts_full_year_at_actual_capture(self):
        client=ModernWebFixture();before=datetime(2026,12,1,4,59,tzinfo=utc.utc);after=before+timedelta(minutes=2)
        clock=[before];original=client.create_customer
        def crossing(**kw):
            result=original(**kw);clock[0]=after;return result
        client.create_customer=crossing
        with patch('apps.billing.terms.timezone.now',side_effect=lambda:clock[0]):
            intent=annual_intent(self.parent,client)
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        term=SquareBillingTerm.objects.get()
        self.assertEqual(term.valid_from,after)
        self.assertEqual(term.valid_until,coverage_end(after,'calendar_year_1','America/New_York'))
        self.assertEqual(len(client.modern_requests),1)
    def test_api_quote_selector_is_accepted_plan_only_and_confirmation_rejects_client_price(self):
        api=APIClient();api.force_authenticate(user=self.parent);client=ModernWebFixture();path='/api/billing/square/checkout-intents/'
        with patch('apps.billing.views.configured_client',return_value=client):
            response=api.get(path+'?billing_period=yearly');self.assertEqual(response.status_code,200);quote=response.data
            self.assertEqual(quote['amount_minor'],9990)
            response=api.post(path,{'password':PASSWORD,'accepted':True,'billing_period':'yearly',
                'disclosure_version':quote['disclosure_version'],'disclosure_sha256':quote['disclosure_sha256']},format='json')
            self.assertEqual(response.status_code,200);intent_id=response.data['id']
            bad=api.post(path+intent_id+'/confirm/',{'password':PASSWORD,'charge_source_id':CHARGE_SOURCE,'amount_minor':999},format='json')
            self.assertEqual(bad.status_code,400);self.assertFalse(client.modern_requests)
            good=api.post(path+intent_id+'/confirm/',{'password':PASSWORD,'charge_source_id':CHARGE_SOURCE},format='json')
            self.assertEqual(good.status_code,200);self.assertEqual(good.data['current_term']['amount_minor'],9990)
            self.assertEqual(api.get(path+'?billing_period=arbitrary').status_code,400)
