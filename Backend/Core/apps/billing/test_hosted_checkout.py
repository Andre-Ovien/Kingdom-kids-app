"""Synthetic canonical hosted contracts only; no network or provider credentials."""
from copy import deepcopy
from datetime import timedelta
from unittest.mock import Mock,patch
from uuid import uuid4
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.db import transaction
from django.test import TestCase,SimpleTestCase,override_settings
from django.utils import timezone
from rest_framework.test import APIClient
from . import hosted_checkout as core
from .checkout import CheckoutBusy,CheckoutConflict,CheckoutRejected,fingerprint
from .client import SquareClientError,SquareResourceNotFound,SquareHttpResult
from .configuration import SquareDisabled,SquareConfigurationError
from .hosted_models import SquareHostedAttempt,SquareHostedPaymentProof,SquareHostedCancellation
from .hosted_policies import hosted_plan,disclosure
from .hosted_provider import hosted_configuration,approved_provider_url,HostedProductionClient
from .hosted_receipts import process_hosted_receipt
from .models import ParentContentEntitlement,SquareWebhookReceipt
from .permissions import verified_paid_coverage_until
from .access_status import parent_content_access
from .test_checkout import make_parent,PASSWORD
from .test_production_environment import PRODUCTION

ORIGIN='https://kingdom-kids-checkout-staging.onrender.com'
HOSTED={**PRODUCTION,'PARENT_CHECKOUT_ORIGIN':ORIGIN,
 'SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL':ORIGIN+'/api/billing/square/webhook/',
 'SQUARE_PRODUCTION_HOSTED_SUBSCRIPTIONS_ENABLED':True,'SQUARE_HOSTED_RELEASE_QUALIFIED':True,
 'SQUARE_PRODUCTION_HOSTED_MONTHLY_VARIATION_ID':'hosted-monthly','SQUARE_PRODUCTION_HOSTED_YEARLY_VARIATION_ID':'hosted-yearly',
 'SQUARE_PRODUCTION_CHECKOUT_ENABLED':False,'PARENT_CHECKOUT_PRODUCTION_ENABLED':False,
 'SQUARE_PRODUCTION_TERM_BILLING_ENABLED':False,'SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED':False,
 'SQUARE_PRODUCTION_RELEASE_QUALIFIED':False,'SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED':False,
 'SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS':'','SQUARE_PRODUCTION_RENEWALS_ENABLED':False,
 'SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED':False,'SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED':False,
 'SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED':False,'SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED':False,
 'SQUARE_SANDBOX_HOSTED_SUBSCRIPTIONS_ENABLED':False}
BASE='/api/billing/square/hosted-checkout/'


