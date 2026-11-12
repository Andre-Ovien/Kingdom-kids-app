"""Synthetic owned grants only, isolated DB, no keys/provider/runtime changes."""
from datetime import timedelta
from io import StringIO
from unittest.mock import patch
from uuid import uuid4
from django.core.exceptions import ValidationError
from django.test import TestCase,SimpleTestCase,override_settings
from django.utils import timezone
from rest_framework.test import APIClient
from .complimentary import grant_access,revoke_access,owner_fingerprint,ComplimentaryRejected,REASON
from .complimentary_models import ParentComplimentaryAccessGrant
from .complimentary_startup import apply_startup_operation,ComplimentaryStartupRejected,PREFIX,HOST
from .permissions import verified_paid_coverage_until,verified_content_access_until,has_paid_content_access,paid_content_access_until
from .access_status import parent_content_access
from .models import ParentContentEntitlement,SquareHostedAttempt
from .hosted_checkout import authorize as authorize_purchase
from .hosted_policies import disclosure
from .test_checkout import make_parent
from .test_hosted_checkout import HOSTED,HostedFixture,ready


def context():
 return {'RENDER_EXTERNAL_HOSTNAME':HOST,'DJANGO_ALLOWED_HOSTS':HOST,'PARENT_CHECKOUT_ORIGIN':'https://'+HOST,
  'RENDER_HOSTED_PRODUCTION_CHECKOUT_ENABLED':'true','DJANGO_DEBUG':'false','SQUARE_ENVIRONMENT':'production',
  'PAID_CONTENT_ENTITLEMENT_ENVIRONMENT':'production','PAID_CONTENT_ENFORCEMENT_ENABLED':'true','PARENT_CONTENT_ACCESS_STATUS_ENABLED':'true'}


