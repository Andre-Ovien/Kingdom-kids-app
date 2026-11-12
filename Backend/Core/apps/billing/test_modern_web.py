"""Modern Web CHARGE_AND_STORE contract; synthetic provider responses only."""
from copy import deepcopy
from datetime import timedelta
from unittest.mock import Mock, patch
from uuid import uuid4
from django.core.exceptions import ValidationError
from django.test import TestCase, SimpleTestCase, override_settings
from django.utils import timezone
from .checkout import CheckoutRejected, CheckoutConflict, checkout_status
from .client import SquareSandboxClient, SquareHttpResult, SquareClientError
from .models import (SquareBillingTerm, SquareContentAgreement, SquarePaymentCardBinding,
                     ParentContentEntitlement, SquareCheckoutIntent, SquareWebhookReceipt)
from .serializers import TermCheckoutCardSerializer
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, make_parent
from .test_terms import TermFixtureSquare, make_term_intent
from .terms import confirm_term_checkout, activate_payment_card, cancel_agreement, prepare_due_term
from .reconciliation import process_receipt

CHARGE_SOURCE = 'cnon:synthetic-charge-and-store-only'

class ModernWebFixture(TermFixtureSquare):
    def __init__(self):
        super().__init__(); self.modern_requests = []; self.stored_cards = {}
        self.lose_card_response = False; self.reject_card_storage = False
    def create_term_payment(self, **kwargs):
        self.modern_requests.append(deepcopy(kwargs))
        try: return super().create_term_payment(**kwargs)
        finally:
            key = 'payment-' + str(kwargs['term_id'])
            if key in self.payments:
                self.payments[key]['card_details']['entry_method'] = 'KEYED'
                self.payments[key]['card_details']['card'] = {'fingerprint':'synthetic-fingerprint'}
    def create_card_from_payment(self, **kwargs):
        self.calls.append(('store-payment-card', kwargs['idempotency_key'], kwargs['payment_id']))
        if self.reject_card_storage: raise SquareClientError('Synthetic no card storage received')
        card = {'id':'ccof:'+str(kwargs['term_id']), 'customer_id':kwargs['customer_id'], 'enabled':True,
            'merchant_id':'merchant-test', 'reference_id':str(kwargs['term_id']), 'fingerprint':'synthetic-fingerprint'}
        self.stored_cards[card['id']] = card
        if self.lose_card_response: raise SquareClientError('Synthetic accepted card response lost')
        return card['id']
    def list_cards(self, **kwargs):
        self.calls.append(('list-cards',kwargs['customer_id']))
        return {'cards':deepcopy(list(self.stored_cards.values()))}
    def retrieve_card(self, identifier):
        return deepcopy(self.stored_cards[identifier]) if identifier in self.stored_cards else super().retrieve_card(identifier)

def modern_fixture(parent):
    client = ModernWebFixture(); intent = make_term_intent(parent,client)
    confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
    return intent,client,SquareBillingTerm.objects.get(agreement__intent_reference=intent.pk)