class HostedFixture:
 environment='production'
 def __init__(self):
  self.calls=[];self.orders={};self.payments={};self.invoices={};self.subscriptions={};self.refunds={};self.links={};self.keys={}
  self.fail_create=False;self.lose_create=False;self.cancel_lost=False;self.cancel_applied=True
 def retrieve_merchant(self,identifier):return {'id':identifier,'country':'US'}
 def retrieve_location(self,identifier):return {'id':identifier,'merchant_id':'production-merchant','country':'US','currency':'USD','status':'ACTIVE','timezone':'America/New_York'}
 def retrieve_catalogue_object(self,identifier):
  yearly=identifier=='hosted-yearly';money={'amount':9990 if yearly else 999,'currency':'USD'}
  return {'id':identifier,'type':'SUBSCRIPTION_PLAN_VARIATION','subscription_plan_variation_data':{
   'subscription_plan_id':'hosted-plan','can_prorate':False,'phases':[{'ordinal':0,'cadence':'ANNUAL' if yearly else 'THIRTY_DAYS',
    'pricing':{'type':'STATIC','price_money':money,'price':money}}]}}
 def create_hosted_subscription_link(self,*,payload):
  self.calls.append(('create_link',deepcopy(payload)))
  if self.fail_create:raise SquareClientError('Synthetic timeout')
  key=payload['idempotency_key']
  if key not in self.keys:
   number=len(self.keys)+1;link_id=f'link-{number}';order_id=f'template-{number}'
   order=deepcopy(payload['order']);order.update(id=order_id,total_money=order['line_items'][0]['base_price_money'])
   self.orders[order_id]=order;self.links[link_id]={'id':link_id,'order_id':order_id,'url':'https://square.link/u/owned'+str(number)}
   self.keys[key]=link_id
  result={'payment_link':deepcopy(self.links[self.keys[key]])}
  if self.lose_create:self.lose_create=False;raise SquareClientError('Accepted response lost')
  return result
 def retrieve_payment_link(self,identifier):
  if identifier not in self.links:raise SquareResourceNotFound('Absent')
  return deepcopy(self.links[identifier])
 def delete_payment_link(self,identifier):self.calls.append(('delete_link',identifier));self.links.pop(identifier,None);return {}
 def retrieve_order(self,identifier):return deepcopy(self.orders[identifier])
 def retrieve_subscription(self,identifier):return deepcopy(self.subscriptions[identifier])
 def search_subscriptions(self,**kwargs):self.calls.append(('search',kwargs));return {'subscriptions':deepcopy(list(self.subscriptions.values()))}
 def retrieve_invoice(self,identifier):return deepcopy(self.invoices[identifier])
 def retrieve_payment(self,identifier):return deepcopy(self.payments[identifier])
 def retrieve_refund(self,identifier):return deepcopy(self.refunds[identifier])
 def cancel_subscription(self,identifier):
  self.calls.append(('cancel_subscription',identifier))
  if self.cancel_applied:
   self.subscriptions[identifier]['canceled_date']=(timezone.now()+timedelta(days=30)).date().isoformat()
   self.subscriptions[identifier]['version']+=1
  if self.cancel_lost:raise SquareClientError('Accepted cancel response lost')
  return deepcopy(self.subscriptions[identifier])
 def subscribe(self,attempt):
  sub={'id':'subscription-'+str(attempt.pk),'location_id':attempt.location_id,'plan_variation_id':attempt.variation_id,
   'version':1,'status':'ACTIVE','customer_id':'customer-owned','card_id':'card-square-owned',
   'start_date':timezone.now().date().isoformat(),'created_at':timezone.now().isoformat(),
   'phases':[{'ordinal':0,'order_template_id':attempt.order_template_id}],'invoice_ids':[]}
  self.subscriptions[sub['id']]=sub;return sub
 def capture(self,attempt,sub,*,suffix='first',captured=None):
  captured=captured or timezone.now()-timedelta(seconds=1);stamp=timezone.now().isoformat();money={'amount':attempt.amount_minor,'currency':'USD'}
  invoice_id='invoice-'+suffix;order_id='billing-'+suffix;payment_id='payment-'+suffix
  self.invoices[invoice_id]={'id':invoice_id,'version':1,'updated_at':stamp,'status':'PAID','location_id':attempt.location_id,
    'subscription_id':sub['id'],'order_id':order_id,'primary_recipient':{'customer_id':sub['customer_id']}}
  self.orders[order_id]={'id':order_id,'version':1,'location_id':attempt.location_id,'total_money':money,'tenders':[{'payment_id':payment_id}]}
  self.payments[payment_id]={'id':payment_id,'order_id':order_id,'location_id':attempt.location_id,'customer_id':sub['customer_id'],
   'updated_at':stamp,'status':'COMPLETED','source_type':'CARD','amount_money':money,'total_money':money,
   'card_details':{'status':'CAPTURED','card_payment_timeline':{'captured_at':captured.isoformat()}}}
  sub['invoice_ids'].insert(0,invoice_id);sub['version']+=1
  return payment_id,invoice_id
 def refund(self,payment_id,amount=None):
  payment=self.payments[payment_id];amount=amount or payment['amount_money']['amount'];identifier='refund-'+payment_id;stamp=timezone.now().isoformat()
  self.refunds[identifier]={'id':identifier,'payment_id':payment_id,'location_id':payment['location_id'],'status':'COMPLETED',
   'updated_at':stamp,'amount_money':{'amount':amount,'currency':'USD'}}
  payment.update(refund_ids=[identifier],refunded_money={'amount':amount,'currency':'USD'},updated_at=stamp)
  self.invoices[next(k for k,v in self.invoices.items() if v['order_id']==payment['order_id'])]['status']='REFUNDED' if amount==payment['amount_money']['amount'] else 'PARTIALLY_REFUNDED'


def authorize(parent,period='monthly',operation=None):
 q=disclosure(period,'production')
 return core.authorize(parent=parent,operation_id=str(operation or uuid4()),billing_period=period,password=PASSWORD,
  accepted=True,disclosure_version=q['disclosure_version'],disclosure_sha256=q['disclosure_sha256'])


def ready(parent,fixture,period='monthly'):
 auth=authorize(parent,period);result=core.prepare(parent=parent,operation_id=auth['operation_id'],billing_period=period,
  authorization_token=auth['authorization_token'],client=fixture)
 return SquareHostedAttempt.objects.get(pk=result['attempt_id']),auth


