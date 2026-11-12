"""Enrolled real-environment profile, synthetic provider/isolated test DB only."""
from datetime import timedelta
from unittest.mock import Mock,patch
from uuid import uuid4
from django.core.cache import cache
from django.db import transaction
from django.test import TestCase,SimpleTestCase,override_settings
from rest_framework.test import APIClient
from .access_status import parent_content_access
from .checkout import CheckoutRejected,checkout_status
from .client import SquareClientError,SquareProductionClient
from .configuration import (SquareDisabled,SquareConfigurationError,require_checkout_enabled,
    require_production_qualified,controlled_production_parent_ids)
from .coverage import coverage_end
from .models import SquareBillingTerm,SquareContentAgreement,SquarePaymentCardBinding,ParentContentEntitlement
from .parent_checkout_web import checkout_capability
from .permissions import verified_paid_coverage_until
from .test_checkout import PASSWORD,CHECKOUT_CONFIG,make_parent,BASE
from .test_modern_web import CHARGE_SOURCE,modern_fixture
from .test_production_environment import PRODUCTION,ProductionFixture
from .term_plans import ONE_PERIOD_MONTHLY_ID,ONE_PERIOD_YEARLY_ID
from .terms import (reserve_term_checkout,confirm_term_checkout,term_disclosure,activate_payment_card,
    prepare_due_term,dispatch_term_payment,cancel_agreement)

ORIGIN='https://kingdom-kids-checkout-staging.onrender.com'
CONTROLLED={**PRODUCTION,'PARENT_CHECKOUT_ORIGIN':ORIGIN,
 'ALLOWED_HOSTS':['kingdom-kids-checkout-staging.onrender.com','testserver'],
 'SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED':True,'SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS':'2',
 'SQUARE_PRODUCTION_RELEASE_QUALIFIED':False,'PAID_CONTENT_ENFORCEMENT_ENABLED':False,
 'SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL':ORIGIN+'/api/billing/square/webhook/',
 'SQUARE_SANDBOX_ENABLED':False,'SQUARE_SANDBOX_CHECKOUT_ENABLED':False,
 'SQUARE_SANDBOX_RECONCILIATION_ENABLED':False,'SQUARE_SANDBOX_CANCELLATION_ENABLED':False,
 'SQUARE_SANDBOX_TERM_BILLING_ENABLED':False,'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED':False,
 'SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED':False,'PARENT_CHECKOUT_SANDBOX_ENABLED':False,
 'SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED':False,'SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED':False,
 'SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED':False,'SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED':False}


def reserve(parent,client,period='monthly'):
 q=term_disclosure('America/New_York',billing_period=period,environment='production')
 return reserve_term_checkout(parent=parent,password=PASSWORD,accepted=True,billing_period=period,
   disclosure_version=q['disclosure_version'],disclosure_sha256=q['disclosure_sha256'],client=client,environment='production')


def pay(parent,period='monthly',client=None):
 client=client or ProductionFixture();intent=reserve(parent,client,period)
 confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,
   client=client,environment='production')
 return intent,client,SquareBillingTerm.objects.get(agreement__intent_reference=intent.pk)


@override_settings(**CONTROLLED)
class ControlledProfileTests(SimpleTestCase):
 def test_default_off_wrong_origin_empty_malformed_ids_or_public_flags_fail_closed(self):
  for changes in ({'SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED':False},
    {'PARENT_CHECKOUT_ORIGIN':'https://other.example.test'}, {'SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS':''},
    {'SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS':'2,*'}, {'SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS':'02'},
    {'SQUARE_PRODUCTION_RELEASE_QUALIFIED':True},{'PAID_CONTENT_ENFORCEMENT_ENABLED':True},
    {'SQUARE_PRODUCTION_RENEWALS_ENABLED':True},{'SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED':True},
    {'SQUARE_SANDBOX_ENABLED':True},{'SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY':''},
    {'SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL':'https://other.example.test/hook/'}):
   with self.subTest(changes=changes),override_settings(**changes):
    with self.assertRaises((SquareDisabled,SquareConfigurationError)):require_checkout_enabled(environment='production')
  self.assertEqual(controlled_production_parent_ids(),frozenset({2}))
  with self.assertRaises(SquareDisabled):require_production_qualified()
 def test_typed_client_cannot_save_card_or_send_merchant_renewal(self):
  transport=Mock(environment='production');client=SquareProductionClient(transport)
  with self.assertRaises(SquareDisabled):client.create_card_from_payment(customer_id='c',payment_id='p',term_id=uuid4(),idempotency_key=uuid4())
  with self.assertRaises(SquareDisabled):client.create_term_payment(term_id=uuid4(),location_id='production-location',
    customer_id='c',card_id='card',idempotency_key=uuid4(),buyer_present=False)
  transport.send.assert_not_called()