@override_settings(**CHECKOUT_CONFIG)
class ModernWebTests(TestCase):
    def setUp(self): self.parent=make_parent()
    def test_exact_initial_payment_saved_instrument_and_immutable_future_renewal(self):
        intent,client,initial=modern_fixture(self.parent);binding=SquarePaymentCardBinding.objects.get()
        self.assertEqual((binding.source_term_id,binding.payment_id),(initial.pk,initial.payment_id))
        self.assertEqual((initial.card_id,initial.payment_source_mode),('','web_charge_and_store'))
        self.assertEqual(client.modern_requests[0]['charge_source_id'],CHARGE_SOURCE)
        self.assertIsNone(client.modern_requests[0]['verification_token'])
        self.assertEqual(ParentContentEntitlement.objects.get().valid_until,initial.valid_until)
        self.assertTrue(checkout_status(SquareCheckoutIntent.objects.get(pk=intent.pk))['renewals_ready'])
        self.assertFalse(any(c[0] in {'create-card','create-subscription'} for c in client.calls))
        with patch('apps.billing.terms.timezone.now',return_value=initial.valid_until+timedelta(seconds=1)):
            renewal=prepare_due_term(agreement_id=initial.agreement_id)
        self.assertEqual(renewal.card_id,binding.card_id);self.assertEqual(renewal.payment_source_mode,'saved_card')
        self.assertFalse(renewal.buyer_present)
        for row in [initial,initial.agreement,binding,SquareCheckoutIntent.objects.get(pk=intent.pk)]:
            self.assertNotIn(CHARGE_SOURCE,repr(row.__dict__))
        binding.card_id='foreign'
        with self.assertRaises(ValidationError):binding.save()
    def test_card_failure_preserves_paid_access_no_renewal_until_same_payment_retry(self):
        client=ModernWebFixture();client.reject_card_storage=True;intent=make_term_intent(self.parent,client)
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        self.assertEqual(SquareBillingTerm.objects.get().state,'paid');self.assertEqual(ParentContentEntitlement.objects.count(),1)
        self.assertIsNone(SquareContentAgreement.objects.get().activated_at)
        status=checkout_status(SquareCheckoutIntent.objects.get(pk=intent.pk))
        self.assertEqual(status['card_storage_state'],'pending');self.assertFalse(status['renewals_ready'])
        client.reject_card_storage=False
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client)
        self.assertEqual(len(client.modern_requests),1)
        calls=[c for c in client.calls if c[0]=='store-payment-card'];self.assertEqual(calls[0][1:],calls[1][1:])
        self.assertEqual(SquarePaymentCardBinding.objects.count(),1)
    def test_accepted_lost_card_response_recovers_without_second_storage_or_charge(self):
        client=ModernWebFixture();client.lose_card_response=True;intent=make_term_intent(self.parent,client)
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        client.lose_card_response=False
        SquareCheckoutIntent.objects.filter(pk=intent.pk).update(consented_at=timezone.now()-timedelta(hours=1))
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client)
        self.assertEqual(len(client.modern_requests),1)
        self.assertEqual(len([c for c in client.calls if c[0]=='store-payment-card']),1)
        self.assertIsNotNone(SquareContentAgreement.objects.get().activated_at)
    def test_lost_charge_receipt_grants_only_term_then_parent_retry_stores_same_payment(self):
        client=ModernWebFixture();client.timeout_payment=True;intent=make_term_intent(self.parent,client)
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        term=SquareBillingTerm.objects.get()
        receipt=SquareWebhookReceipt.objects.create(merchant_id='merchant-test',event_id='modern-lost',event_type='payment.updated',
            object_id='payment-'+str(term.pk),body_sha256='d'*64)
        self.assertEqual(process_receipt(receipt_id=receipt.pk,client=client),'processed')
        self.assertEqual(ParentContentEntitlement.objects.count(),1);self.assertFalse(SquarePaymentCardBinding.objects.exists())
        self.assertIsNone(SquareContentAgreement.objects.get().activated_at);client.timeout_payment=False
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client)
        self.assertEqual(len(client.modern_requests),1)
        self.assertEqual(SquarePaymentCardBinding.objects.get().payment_id,'payment-'+str(term.pk))
    def test_invalid_or_replaced_modern_source_cannot_dispatch_or_mix_legacy(self):
        client=ModernWebFixture();intent=make_term_intent(self.parent,client)
        for value in ['', 'ccof:arbitrary-card','cnon:bad token']:
            with self.assertRaises(CheckoutRejected):
                confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=value,client=client)
        self.assertFalse(any(c[0].startswith('create-') for c in client.calls))
        client.create_term_payment=Mock(side_effect=SquareClientError('Synthetic not received'))
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        with self.assertRaises(CheckoutConflict):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id='cnon:different-source',client=client)
        self.assertEqual(client.create_term_payment.call_count,1)
        serializer=TermCheckoutCardSerializer(data={'password':PASSWORD,'charge_source_id':CHARGE_SOURCE,'verification_token':'verf:mix'})
        self.assertFalse(serializer.is_valid())
    def test_stale_initial_consent_never_dispatches_first_modern_payment(self):
        client=ModernWebFixture();intent=make_term_intent(self.parent,client)
        client.create_term_payment=Mock(side_effect=SquareClientError('Synthetic never received'))
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        with patch('apps.billing.terms.timezone.now',return_value=timezone.now()+timedelta(minutes=11)):
            with self.assertRaises(CheckoutRejected):
                confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        self.assertEqual(client.create_term_payment.call_count,1)
    def test_old_or_on_file_source_payment_never_creates_recurring_card(self):
        for key,value in [('entry_method','ON_FILE'),('created_at',(timezone.now()-timedelta(hours=25)).isoformat())]:
            parent=make_parent(key);client=ModernWebFixture();client.reject_card_storage=True;intent=make_term_intent(parent,client)
            with self.assertRaises(SquareClientError):
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
            term=SquareBillingTerm.objects.get(agreement__parent=parent);
            if key == 'created_at': client.payments[term.payment_id]['card_details']['card_payment_timeline']['authorized_at']=value
            else: client.payments[term.payment_id]['card_details'][key]=value
            client.calls.clear()
            with self.assertRaises(CheckoutRejected):activate_payment_card(term_id=term.pk,client=client)
            self.assertFalse(any(c[0]=='store-payment-card' for c in client.calls))
            self.assertIsNone(SquareContentAgreement.objects.get(parent=parent).activated_at)
        self.assertEqual(ParentContentEntitlement.objects.count(),2)
    def test_wrong_card_owner_reference_or_disabled_never_activates(self):
        for field,value in [('customer_id','foreign-customer'),('reference_id',str(uuid4())),('enabled',False)]:
            parent=make_parent(field);client=ModernWebFixture();intent=make_term_intent(parent,client);original=client.retrieve_card
            def bad(identifier,_field=field,_value=value):
                card=original(identifier);card[_field]=_value;return card
            client.retrieve_card=bad
            with self.assertRaises(CheckoutRejected):
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
            self.assertFalse(SquarePaymentCardBinding.objects.filter(agreement__parent=parent).exists())
            self.assertIsNone(SquareContentAgreement.objects.get(parent=parent).activated_at)
    def test_cancel_or_delete_during_paid_card_save_never_reactivates(self):
        for action in ['cancel','delete']:
            parent=make_parent(action);client=ModernWebFixture();intent=make_term_intent(parent,client);original=client.create_card_from_payment
            def stopped(_action=action,_parent=parent,_intent=intent,_original=original,**kwargs):
                card_id=_original(**kwargs)
                if _action=='cancel':cancel_agreement(parent=_parent,intent_id=_intent.pk,password=PASSWORD)
                else:type(_parent).objects.get(pk=_parent.pk).delete()
                return card_id
            client.create_card_from_payment=stopped
            with self.assertRaises((CheckoutRejected,SquareClientError)):
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
            agreement=SquareContentAgreement.objects.get(intent_reference=intent.pk)
            self.assertFalse(agreement.renewals_enabled);self.assertIsNone(agreement.activated_at)
            self.assertFalse(SquarePaymentCardBinding.objects.filter(agreement=agreement).exists())

    def test_paid_initial_card_recovery_after_period_end_does_not_extend_old_term(self):
        from datetime import datetime, timezone as utc
        before=datetime(2026,11,28,4,59,tzinfo=utc.utc)  # NewYork27th23:59.
        client=ModernWebFixture();client.lose_card_response=True
        with patch('apps.billing.terms.timezone.now',return_value=before):
            intent=make_term_intent(self.parent,client)
            with self.assertRaises(SquareClientError):
                confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,
                    charge_source_id=CHARGE_SOURCE,client=client)
        first=SquareBillingTerm.objects.get();original_end=first.valid_until
        client.lose_card_response=False
        with patch('apps.billing.terms.timezone.now',return_value=original_end+timedelta(minutes=2)):
            confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client)
            second=prepare_due_term(agreement_id=first.agreement_id)
        self.assertEqual(ParentContentEntitlement.objects.get().valid_until,original_end)
        self.assertEqual(second.request_not_before,original_end)
        self.assertIsNone(second.valid_from)
        self.assertEqual(len(client.modern_requests),1)
        self.assertEqual(len([c for c in client.calls if c[0]=='store-payment-card']),1)
        self.assertTrue(SquareContentAgreement.objects.get().activated_at)

    def test_missing_authorization_timeline_and_conflicting_recovered_fingerprint_fail_closed(self):
        for defect in ['timeline', 'fingerprint', 'ambiguous']:
            parent=make_parent(defect);client=ModernWebFixture();client.lose_card_response=True
            intent=make_term_intent(parent,client)
            with self.assertRaises(SquareClientError):
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
            term=SquareBillingTerm.objects.get(agreement__parent=parent)
            if defect=='timeline':
                client.stored_cards.clear()
                client.payments[term.payment_id]['card_details'].pop('card_payment_timeline')
                # The stale overview's undocumented field must not establish authorization age.
                client.payments[term.payment_id]['card_details']['created_at']=timezone.now().isoformat()
            elif defect=='fingerprint':
                for card in client.stored_cards.values():card['fingerprint']='different-instrument'
            else:
                card=deepcopy(next(iter(client.stored_cards.values())));card['id']='ccof:ambiguous'
                client.stored_cards[card['id']]=card
            client.calls.clear()
            with self.assertRaises(CheckoutRejected):activate_payment_card(term_id=term.pk,client=client)
            self.assertFalse(any(c[0]=='store-payment-card' for c in client.calls))
            self.assertFalse(SquarePaymentCardBinding.objects.filter(agreement__parent=parent).exists())
            self.assertIsNone(SquareContentAgreement.objects.get(parent=parent).activated_at)
        self.assertEqual(ParentContentEntitlement.objects.count(),3)