def paid(parent,fixture,period='monthly'):
 attempt,auth=ready(parent,fixture,period);sub=fixture.subscribe(attempt);payment,invoice=fixture.capture(attempt,sub)
 result=core.reconcile(parent=parent,attempt_id=attempt.pk,client=fixture)
 return attempt,sub,payment,invoice,result


@override_settings(**HOSTED)
class HostedConfigurationTests(SimpleTestCase):
 def test_default_off_and_mixed_profiles_are_refused(self):
  hosted_configuration()
  for flag,value in [('SQUARE_HOSTED_RELEASE_QUALIFIED',False),('SQUARE_PRODUCTION_HOSTED_SUBSCRIPTIONS_ENABLED',False),
   ('PAID_CONTENT_ENFORCEMENT_ENABLED',False),('SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED',True),
   ('SQUARE_PRODUCTION_TERM_BILLING_ENABLED',True),('SQUARE_PRODUCTION_RENEWALS_ENABLED',True),
   ('PARENT_CHECKOUT_PRODUCTION_ENABLED',True),('SQUARE_PRODUCTION_RELEASE_QUALIFIED',True),
   ('SQUARE_PRODUCTION_HOSTED_YEARLY_VARIATION_ID','hosted-monthly')]:
   with self.subTest(flag=flag),override_settings(**{flag:value}):
    with self.assertRaises((SquareDisabled,SquareConfigurationError)):hosted_configuration()
 def test_exact_provider_urls_and_no_credential_redirect(self):
  for value in ['https://square.link/u/owned','https://checkout.square.site/merchant/m/order/o']:
   self.assertEqual(approved_provider_url(value,environment='production'),value)
  for value in ['https://sandbox.square.link/u/owned','https://square.link.evil/u/owned','http://square.link/u/owned',
    'https://square.link/u/owned?token=x','https://u:p@square.link/u/owned','https://square.link/u/owned#x','https://square.link/else','https://square.link/u/a%2fb']:
   with self.subTest(value=value),self.assertRaises(SquareClientError):approved_provider_url(value,environment='production')
 def test_hosted_adapter_cannot_make_app_owned_payment_or_card(self):
  transport=Mock(environment='production');client=HostedProductionClient(transport)
  for path in ['/v2/payments','/v2/cards','/v2/subscriptions']:
   with self.assertRaises(SquareDisabled):client.request('POST',path,{})
  transport.send.assert_not_called()
 def test_thirty_day_and_annual_static_plan_exact_prices(self):
  fixture=HostedFixture()
  for period,amount,cadence in [('monthly',999,'THIRTY_DAYS'),('yearly',9990,'ANNUAL')]:
   plan=hosted_plan(period);self.assertEqual((plan.amount,plan.cadence),(amount,cadence))
   core.validate_variation(fixture,identifier='hosted-'+period,period=period)
  canonical=fixture.retrieve_catalogue_object('hosted-monthly')
  for changes in [{'cadence':'MONTHLY'},{'periods':1},{'pricing':{'type':'RELATIVE','price_money':{'amount':999,'currency':'USD'}}},
   {'pricing':{'type':'STATIC','price_money':{'amount':999,'currency':'USD'},'price':{'amount':9990,'currency':'USD'}}}]:
   obj=deepcopy(canonical);obj['subscription_plan_variation_data']['phases'][0].update(changes)
   with patch.object(fixture,'retrieve_catalogue_object',return_value=obj),self.assertRaises(CheckoutRejected):
    core.validate_variation(fixture,identifier='hosted-monthly',period='monthly')