@override_settings(**CONTROLLED)
class ControlledPurchaseTests(TestCase):
 def setUp(self):
  cache.clear();self.other=make_parent('not-approved');self.parent=make_parent('approved-two')
  self.assertEqual(self.parent.pk,2)
 def test_only_enrolled_parent_can_quote_reserve_or_send_source_no_general_paywall(self):
  allowed=parent_content_access(self.parent);denied=parent_content_access(self.other)
  self.assertEqual(allowed['checkout']['reason_code'],'production_controlled')
  self.assertTrue(allowed['checkout']['controlled_parent_eligible'])
  self.assertFalse(allowed['parent_plan_routing_enabled']);self.assertFalse(allowed['content_enforcement_enabled'])
  self.assertEqual(denied['checkout']['state'],'unavailable');self.assertFalse(denied['checkout']['controlled_parent_eligible'])
  api=APIClient();api.force_authenticate(self.other)
  with patch('apps.billing.views.configured_client',side_effect=AssertionError('Unenrolled provider setup')):
   self.assertEqual(api.get(BASE).status_code,404)
   self.assertEqual(api.post(BASE,{'password':PASSWORD,'accepted':True},format='json').status_code,404)
  client=ProductionFixture()
  with self.assertRaises(SquareDisabled):reserve(self.other,client)
  self.assertFalse(client.calls)
 def test_monthly_and_yearly_canonical_charge_only_no_card_save_or_future_mandate(self):
  for period,policy,amount in [('monthly',ONE_PERIOD_MONTHLY_ID,999),('yearly',ONE_PERIOD_YEARLY_ID,9990)]:
   # Both approved periods are exercised independently in isolated savepoints.
   with self.subTest(period=period):
    with transaction.atomic():
     intent,client,term=pay(self.parent,period);agreement=term.agreement
     self.assertEqual((agreement.policy_id,term.amount_minor,term.payment_source_mode),(policy,amount,'web_charge_only'))
     self.assertFalse(agreement.renewals_enabled);self.assertIsNone(agreement.activated_at);self.assertIsNone(agreement.next_term_start)
     self.assertEqual(term.valid_until,coverage_end(term.captured_at,term.coverage_rule,agreement.billing_timezone))
     self.assertEqual(verified_paid_coverage_until(self.parent,environment='production'),term.valid_until)
     self.assertFalse(SquarePaymentCardBinding.objects.exists())
     self.assertFalse(any(c[0] in {'store-payment-card','create-card','list-cards'} for c in client.calls))
     confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client,environment='production')
     self.assertEqual(len(client.modern_requests),1)
     with self.assertRaises(CheckoutRejected):activate_payment_card(term_id=term.pk,client=client,environment='production')
     with self.assertRaises((CheckoutRejected,SquareDisabled)):prepare_due_term(agreement_id=agreement.pk,environment='production')
     # A subsequent rollout cannot turn this frozen one-period contract recurring.
     with override_settings(**{**PRODUCTION,'SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED':False,'SQUARE_PRODUCTION_RENEWALS_ENABLED':True}):
      with self.assertRaises(CheckoutRejected):prepare_due_term(agreement_id=agreement.pk,environment='production')
      self.assertEqual(checkout_status(intent)['terms']['policy_id'],policy)
     transaction.set_rollback(True)
 def test_sandbox_purchase_untouched_and_does_not_grant_or_block_live_period(self):
  with override_settings(**CHECKOUT_CONFIG):sandbox,_,old=modern_fixture(self.parent)
  old_hash,old_end=old.request_sha256,old.valid_until
  self.assertEqual(parent_content_access(self.parent)['access_state'],'unpaid')
  intent,_,term=pay(self.parent)
  self.assertEqual(term.environment,'production');self.assertNotEqual(sandbox.pk,intent.pk)
  old.refresh_from_db();self.assertEqual((old.request_sha256,old.valid_until),(old_hash,old_end))
  self.assertEqual(ParentContentEntitlement.objects.filter(environment='sandbox').count(),1)
  self.assertEqual(ParentContentEntitlement.objects.filter(environment='production').count(),1)
 def test_disclosure_and_render_are_plain_one_period_no_card_or_recurring_consent(self):
  for period in ('monthly','yearly'):
   q=term_disclosure('America/New_York',billing_period=period,environment='production')
   self.assertEqual(q['web_tokenization']['intent'],'CHARGE');self.assertIsNone(q['first_renewal_rule'])
   self.assertFalse(q['automatic_renewal']);self.assertEqual(q['card_storage'],'none')
   self.assertIn('Automatic renewal is off.',q['disclosure']);self.assertIn('will not be saved',q['disclosure'])
   response=self.client.get('/parent/checkout/?plan='+period,secure=True,HTTP_HOST='kingdom-kids-checkout-staging.onrender.com')
   self.assertEqual(response.status_code,200);self.assertContains(response,'one payment for this paid period')
   self.assertNotContains(response,'I accept the billing agreement, saving my card')
   self.assertNotContains(response,'Sandbox');self.assertContains(response,'"billing_mode": "one_period"')
 def test_uncertain_initial_payment_recovers_same_capture_after_enrollment_withdrawal(self):
  client=ProductionFixture();client.timeout_payment=True;intent=reserve(self.parent,client)
  with self.assertRaises(SquareClientError):confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,
    charge_source_id=CHARGE_SOURCE,client=client,environment='production')
  with override_settings(SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS=''):
   confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client,environment='production')
   self.assertEqual(parent_content_access(self.parent)['access_state'],'paid')
   self.assertEqual(parent_content_access(self.parent)['checkout']['state'],'unavailable')
   self.assertEqual(parent_content_access(self.parent)['checkout']['management_state'],'available')
  self.assertEqual(len(client.modern_requests),1);self.assertFalse(SquarePaymentCardBinding.objects.exists())
 def test_cancel_before_final_dispatch_stops_one_period_request(self):
  client=ProductionFixture();intent=reserve(self.parent,client)
  with patch('apps.billing.terms.dispatch_term_payment',return_value='reserved'):
   confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,
    client=client,environment='production')
  term=SquareBillingTerm.objects.get();cancel_agreement(parent=self.parent,intent_id=intent.pk,password=PASSWORD,environment='production')
  client.calls.clear()
  with self.assertRaises(CheckoutRejected):dispatch_term_payment(term_id=term.pk,charge_source_id=CHARGE_SOURCE,client=client,environment='production')
  self.assertFalse(client.calls);self.assertFalse(client.modern_requests)
 def test_prior_recurring_intent_and_final_profile_switch_cannot_charge_under_controlled_mode(self):
  from .test_production_environment import reserve as public_reserve
  from .terms import _authorize_dispatch
  client=ProductionFixture()
  with override_settings(**{**PRODUCTION,'SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED':False}):
   intent=public_reserve(self.parent,client)
   with patch('apps.billing.terms.dispatch_term_payment',return_value='reserved'):
    confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,
     client=client,environment='production')
  term=SquareBillingTerm.objects.get();self.assertTrue(term.agreement.renewals_enabled);client.calls.clear()
  with self.assertRaises(CheckoutRejected):confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,
   charge_source_id=CHARGE_SOURCE,client=client,environment='production')
  with self.assertRaises(CheckoutRejected):dispatch_term_payment(term_id=term.pk,charge_source_id=CHARGE_SOURCE,client=client,environment='production')
  with self.assertRaises(CheckoutRejected):activate_payment_card(term_id=term.pk,client=client,environment='production')
  self.assertFalse(client.calls);self.assertFalse(client.modern_requests)
  def changed_profile(current):
   with override_settings(**CONTROLLED):return _authorize_dispatch(current)
  with override_settings(**{**PRODUCTION,'SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED':False}),patch(
     'apps.billing.terms._authorize_dispatch',side_effect=changed_profile):
   with self.assertRaises(CheckoutRejected):dispatch_term_payment(term_id=term.pk,charge_source_id=CHARGE_SOURCE,client=client,environment='production')
  self.assertFalse(client.modern_requests);self.assertFalse(ParentContentEntitlement.objects.exists())