@override_settings(**CHECKOUT_CONFIG)
class ModernWebClientTests(SimpleTestCase):
    def test_modern_payment_source_and_exact_payment_card_source_http_contract(self):
        import json
        transport=Mock();transport.send.return_value=SquareHttpResult(200,b'{"payment":{"id":"payment-test"}}')
        client=SquareSandboxClient(transport=transport);term_id,key=uuid4(),uuid4()
        client.create_term_payment(term_id=term_id,location_id='location-test',customer_id='customer-test',card_id='',
            idempotency_key=key,buyer_present=True,charge_source_id=CHARGE_SOURCE)
        payload=json.loads(transport.send.call_args.kwargs['body'])
        self.assertEqual(payload['source_id'],CHARGE_SOURCE);self.assertNotIn('verification_token',payload)
        self.assertEqual(payload['reference_id'],str(term_id));self.assertEqual(payload['idempotency_key'],str(key))
        self.assertEqual(payload['amount_money'],{'amount':999,'currency':'USD'})
        self.assertTrue(payload['autocomplete']);self.assertTrue(payload['customer_details']['customer_initiated'])
        transport.send.return_value=SquareHttpResult(200,json.dumps({'card':{'id':'ccof:own','customer_id':'customer-test',
            'reference_id':str(term_id),'enabled':True}}).encode())
        client.create_card_from_payment(customer_id='customer-test',payment_id='payment-test',term_id=term_id,idempotency_key=key)
        payload=json.loads(transport.send.call_args.kwargs['body'])
        self.assertEqual(payload['source_id'],'payment-test')
        self.assertEqual(payload['card'],{'customer_id':'customer-test','reference_id':str(term_id)})
        self.assertNotIn(CHARGE_SOURCE,repr(payload))

    def test_mixed_modern_client_proof_never_sends(self):
        client=SquareSandboxClient(transport=Mock())
        for extra in [{'verification_token':'verf:mixed'}, {'card_id':'ccof:other'}]:
            args={'term_id':uuid4(),'location_id':'location-test','customer_id':'customer-test','card_id':'',
                'idempotency_key':uuid4(),'buyer_present':True,'charge_source_id':CHARGE_SOURCE}
            args.update(extra)
            with self.assertRaises(SquareClientError):client.create_term_payment(**args)
        client.transport.send.assert_not_called()
