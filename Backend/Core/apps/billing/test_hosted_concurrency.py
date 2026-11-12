"""Real PostgreSQL locks with fake provider I/O outside transactions."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier,Event
from django.contrib.auth import get_user_model
from django.db import close_old_connections,connections
from django.test import TransactionTestCase,override_settings,skipUnlessDBFeature
from . import hosted_checkout as core
from .checkout import CheckoutBusy,CheckoutConflict
from .hosted_models import SquareHostedAttempt,SquareHostedCancellation
from .test_checkout import make_parent,PASSWORD
from .test_hosted_checkout import HOSTED,HostedFixture,authorize


@override_settings(**HOSTED)
@skipUnlessDBFeature('has_select_for_update')
class HostedConcurrencyTests(TransactionTestCase):
 def setUp(self):self.parent=make_parent('hosted-locks');self.fixture=HostedFixture()
 def thread(self,action):
  close_old_connections()
  try:return action()
  finally:connections.close_all()
 def test_parallel_authorization_has_one_open_owned_operation(self):
  barrier=Barrier(2);parent_id=self.parent.pk
  def attempt():
   parent=get_user_model().objects.get(pk=parent_id);barrier.wait(timeout=5)
   try:return authorize(parent)['attempt_id']
   except CheckoutConflict:return 'conflict'
  with ThreadPoolExecutor(max_workers=2) as pool:
   results=list(pool.map(lambda _:self.thread(attempt),range(2)))
  self.assertEqual(results.count('conflict'),1);self.assertEqual(SquareHostedAttempt.objects.count(),1)
 def test_prepare_lease_blocks_second_provider_creation(self):
  auth=authorize(self.parent);entered=Event();release=Event();original=self.fixture.create_hosted_subscription_link;parent_id=self.parent.pk
  def blocked(*,payload):entered.set();release.wait(timeout=5);return original(payload=payload)
  self.fixture.create_hosted_subscription_link=blocked
  def prepare():return core.prepare(parent=get_user_model().objects.get(pk=parent_id),operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  with ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(self.thread,prepare)
   try:
    self.assertTrue(entered.wait(timeout=5))
    with self.assertRaises(CheckoutBusy):prepare()
   finally:release.set()
   result=future.result(timeout=10)
  self.assertEqual(result['state'],'ready');self.assertEqual(len([c for c in self.fixture.calls if c[0]=='create_link']),1)
 def test_cancel_during_provider_creation_prevents_ready_url_and_retains_owned_link(self):
  auth=authorize(self.parent);entered=Event();release=Event();original=self.fixture.create_hosted_subscription_link;parent_id=self.parent.pk
  def blocked(*,payload):
   result=original(payload=payload);entered.set();release.wait(timeout=5);return result
  self.fixture.create_hosted_subscription_link=blocked
  def prepare():return core.prepare(parent=get_user_model().objects.get(pk=parent_id),operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  with ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(self.thread,prepare)
   try:
    self.assertTrue(entered.wait(timeout=5))
    with self.assertRaises(CheckoutBusy):core.cancel(parent=self.parent,attempt_id=auth['attempt_id'],password=PASSWORD,client=self.fixture)
   finally:release.set()
   result=future.result(timeout=10)
  self.assertEqual(result['state'],'pending');self.assertIsNone(result['checkout_url'])
  row=SquareHostedAttempt.objects.get();self.assertTrue(row.cancel_requested_at);self.assertTrue(row.payment_link_id)
  self.assertEqual(SquareHostedCancellation.objects.count(),1)
 def test_delete_during_create_retains_refs_and_no_payment_url_or_grant(self):
  auth=authorize(self.parent);entered=Event();release=Event();original=self.fixture.create_hosted_subscription_link;parent_id=self.parent.pk
  def blocked(*,payload):
   result=original(payload=payload);entered.set();release.wait(timeout=5);return result
  self.fixture.create_hosted_subscription_link=blocked
  def prepare():return core.prepare(parent=get_user_model().objects.get(pk=parent_id),operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=self.fixture)
  with ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(self.thread,prepare)
   try:
    self.assertTrue(entered.wait(timeout=5));self.parent.delete()
   finally:release.set()
   result=future.result(timeout=10)
  self.assertEqual(result['state'],'pending');self.assertIsNone(result['checkout_url'])
  row=SquareHostedAttempt.objects.get();self.assertIsNone(row.parent_id);self.assertTrue(row.payment_link_id);self.assertTrue(row.cancel_requested_at)
  self.assertEqual(SquareHostedCancellation.objects.get().state,'pending')
 def test_cancel_during_reconcile_records_capture_but_preserves_pending_stop(self):
  from .test_hosted_checkout import ready
  attempt,_=ready(self.parent,self.fixture);sub=self.fixture.subscribe(attempt);self.fixture.capture(attempt,sub)
  entered=Event();release=Event();original=self.fixture.retrieve_invoice;parent_id=self.parent.pk
  def blocked(identifier):entered.set();release.wait(timeout=5);return original(identifier)
  self.fixture.retrieve_invoice=blocked
  def reconcile():return core.reconcile(parent=get_user_model().objects.get(pk=parent_id),attempt_id=attempt.pk,client=self.fixture)
  with ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(self.thread,reconcile)
   try:
    self.assertTrue(entered.wait(timeout=5))
    with self.assertRaises(CheckoutBusy):core.cancel(parent=self.parent,attempt_id=attempt.pk,password=PASSWORD,client=self.fixture)
   finally:release.set()
   result=future.result(timeout=10)
  self.assertTrue(result['payment_confirmed']);self.assertTrue(result['cancel_requested'])
  job=SquareHostedCancellation.objects.get();self.assertEqual(job.state,'pending')
  self.assertEqual(core.process_cancellation(job_id=job.pk,client=self.fixture),'verified')
 def test_deleted_parent_cannot_receive_grant_from_inflight_reconcile(self):
  from .test_hosted_checkout import ready
  from .models import ParentContentEntitlement
  from .hosted_models import SquareHostedPaymentProof
  attempt,_=ready(self.parent,self.fixture);sub=self.fixture.subscribe(attempt);self.fixture.capture(attempt,sub)
  entered=Event();release=Event();original=self.fixture.retrieve_invoice;parent_id=self.parent.pk
  def blocked(identifier):entered.set();release.wait(timeout=5);return original(identifier)
  self.fixture.retrieve_invoice=blocked
  def reconcile():return core.reconcile(parent=get_user_model().objects.get(pk=parent_id),attempt_id=attempt.pk,client=self.fixture)
  with ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(self.thread,reconcile)
   try:self.assertTrue(entered.wait(timeout=5));self.parent.delete()
   finally:release.set()
   future.result(timeout=10)
  attempt.refresh_from_db();self.assertIsNone(attempt.parent_id)
  self.assertEqual(SquareHostedPaymentProof.objects.count(),1);self.assertFalse(ParentContentEntitlement.objects.exists())
  self.assertEqual(SquareHostedCancellation.objects.get().state,'pending')
