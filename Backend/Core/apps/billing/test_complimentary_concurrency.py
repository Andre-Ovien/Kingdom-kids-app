"""PostgreSQL serialization of privileged grants and existing owned checkout."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, Event
from datetime import timedelta
from uuid import uuid4
from django.contrib.auth import get_user_model
from django.db import close_old_connections,connections,transaction
from django.test import TransactionTestCase,override_settings,skipUnlessDBFeature
from django.utils import timezone
from .complimentary import grant_access,owner_fingerprint,REASON
from .complimentary_models import ParentComplimentaryAccessGrant
from .test_checkout import make_parent
from .test_hosted_checkout import HOSTED,HostedFixture,authorize
from .hosted_checkout import prepare
from .checkout import CheckoutConflict


@override_settings(**HOSTED)
@skipUnlessDBFeature('has_select_for_update')
class ComplimentaryConcurrencyTests(TransactionTestCase):
 def setUp(self):
  self.parent=make_parent('complimentary-lock')
  self.args=dict(parent_id=self.parent.pk,environment='production',request_reference=str(uuid4()),owner_sha256=owner_fingerprint(self.parent),
   valid_until=timezone.now()+timedelta(days=29),authorized_by='user_request',reason_code=REASON,apply=True)
 def thread(self,action):
  close_old_connections()
  try:return action()
  finally:connections.close_all()
 def test_parallel_same_request_creates_once_without_extending(self):
  barrier=Barrier(2)
  def grant():barrier.wait(timeout=5);return grant_access(**self.args)[1]
  with ThreadPoolExecutor(max_workers=2) as pool:
   results=list(pool.map(lambda _:self.thread(grant),range(2)))
  self.assertEqual(sorted(results),[False,True]);self.assertEqual(ParentComplimentaryAccessGrant.objects.count(),1)
  self.assertEqual(ParentComplimentaryAccessGrant.objects.get().valid_until,self.args['valid_until'])
 def test_grant_committed_before_waiting_prepare_blocks_provider_creation(self):
  auth=authorize(self.parent);fixture=HostedFixture();started=Event();parent_id=self.parent.pk
  def waiting_prepare():
   parent=get_user_model().objects.get(pk=parent_id);started.set()
   try:prepare(parent=parent,operation_id=auth['operation_id'],billing_period='monthly',authorization_token=auth['authorization_token'],client=fixture)
   except CheckoutConflict:return 'blocked'
  with ThreadPoolExecutor(max_workers=1) as pool:
   with transaction.atomic():
    get_user_model().objects.select_for_update().get(pk=parent_id)
    future=pool.submit(self.thread,waiting_prepare);self.assertTrue(started.wait(timeout=5))
    grant_access(**self.args)
   self.assertEqual(future.result(timeout=10),'blocked')
  self.assertFalse(fixture.calls)
