"""Historical28-day request/financial proofs remain readable and refundable only."""
from datetime import timedelta
from django.test import TestCase,override_settings
from django.utils import timezone
from .checkout import fingerprint,CheckoutRejected
from .models import SquareCheckoutIntent,SquareContentAgreement,SquareBillingTerm,ParentContentEntitlement
from .plans import POLICY_SHA256,ALL_CONTENT_FEATURE
from .test_checkout import CHECKOUT_CONFIG,PASSWORD,make_parent
from .test_terms import TermFixtureSquare
from .terms import frozen_term_hash,next_anchor,reconcile_term,confirm_term_checkout,prepare_due_term,term_reference


def old_term_fixture(parent):
    now=timezone.now();start=now-timedelta(days=1);end=next_anchor(start,'America/New_York')
    intent=SquareCheckoutIntent.objects.create(parent=parent,checkout_mode='payments',merchant_id='merchant-test',
        location_id='location-test',variation_id='',policy_id='all-content-monthly-usd-999-v1',policy_sha256=POLICY_SHA256,
        disclosure_version='usd999-app-terms-28-v1',disclosure_sha256='a'*64,billing_timezone='America/New_York',
        consented_at=start,reauthenticated_at=start,request_sha256='b'*64)
    agreement=SquareContentAgreement.objects.create(parent=parent,intent=intent,intent_reference=intent.pk,
        merchant_id='merchant-test',location_id='location-test',customer_id='old-customer',card_id='old-card',
        policy_id=intent.policy_id,policy_sha256=POLICY_SHA256,disclosure_version=intent.disclosure_version,
        disclosure_sha256=intent.disclosure_sha256,billing_timezone='America/New_York',consented_at=start,next_term_start=end)
    term=SquareBillingTerm(agreement=agreement,valid_from=start,valid_until=end,customer_id='old-customer',
        card_id='old-card',location_id='location-test',buyer_present=True,payment_id='old-payment',state='paid')
    # Exact pre0008 request shape: no duration/capture fields were present.
    old={'term_id':str(term.pk),'agreement':str(agreement.pk),'policy':POLICY_SHA256,'merchant':'merchant-test',
        'location':'location-test','customer':'old-customer','card':'old-card','valid_from':start.isoformat(),
        'valid_until':end.isoformat(),'amount':999,'currency':'USD','timezone':'America/New_York',
        'buyer_present':True,'verification_sha256':'','provider_key':str(term.provider_idempotency_key)}
    term.request_sha256=fingerprint(old);term.save(force_insert=True)
    assert frozen_term_hash(term,agreement)==term.request_sha256
    client=TermFixtureSquare();stamp=now.isoformat()
    client.payments['old-payment']={'id':'old-payment','reference_id':str(term.pk),'customer_id':term.customer_id,
        'location_id':term.location_id,'source_type':'CARD','status':'COMPLETED','updated_at':stamp,'created_at':stamp,
        'version_token':'old-v1','amount_money':{'amount':999,'currency':'USD'},'refunded_money':{'amount':0,'currency':'USD'},'refund_ids':[]}
    return intent,term,client


@override_settings(**CHECKOUT_CONFIG)
class HistoricalCaptureTests(TestCase):
    def setUp(self):self.parent=make_parent()
    def test_old_hash_read_and_same_timestamp_new_capture_field_does_not_grant_or_rewrite(self):
        intent,term,client=old_term_fixture(self.parent);before=(term.valid_from,term.valid_until,term.request_sha256)
        reconcile_term(term_id=term.pk,client=client)
        client.payments['old-payment']['card_details']={'status':'CAPTURED','card_payment_timeline':{'captured_at':timezone.now().isoformat()}}
        reconcile_term(term_id=term.pk,client=client)
        term.refresh_from_db();self.assertEqual((term.valid_from,term.valid_until,term.request_sha256),before)
        self.assertIsNone(term.captured_at);self.assertFalse(ParentContentEntitlement.objects.exists())
        with self.assertRaises(CheckoutRejected):prepare_due_term(agreement_id=term.agreement_id)
        client.calls.clear()
        with self.assertRaises(CheckoutRejected):confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client)
        self.assertEqual(client.calls,[])
    def test_old_existing_proof_full_refund_revokes_only_unchanged_original_interval(self):
        _intent,term,client=old_term_fixture(self.parent)
        grant=ParentContentEntitlement.objects.create(parent=self.parent,feature_code=ALL_CONTENT_FEATURE,provider='square',
            environment='sandbox',provider_account_id='merchant-test',source_reference=term_reference(term.pk),
            valid_from=term.valid_from,valid_until=term.valid_until,payment_verified_at=timezone.now())
        reconcile_term(term_id=term.pk,client=client)
        stamp=(timezone.now()+timedelta(seconds=1)).isoformat();client.payments['old-payment'].update(version_token='old-v2',
            updated_at=stamp,refund_ids=['old-refund'],refunded_money={'amount':999,'currency':'USD'})
        client.refunds['old-refund']={'id':'old-refund','payment_id':'old-payment','location_id':'location-test','status':'COMPLETED',
            'updated_at':stamp,'amount_money':{'amount':999,'currency':'USD'}}
        self.assertEqual(reconcile_term(term_id=term.pk,client=client),'refunded')
        grant.refresh_from_db();self.assertIsNotNone(grant.revoked_at)
        self.assertEqual((grant.valid_from,grant.valid_until),(term.valid_from,term.valid_until))