@override_settings(**HOSTED)
class ComplimentaryAccessTests(TestCase):
 def setUp(self):
  self.parent=make_parent('complimentary');self.other=make_parent('complimentary-other')
  self.args=dict(parent_id=self.parent.pk,environment='production',request_reference=str(uuid4()),
    owner_sha256=owner_fingerprint(self.parent),valid_until=timezone.now()+timedelta(days=29,hours=23),
    authorized_by='user_request_20261112',reason_code=REASON)
 def test_dry_run_no_grant_and_apply_is_financially_separate(self):
  row,changed=grant_access(**self.args);self.assertFalse(changed);self.assertEqual(ParentComplimentaryAccessGrant.objects.count(),0)
  row,changed=grant_access(**self.args,apply=True);self.assertTrue(changed)
  self.assertEqual(ParentContentEntitlement.objects.count(),0);self.assertEqual(SquareHostedAttempt.objects.count(),0)
  self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))
  self.assertEqual(verified_content_access_until(self.parent,environment='production'),row.valid_until)
  self.assertEqual(paid_content_access_until(self.parent),row.valid_until);self.assertTrue(has_paid_content_access(self.parent))
  result=parent_content_access(self.parent)
  self.assertEqual(result['access_state'],'paid');self.assertEqual(result['access_basis'],'complimentary')
  self.assertEqual(result['reason_code'],'complimentary_access');self.assertFalse(result['payment_confirmed'])
  self.assertEqual(result['checkout']['state'],'unavailable');self.assertEqual(result['checkout']['management_state'],'unavailable')
  for key in ('purchase_recovery','management_recovery','hosted_checkout_recovery'):self.assertIsNone(result[key])
 def test_only_approved_owner_environment_active_verified_and_finite_period(self):
  for changes in [dict(owner_sha256='0'*64),dict(parent_id=self.other.pk),dict(environment='invalid'),
    dict(valid_until=timezone.now()+timedelta(days=31)),dict(valid_until=timezone.now()-timedelta(seconds=1)),dict(reason_code='arbitrary')]:
   with self.subTest(changes=changes),self.assertRaises(ComplimentaryRejected):grant_access(**{**self.args,**changes},apply=True)
  self.assertFalse(ParentComplimentaryAccessGrant.objects.exists())
  for field,value in [('is_active',False),('email_verified_at',None),('is_staff',True),('is_superuser',True)]:
   original=getattr(self.parent,field);setattr(self.parent,field,value);self.parent.save()
   with self.assertRaises(ComplimentaryRejected):grant_access(**self.args,apply=True)
   setattr(self.parent,field,original);self.parent.save()
 def test_environment_and_other_parent_cannot_use_grant(self):
  row,_=grant_access(**self.args,apply=True)
  self.assertIsNone(verified_content_access_until(self.parent,environment='sandbox'))
  self.assertFalse(has_paid_content_access(self.other))
  self.assertIsNone(verified_content_access_until(self.parent,environment='production',at=row.valid_until))
  self.parent.is_active=False;self.parent.save();self.assertFalse(has_paid_content_access(self.parent))
 def test_replay_never_extends_reassigns_or_unrevokes(self):
  row,_=grant_access(**self.args,apply=True);again,changed=grant_access(**self.args,apply=True)
  self.assertFalse(changed);self.assertEqual(again.pk,row.pk);self.assertEqual(again.valid_until,row.valid_until)
  for changes in [dict(parent_id=self.other.pk,owner_sha256=owner_fingerprint(self.other)),dict(environment='sandbox'),dict(valid_until=self.args['valid_until']-timedelta(hours=1))]:
   with self.assertRaises(ComplimentaryRejected):grant_access(**{**self.args,**changes},apply=True)
  revoke=dict(parent_id=self.parent.pk,environment='production',grant_id=str(row.pk),request_reference=str(uuid4()),owner_sha256=self.args['owner_sha256'],authorized_by='user_request_20261112')
  revoke_access(**revoke,apply=False);self.assertTrue(has_paid_content_access(self.parent))
  revoked,changed=revoke_access(**revoke,apply=True);self.assertTrue(changed);self.assertFalse(has_paid_content_access(self.parent))
  self.assertFalse(revoke_access(**revoke,apply=True)[1]);self.assertFalse(grant_access(**self.args,apply=True)[1])
  row.refresh_from_db();row.revoked_at=None
  with self.assertRaises(ValidationError):row.save()
 def test_model_owner_period_environment_are_immutable(self):
  row,_=grant_access(**self.args,apply=True)
  for field,value in [('parent',self.other),('environment','sandbox'),('valid_until',row.valid_until+timedelta(seconds=1))]:
   row.refresh_from_db();setattr(row,field,value)
   with self.assertRaises(ValidationError):row.save()
 def test_active_complimentary_owner_cannot_start_hosted_purchase(self):
  grant_access(**self.args,apply=True);q=disclosure('monthly','production')
  with self.assertRaises(Exception) as error:authorize_purchase(parent=self.parent,operation_id=str(uuid4()),billing_period='monthly',accepted=True,
    disclosure_version=q['disclosure_version'],disclosure_sha256=q['disclosure_sha256'])
  from .checkout import CheckoutConflict
  self.assertIsInstance(error.exception,CheckoutConflict);self.assertEqual(SquareHostedAttempt.objects.count(),0)
 def test_unknown_owned_financial_work_refuses_grant_without_touching_it(self):
  attempt,_=ready(self.parent,HostedFixture())
  with self.assertRaises(ComplimentaryRejected):grant_access(**self.args,apply=True)
  attempt.refresh_from_db();self.assertEqual(attempt.state,'ready');self.assertFalse(ParentComplimentaryAccessGrant.objects.exists())
 def test_grant_retained_anonymously_on_account_deletion_no_provider_rows(self):
  row,_=grant_access(**self.args,apply=True);self.parent.delete();row.refresh_from_db();self.assertIsNone(row.parent_id)
  self.assertFalse(ParentContentEntitlement.objects.exists())
  self.assertIsNone(verified_content_access_until(self.parent,environment='production'))
 def test_no_public_grant_endpoint(self):
  api=APIClient();api.force_authenticate(self.parent)
  self.assertEqual(api.post('/api/billing/complimentary-access/',{},format='json').status_code,404)
 def test_startup_apply_replay_and_safe_receipt_without_account_values(self):
  values={**context(),**{PREFIX+name:value for name,value in {
    'OPERATION':'grant','PARENT_ID':str(self.parent.pk),'ENVIRONMENT':'production','REQUEST_ID':self.args['request_reference'],
    'OWNER_SHA256':self.args['owner_sha256'],'VALID_UNTIL':self.args['valid_until'].isoformat(),
    'AUTHORIZED_BY':self.args['authorized_by'],'REASON':REASON}.items()}}
  output=[];self.assertTrue(apply_startup_operation(values,output=output.append))
  self.assertFalse(any(k.startswith(PREFIX) for k in values));self.assertEqual(len(output),1)
  self.assertNotIn(self.parent.email,output[0]);self.assertNotIn(self.args['owner_sha256'],output[0])
  self.assertIn('KK_COMPLIMENTARY_ACCESS_RECEIPT',output[0]);self.assertEqual(ParentComplimentaryAccessGrant.objects.count(),1)
 def test_startup_wrong_owner_or_db_exception_is_sanitized_and_stripped(self):
  raw={PREFIX+name:value for name,value in {'OPERATION':'grant','PARENT_ID':str(self.other.pk),'ENVIRONMENT':'production',
   'REQUEST_ID':self.args['request_reference'],'OWNER_SHA256':self.args['owner_sha256'],'VALID_UNTIL':self.args['valid_until'].isoformat(),
   'AUTHORIZED_BY':self.args['authorized_by'],'REASON':REASON}.items()}
  values={**context(),**raw}
  with self.assertRaises(ComplimentaryStartupRejected) as error:apply_startup_operation(values)
  self.assertNotIn(self.parent.email,str(error.exception));self.assertEqual(error.exception.safe_code,'invalid_owner');self.assertFalse(any(k.startswith(PREFIX) for k in values))
  values={**context(),**raw}
  with patch('apps.billing.complimentary.grant_access',side_effect=RuntimeError('private-db-url-and-token')):
   with self.assertRaises(ComplimentaryStartupRejected) as error:apply_startup_operation(values)
  self.assertNotIn('private',str(error.exception));self.assertEqual(error.exception.safe_code,'internal_error');self.assertFalse(any(k.startswith(PREFIX) for k in values))

 def test_multiple_active_grants_use_furthest_individually_clipped_expiry(self):
  first,_=grant_access(**{**self.args,'valid_until':timezone.now()+timedelta(days=2)},apply=True)
  second,_=grant_access(**{**self.args,'request_reference':str(uuid4()),'valid_until':timezone.now()+timedelta(days=10)},apply=True)
  self.assertEqual(verified_content_access_until(self.parent,environment='production'),second.valid_until)
  # A scheduled row revocation cannot clip a different valid authorization.
  second.revoked_at=timezone.now()+timedelta(days=1);second.revocation_reference=uuid4();second.revoked_by='operator';second.save()
  self.assertEqual(verified_content_access_until(self.parent,environment='production'),first.valid_until)
 def test_open_legacy_production_checkout_refuses_without_hiding_or_promoting_sandbox(self):
  from .test_checkout import make_intent
  intent=make_intent(self.parent)
  # Sandbox history is intentionally ignored by a production-only grant.
  grant_access(**self.args)
  from .models import SquareCheckoutIntent
  SquareCheckoutIntent.objects.filter(pk=intent.pk).update(environment='production')
  with self.assertRaises(ComplimentaryRejected):grant_access(**self.args,apply=True)
  self.assertFalse(ParentComplimentaryAccessGrant.objects.exists())

 def test_paid_and_complimentary_union_never_shortens_independent_valid_period(self):
  from .test_hosted_checkout import paid
  from .hosted_checkout import reconcile
  fixture=HostedFixture();attempt,sub,payment,invoice,result=paid(self.parent,fixture)
  paid_end=verified_paid_coverage_until(self.parent,environment='production')
  # Canonical terminal subscription, completed first invoice, no future billing.
  sub['status']='CANCELED';sub['canceled_date']=timezone.now().date().isoformat();sub['version']+=1
  reconcile(parent=self.parent,attempt_id=attempt.pk,client=fixture)
  row,_=grant_access(**{**self.args,'valid_until':timezone.now()+timedelta(days=3)},apply=True)
  self.assertLess(row.valid_until,paid_end)
  self.assertEqual(verified_content_access_until(self.parent,environment='production'),paid_end)
  result=parent_content_access(self.parent)
  self.assertEqual(result['access_until'],paid_end.isoformat());self.assertEqual(result['access_basis'],'complimentary')
  self.assertFalse(result['payment_confirmed'])