@override_settings(**HOSTED)
class HostedCheckoutTests(TestCase):
 def setUp(self):cache.clear();self.parent=make_parent('hosted');self.other=make_parent('hosted-other');self.fixture=HostedFixture()
 def test_all_verified_parents_quote_and_native_password_once(self):
  for parent in [self.parent,self.other]:
   result=core.quote(parent=parent,period='monthly',client=self.fixture)
   self.assertEqual(result['amount_minor'],999);self.assertEqual(result['parent_id'],str(parent.pk))
   self.assertEqual(parent_content_access(parent)['checkout']['reason_code'],'production_hosted')
  with self.assertRaises(CheckoutRejected):
   q=disclosure('monthly','production');core.authorize(parent=self.parent,operation_id=str(uuid4()),billing_period='monthly',password='bad',
    accepted=True,disclosure_version=q['disclosure_version'],disclosure_sha256=q['disclosure_sha256'])
  self.assertEqual(SquareHostedAttempt.objects.count(),0)
 def test_same_operation_plan_and_unresolved_checkout_block_new_attempt(self):
  auth=authorize(self.parent);again=authorize(self.parent,operation=auth['operation_id']);self.assertEqual(auth['attempt_id'],again['attempt_id'])
  with self.assertRaises(CheckoutConflict):authorize(self.parent,'yearly',operation=auth['operation_id'])
  with self.assertRaises(CheckoutConflict):authorize(self.parent,'yearly')
  self.assertEqual(SquareHostedAttempt.objects.count(),1)
 def test_auth_is_parent_plan_password_bound_and_no_provider_on_rejection(self):
  auth=authorize(self.parent)
  for token,parent in [(auth['authorization_token'],self.other),('kkhost.'+'x'*43,self.parent)]:
   with self.assertRaises((SquareHostedAttempt.DoesNotExist,CheckoutRejected)):
    core.prepare(parent=parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=token,client=self.fixture)
  self.parent.set_password('Changed-password-123!');self.parent.save()
  with self.assertRaises(CheckoutRejected):core.prepare(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  self.assertFalse(self.fixture.calls)
 def test_lost_creation_response_reuses_exact_frozen_key_and_body(self):
  auth=authorize(self.parent);self.fixture.lose_create=True
  kwargs=dict(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  with self.assertRaises(SquareClientError):core.prepare(**kwargs)
  attempt=SquareHostedAttempt.objects.get();self.assertEqual(attempt.state,'pending');key=attempt.provider_idempotency_key
  result=core.prepare(**kwargs);self.assertEqual(result['state'],'ready')
  calls=[c[1] for c in self.fixture.calls if c[0]=='create_link'];self.assertEqual(len(calls),2);self.assertEqual(calls[0],calls[1]);self.assertEqual(len(self.fixture.keys),1)
  self.assertEqual(calls[0]['idempotency_key'],str(key));self.assertNotIn(auth['authorization_token'],str(calls));self.assertNotIn(PASSWORD,str(calls))
 def test_monthly_yearly_paid_exact_capture_coverage_and_repeat_no_extension(self):
  for period in ['monthly','yearly']:
   with transaction.atomic():
    attempt,sub,payment,invoice,result=paid(self.parent,self.fixture,period)
    self.assertTrue(result['payment_confirmed']);proof=SquareHostedPaymentProof.objects.get(attempt=attempt)
    self.assertEqual(proof.valid_until,core.coverage_end(proof.captured_at,hosted_plan(period).coverage_rule,'America/New_York'))
    before=proof.valid_until;callcount=len([c for c in self.fixture.calls if c[0]=='create_link'])
    core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
    proof.refresh_from_db();self.assertEqual(proof.valid_until,before);self.assertEqual(ParentContentEntitlement.objects.filter(parent=self.parent).count(),1)
    self.assertEqual(len([c for c in self.fixture.calls if c[0]=='create_link']),callcount)
    self.assertEqual(verified_paid_coverage_until(self.parent,environment='production'),before)
    with self.assertRaises(CheckoutConflict):authorize(self.parent,period)
    transaction.set_rollback(True)
 def test_one_off_or_active_without_captured_invoice_never_grants(self):
  attempt,_=ready(self.parent,self.fixture)
  resumable=core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  self.assertEqual(resumable['state'],'ready');self.assertEqual(resumable['access_state'],'unknown');self.assertFalse(resumable['payment_confirmed'])
  sub=self.fixture.subscribe(attempt);result=core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  self.assertFalse(result['payment_confirmed']);self.assertEqual(result['access_state'],'unknown');self.assertFalse(ParentContentEntitlement.objects.exists())
 def test_foreign_customer_template_variation_amount_or_environment_never_grants(self):
  for mode in ['customer','template','variation','amount','environment']:
   with transaction.atomic():
    fixture=HostedFixture();attempt,_=ready(self.parent,fixture);sub=fixture.subscribe(attempt);payment,invoice=fixture.capture(attempt,sub)
    if mode=='customer':fixture.payments[payment]['customer_id']='foreign'
    if mode=='template':sub['phases'][0]['order_template_id']='foreign'
    if mode=='variation':sub['plan_variation_id']='foreign'
    if mode=='amount':fixture.payments[payment]['amount_money']={'amount':9990,'currency':'USD'}
    if mode=='environment':fixture.environment='sandbox'
    if mode=='template':
     self.assertFalse(core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=fixture)['payment_confirmed'])
    else:
     with self.assertRaises((CheckoutRejected,CheckoutBusy,SquareConfigurationError)):
      core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=fixture)
    self.assertFalse(ParentContentEntitlement.objects.exists());transaction.set_rollback(True)
 def test_full_refund_revokes_only_its_proof_not_newer_paid_invoice(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture)
  first=SquareHostedPaymentProof.objects.get();first_end=first.valid_until
  newpayment,newinvoice=self.fixture.capture(attempt,sub,suffix='renewal',captured=timezone.now())
  core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  self.fixture.refund(payment)
  core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture,invoice_hint=invoice)
  first.refresh_from_db();self.assertIsNotNone(first.revoked_at);self.assertEqual(first.valid_until,first_end)
  self.assertEqual(ParentContentEntitlement.objects.filter(revoked_at__isnull=True).count(),1)
  self.assertIsNotNone(verified_paid_coverage_until(self.parent,environment='production'))
 def test_pending_refund_or_partial_refund_cannot_revoke_other_grants(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture)
  self.fixture.refund(payment,100)
  result=core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  self.assertFalse(result['payment_confirmed']);proof=SquareHostedPaymentProof.objects.get();self.assertIsNone(proof.revoked_at)
  self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))
 def test_cancel_keeps_paid_end_and_stays_confirmed_after_read_reconcile(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture);end=result['access_until'];old=deepcopy(sub)
  result=core.cancel(parent=self.parent,attempt_id=attempt.pk,password=PASSWORD,client=self.fixture)
  self.assertTrue(result['cancellation_confirmed']);self.assertTrue(result['payment_confirmed']);self.assertFalse(result['renewals_enabled'])
  result=core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  self.assertTrue(result['cancellation_confirmed']);self.assertEqual(result['access_until'],end)
  self.fixture.subscriptions[sub['id']]=old
  with self.assertRaises(CheckoutRejected):core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  attempt.refresh_from_db();self.assertFalse(attempt.renewals_enabled)
 def test_uncertain_cancel_is_read_only_recovered_no_repeat_write(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture);self.fixture.cancel_lost=True
  with self.assertRaises(SquareClientError):core.cancel(parent=self.parent,attempt_id=attempt.pk,password=PASSWORD,client=self.fixture)
  job=SquareHostedCancellation.objects.get();self.assertEqual(core.process_cancellation(job_id=job.pk,client=self.fixture),'verified')
  self.assertEqual(len([c for c in self.fixture.calls if c[0]=='cancel_subscription']),1)
 def test_cancel_unpaid_link_revokes_it_but_absence_not_canonical_failure(self):
  attempt,_=ready(self.parent,self.fixture)
  with self.assertRaises(CheckoutBusy):core.cancel(parent=self.parent,attempt_id=attempt.pk,password=PASSWORD,client=self.fixture)
  self.assertNotIn(attempt.payment_link_id,self.fixture.links);attempt.refresh_from_db();self.assertTrue(attempt.is_open);self.assertEqual(attempt.state,'pending')
  self.assertEqual(SquareHostedCancellation.objects.get().state,'pending')
  with self.assertRaises(CheckoutConflict):authorize(self.parent,'yearly')
 def test_deletion_keeps_billing_ledger_and_pending_cancel_without_network_in_locks(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture)
  with self.captureOnCommitCallbacks(execute=False) as callbacks:
   self.parent.delete()
  attempt.refresh_from_db();self.assertIsNone(attempt.parent_id);self.assertTrue(attempt.cancel_requested_at)
  self.assertEqual(SquareHostedPaymentProof.objects.count(),1);self.assertEqual(SquareHostedCancellation.objects.get().state,'pending');self.assertEqual(len(callbacks),1)
  self.assertEqual(core.process_cancellation(job_id=SquareHostedCancellation.objects.get().pk,client=self.fixture),'verified')
  self.assertFalse(ParentContentEntitlement.objects.exists())
 def test_creation_deletion_race_retains_unknown_provider_operation(self):
  auth=authorize(self.parent);self.fixture.lose_create=True
  with self.assertRaises(SquareClientError):core.prepare(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  with self.captureOnCommitCallbacks(execute=False):self.parent.delete()
  job=SquareHostedCancellation.objects.get()
  with self.assertRaises(CheckoutBusy):core.process_cancellation(job_id=job.pk,client=self.fixture)
  job.refresh_from_db();self.assertEqual(job.state,'pending')
  self.assertFalse(core.status(SquareHostedAttempt.objects.get())['cancellation_confirmed'])
 def test_provider_read_failure_retains_lease_safe_pending_and_ownership(self):
  attempt,_=ready(self.parent,self.fixture)
  with patch.object(self.fixture,'search_subscriptions',side_effect=SquareClientError('timeout')):
   with self.assertRaises(SquareClientError):core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  attempt.refresh_from_db();self.assertIsNone(attempt.processing_lease);self.assertEqual(attempt.state,'pending');self.assertTrue(attempt.is_open)
 def test_paused_checkout_keeps_management_and_read_reconcile(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture)
  with override_settings(SQUARE_PRODUCTION_HOSTED_SUBSCRIPTIONS_ENABLED=False,SQUARE_HOSTED_RELEASE_QUALIFIED=False):
   result=parent_content_access(self.parent);self.assertEqual(result['checkout']['state'],'unavailable');self.assertEqual(result['checkout']['management_state'],'available')
   self.assertTrue(core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)['payment_confirmed'])
 def test_cross_parent_api_404_and_body_does_not_accept_return_url(self):
  attempt,_=ready(self.parent,self.fixture);api=APIClient();api.force_authenticate(self.other)
  self.assertEqual(api.get(BASE+f'attempts/{attempt.pk}/status/').status_code,404)
  self.assertEqual(api.post(BASE+f'attempts/{attempt.pk}/reconcile/',{},format='json').status_code,404)
  api.force_authenticate(self.parent)
  self.assertEqual(api.post(BASE+'prepare/',{'operation_id':str(uuid4()),'billing_period':'monthly','authorization_token':'x','return_url':'https://evil'},format='json').status_code,400)
 def test_model_owner_environment_and_paid_bounds_cannot_move(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture)
  attempt.environment='sandbox'
  with self.assertRaises(ValidationError):attempt.save()
  proof=SquareHostedPaymentProof.objects.get();proof.valid_until+=timedelta(days=1)
  with self.assertRaises(ValidationError):proof.save()
 def test_signed_receipt_hints_only_canonical_chain_grants_and_duplicate_no_extra_reads(self):
  attempt,_=ready(self.parent,self.fixture);sub=self.fixture.subscribe(attempt);payment,invoice=self.fixture.capture(attempt,sub)
  receipt=SquareWebhookReceipt.objects.create(environment='production',merchant_id='production-merchant',event_id='hosted-invoice',event_type='invoice.payment_made',object_id=invoice,body_sha256='a'*64)
  self.assertEqual(process_hosted_receipt(receipt_id=receipt.pk,client=self.fixture),'processed')
  self.assertIsNotNone(verified_paid_coverage_until(self.parent,environment='production'))
  with patch.object(self.fixture,'retrieve_invoice',side_effect=AssertionError('Replay read')):
   self.assertEqual(process_hosted_receipt(receipt_id=receipt.pk,client=self.fixture),'processed')
 def test_receipt_after_lost_create_binds_canonical_template_and_cancels_deleted_parent(self):
  auth=authorize(self.parent);self.fixture.lose_create=True
  with self.assertRaises(SquareClientError):core.prepare(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  attempt=SquareHostedAttempt.objects.get();attempt.order_template_id=next(iter(self.fixture.orders));sub=self.fixture.subscribe(attempt)
  with self.captureOnCommitCallbacks(execute=False):self.parent.delete()
  receipt=SquareWebhookReceipt.objects.create(environment='production',merchant_id='production-merchant',event_id='late-sub',event_type='subscription.created',object_id=sub['id'],body_sha256='b'*64)
  self.assertEqual(process_hosted_receipt(receipt_id=receipt.pk,client=self.fixture),'processed')
  attempt.refresh_from_db();self.assertEqual(attempt.subscription_id,sub['id']);self.assertFalse(attempt.renewals_enabled)
  self.assertEqual(SquareHostedCancellation.objects.get().state,'verified');self.assertFalse(ParentContentEntitlement.objects.exists())
 def test_no_subscription_panel_payment_remains_pending_no_customer_fallback(self):
  attempt,_=ready(self.parent,self.fixture)
  self.fixture.payments['panel']={'id':'panel','order_id':attempt.order_template_id,'status':'COMPLETED','amount_money':{'amount':999,'currency':'USD'}}
  receipt=SquareWebhookReceipt.objects.create(environment='production',merchant_id='production-merchant',event_id='panel-only',event_type='payment.updated',object_id='panel',body_sha256='c'*64)
  self.assertEqual(process_hosted_receipt(receipt_id=receipt.pk,client=self.fixture),'retry');self.assertFalse(ParentContentEntitlement.objects.exists())
 def test_already_paid_attempt_cannot_reopen_pay_even_with_original_authorization(self):
  attempt,auth=ready(self.parent,self.fixture);sub=self.fixture.subscribe(attempt);self.fixture.capture(attempt,sub)
  core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  before=len(self.fixture.calls)
  with self.assertRaises(CheckoutConflict):core.prepare(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  self.assertEqual(len(self.fixture.calls),before)
 def test_signed_webhook_consumes_canonical_initial_proof_and_uncertainty_is_retryable(self):
  import json
  from .tests import signature
  from .configuration import square_configuration
  attempt,_=ready(self.parent,self.fixture);sub=self.fixture.subscribe(attempt);payment,invoice=self.fixture.capture(attempt,sub)
  api=APIClient();path='/api/billing/square/webhook/'
  raw=json.dumps({'event_id':'signed-hosted','merchant_id':'production-merchant','type':'invoice.payment_made','data':{'id':invoice}}).encode()
  with patch('apps.billing.hosted_receipts.hosted_client',return_value=self.fixture):
   response=api.post(path,raw,content_type='application/json',HTTP_X_SQUARE_HMACSHA256_SIGNATURE=signature(raw,square_configuration(environment='production',webhook=True)))
  self.assertEqual(response.status_code,200);self.assertTrue(core.status(SquareHostedAttempt.objects.get())['payment_confirmed'])
  raw=json.dumps({'event_id':'unknown-hosted-payment','merchant_id':'production-merchant','type':'payment.updated','data':{'id':'not-settled'}}).encode()
  with patch('apps.billing.hosted_receipts.hosted_client',return_value=self.fixture):
   response=api.post(path,raw,content_type='application/json',HTTP_X_SQUARE_HMACSHA256_SIGNATURE=signature(raw,square_configuration(environment='production',webhook=True)))
  self.assertEqual(response.status_code,503)
 def test_budget_and_deadline_prevent_unbounded_canonical_scans(self):
  client=Mock();reader=core.HostedReader(client,timezone.now()+timedelta(seconds=8))
  for _ in range(24):reader.retrieve_payment('safe')
  with self.assertRaises(SquareClientError):reader.retrieve_payment('safe')
  self.assertEqual(client.retrieve_payment.call_count,24)
  expired=core.HostedReader(client,timezone.now()-timedelta(seconds=1))
  with self.assertRaises(SquareClientError):expired.retrieve_payment('safe')
 def test_single_invoice_cursor_makes_progress_through_longer_history(self):
  attempt,_=ready(self.parent,self.fixture);sub=self.fixture.subscribe(attempt)
  for index in range(5):self.fixture.capture(attempt,sub,suffix=str(index))
  seen=[]
  for _ in range(5):
   result=core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
   attempt.refresh_from_db();seen.append(attempt.reconciliation_invoice_cursor)
  self.assertEqual(len(set(seen)),5);self.assertEqual(SquareHostedPaymentProof.objects.count(),5)
  self.assertTrue(result['payment_confirmed'])
 def test_app_owned_financial_route_cannot_activate_beside_hosted_profile(self):
  from .configuration import require_checkout_enabled,require_production_qualified
  with override_settings(SQUARE_PRODUCTION_CHECKOUT_ENABLED=True,PARENT_CHECKOUT_PRODUCTION_ENABLED=True,SQUARE_PRODUCTION_RELEASE_QUALIFIED=True):
   with self.assertRaises(SquareDisabled):require_checkout_enabled(environment='production')
   with self.assertRaises(SquareDisabled):require_production_qualified()
 def test_cancel_first_pending_invoice_does_not_authorize_second_purchase(self):
  attempt,_=ready(self.parent,self.fixture);sub=self.fixture.subscribe(attempt)
  # A canonical subscription with an invoice whose card settlement is not yet
  # complete is still one unresolved purchase after future renewal is stopped.
  invoice='invoice-still-pending';sub['invoice_ids']=[invoice]
  result=core.cancel(parent=self.parent,attempt_id=attempt.pk,password=PASSWORD,client=self.fixture)
  self.assertTrue(result['cancellation_confirmed']);self.assertEqual(result['state'],'pending')
  self.assertEqual(result['access_state'],'unknown');attempt.refresh_from_db();self.assertTrue(attempt.is_open)
  with self.assertRaises(CheckoutConflict):authorize(self.parent,'yearly')
 def test_owned_status_and_recovery_query_counts_ignore_unrelated_ledger_size(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture);attempt.refresh_from_db()
  for population in [0,12]:
   for index in range(population):
    other=make_parent('unrelated-hosted-'+str(index));plan=hosted_plan('monthly')
    unrelated=SquareHostedAttempt.objects.create(parent=other,environment='production',operation_id=uuid4(),billing_period='monthly',
      policy_id=plan.policy_id,policy_sha256=plan.policy_sha256,disclosure_sha256='a'*64,merchant_id='production-merchant',
      location_id='production-location',variation_id='hosted-monthly',amount_minor=999,is_open=False)
    SquareHostedPaymentProof.objects.create(attempt=unrelated,environment='production',invoice_id='unrelated-invoice-'+str(index),
      payment_id='unrelated-payment-'+str(index),order_id='unrelated-order-'+str(index),amount_minor=999,status='COMPLETED',
      captured_at=timezone.now(),valid_until=timezone.now()+timedelta(days=30),payment_updated_at=timezone.now(),canonical_sha256='b'*64)
   with self.assertNumQueries(1):self.assertTrue(core.status(attempt)['payment_confirmed'])
   with self.assertNumQueries(2):self.assertEqual(core.recovery(self.parent,'production')['attempt_id'],str(attempt.pk))
 def test_sandbox_copy_of_hosted_grant_cannot_satisfy_production_access(self):
  attempt,sub,payment,invoice,result=paid(self.parent,self.fixture)
  proof=SquareHostedPaymentProof.objects.get();grant=ParentContentEntitlement.objects.get()
  grant.environment='sandbox'
  with self.assertRaises(ValidationError):grant.save()
  # Deliberate corrupt legacy/bulk copy bypasses save(), but cannot transfer proof.
  ParentContentEntitlement.objects.filter(pk=grant.pk).update(environment='sandbox')
  self.assertIsNone(verified_paid_coverage_until(self.parent,environment='sandbox'))
  self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))

 def test_explicit_resume_reads_same_single_use_link_never_creates_another(self):
  attempt,auth=ready(self.parent,self.fixture);before=len([c for c in self.fixture.calls if c[0]=='create_link'])
  result=core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  self.assertEqual(result['state'],'ready');self.assertEqual(result['checkout_url'],attempt.checkout_url)
  self.assertEqual(result['access_state'],'unknown');self.assertFalse(result['payment_confirmed'])
  same=core.prepare(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  self.assertEqual(same['attempt_id'],str(attempt.pk));self.assertEqual(same['checkout_url'],attempt.checkout_url)
  self.assertEqual(len([c for c in self.fixture.calls if c[0]=='create_link']),before)
  self.fixture.links.clear()
  with self.assertRaises(SquareResourceNotFound):core.reconcile(parent=self.parent,attempt_id=attempt.pk,client=self.fixture)
  attempt.refresh_from_db();self.assertEqual(attempt.state,'pending');self.assertTrue(attempt.is_open)

 def test_expired_prepare_budget_never_sends_creation_and_keeps_original_key(self):
  auth=authorize(self.parent)
  with patch.object(core.HostedReader,'ensure_budget',side_effect=[None,None,None,SquareClientError('Synthetic elapsed budget')]):
   with self.assertRaises(SquareClientError):core.prepare(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  attempt=SquareHostedAttempt.objects.get();self.assertEqual(attempt.state,'pending');self.assertTrue(attempt.request_sha256)
  self.assertFalse([c for c in self.fixture.calls if c[0]=='create_link'])
  key=attempt.provider_idempotency_key
  core.prepare(parent=self.parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  self.assertEqual(self.fixture.calls[0][1]['idempotency_key'],str(key))


@override_settings(**HOSTED)
class HostedTransportBoundaryTests(SimpleTestCase):
 def test_typed_hosted_create_uses_fixed_production_origin_once(self):
  import json
  transport=Mock(environment='production');transport.send.return_value=SquareHttpResult(200,b'{"payment_link":{"id":"owned"}}')
  payload={'idempotency_key':str(uuid4()),'order':{'reference_id':str(uuid4())}}
  self.assertEqual(HostedProductionClient(transport).create_hosted_subscription_link(payload=payload)['payment_link']['id'],'owned')
  self.assertEqual(transport.send.call_count,1);sent=transport.send.call_args.kwargs
  self.assertEqual(sent['url'],'https://connect.squareup.com/v2/online-checkout/payment-links')
  self.assertEqual(json.loads(sent['body']),payload)
  transport.send.side_effect=TimeoutError('Synthetic uncertain send')
  with self.assertRaises(SquareClientError):HostedProductionClient(transport).create_hosted_subscription_link(payload=payload)
  self.assertEqual(transport.send.call_count,2)  # One send per explicit invocation, no internal retry.
 def test_sandbox_transport_cannot_be_selected_for_hosted_production(self):
  from .hosted_provider import hosted_client
  transport=Mock(environment='sandbox')
  with override_settings(SQUARE_PRODUCTION_TRANSPORT_FACTORY=lambda:transport):
   with self.assertRaises(SquareConfigurationError):hosted_client(environment='production')
  transport.send.assert_not_called()