class ComplimentaryStartupValidationTests(SimpleTestCase):
 def test_absent_default_has_no_import_or_query(self):
  with patch('apps.billing.complimentary.grant_access',side_effect=AssertionError('No grant')):
   self.assertFalse(apply_startup_operation({}))
 def test_partial_invalid_wrong_host_or_sandbox_refused_before_service(self):
  valid={**context(),**{PREFIX+name:value for name,value in {'OPERATION':'grant','PARENT_ID':'41','ENVIRONMENT':'production',
   'REQUEST_ID':str(uuid4()),'OWNER_SHA256':'a'*64,'VALID_UNTIL':(timezone.now()+timedelta(days=29)).isoformat(),
   'AUTHORIZED_BY':'user_request','REASON':REASON}.items()}}
  for changes in [{'RENDER_EXTERNAL_HOSTNAME':'evil.example'},{'SQUARE_ENVIRONMENT':'sandbox'},{PREFIX+'ENVIRONMENT':'sandbox'},
    {PREFIX+'PARENT_ID':'*'},{PREFIX+'OWNER_SHA256':'x'},{PREFIX+'REQUEST_ID':'not-a-uuid'},{PREFIX+'VALID_UNTIL':'tomorrow'},
    {'RENDER_HOSTED_PRODUCTION_CHECKOUT_ENABLED':'false'}]:
   values={**valid,**changes}
   with patch('apps.billing.complimentary.grant_access',side_effect=AssertionError('No service allowed')) as service:
    with self.assertRaises(ComplimentaryStartupRejected):apply_startup_operation(values)
    service.assert_not_called()
   self.assertFalse(any(k.startswith(PREFIX) for k in values))


@override_settings(**HOSTED)
class ComplimentarySafeRejectionTests(TestCase):
 def test_financial_and_expiry_refusal_codes_are_static_and_stripped(self):
  parent=make_parent('safe-refusal');args=dict(parent_id=parent.pk,environment='production',request_reference=str(uuid4()),owner_sha256=owner_fingerprint(parent),
   valid_until=timezone.now()+timedelta(days=29),authorized_by='user_request',reason_code=REASON)
  ready(parent,HostedFixture())
  output=[];values={**context(),**{PREFIX+k:v for k,v in {'OPERATION':'grant','PARENT_ID':str(parent.pk),'ENVIRONMENT':'production',
   'REQUEST_ID':args['request_reference'],'OWNER_SHA256':args['owner_sha256'],'VALID_UNTIL':args['valid_until'].isoformat(),
   'AUTHORIZED_BY':'user_request','REASON':REASON}.items()}}
  with self.assertRaises(ComplimentaryStartupRejected) as error:apply_startup_operation(values,output=output.append)
  self.assertEqual(error.exception.safe_code,'unresolved_financial_work')
  self.assertEqual(output,['KK_COMPLIMENTARY_ACCESS_REFUSED reason=unresolved_financial_work'])
  self.assertNotIn(parent.email,str(output));self.assertFalse(any(k.startswith(PREFIX) for k in values))
  with self.assertRaises(ComplimentaryRejected) as error:grant_access(**{**args,'valid_until':timezone.now()+timedelta(days=31)},apply=True)
  self.assertEqual(error.exception.safe_code,'invalid_expiry')
