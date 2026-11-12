"""PostgreSQL-only modern Web payment/card handoff races, synthetic I/O."""
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from django.db import connections
from django.test import TransactionTestCase, override_settings, skipUnlessDBFeature
from .checkout import CheckoutBusy, CheckoutRejected
from .client import SquareClientError
from .models import ParentContentEntitlement, SquarePaymentCardBinding, SquareContentAgreement
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, make_parent
from .test_checkout_concurrency import isolated
from .test_modern_web import ModernWebFixture, CHARGE_SOURCE
from .test_terms import make_term_intent
from .terms import confirm_term_checkout, cancel_agreement

@override_settings(**CHECKOUT_CONFIG)
@skipUnlessDBFeature('has_select_for_update')
class ModernWebPostgresRaces(TransactionTestCase):
    def setUp(self):self.parent=make_parent()
    def test_parallel_confirmations_single_charge_single_bound_card_and_no_io_under_atomic(self):
        client=ModernWebFixture();intent=make_term_intent(self.parent,client);atomic=[]
        for name in [n for n in dir(client) if n.startswith(('create_','retrieve_','list_'))]:
            original=getattr(client,name)
            def checked(*a,_original=original,**kw):
                atomic.append(connections['default'].in_atomic_block);return _original(*a,**kw)
            setattr(client,name,checked)
        entered,proceed=Event(),Event();original=client.create_term_payment
        def held(**kw):
            entered.set()
            if not proceed.wait(10):raise AssertionError('Synthetic payment release timed out')
            return original(**kw)
        client.create_term_payment=held
        def confirm():return confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,
            charge_source_id=CHARGE_SOURCE,client=client)
        with ThreadPoolExecutor(max_workers=1) as pool:
            first=pool.submit(isolated,confirm);self.assertTrue(entered.wait(10))
            try:
                with self.assertRaises(CheckoutBusy):confirm()
            finally:proceed.set()
            first.result(15)
        self.assertEqual(len(client.modern_requests),1);self.assertEqual(SquarePaymentCardBinding.objects.count(),1)
        self.assertEqual(ParentContentEntitlement.objects.count(),1);self.assertTrue(atomic);self.assertFalse(any(atomic))
    def test_cancel_during_remote_card_save_prevents_activation_after_response(self):
        client=ModernWebFixture();intent=make_term_intent(self.parent,client)
        entered,proceed=Event(),Event();original=client.create_card_from_payment
        def held(**kw):
            result=original(**kw);entered.set()
            if not proceed.wait(10):raise AssertionError('Synthetic storage release timed out')
            return result
        client.create_card_from_payment=held
        with ThreadPoolExecutor(max_workers=1) as pool:
            first=pool.submit(isolated,lambda:confirm_term_checkout(parent=self.parent,intent_id=intent.pk,
                password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client))
            self.assertTrue(entered.wait(10))
            try:cancel_agreement(parent=self.parent,intent_id=intent.pk,password=PASSWORD)
            finally:proceed.set()
            with self.assertRaises((CheckoutRejected,SquareClientError)):first.result(15)
        agreement=SquareContentAgreement.objects.get();self.assertFalse(agreement.renewals_enabled)
        self.assertIsNone(agreement.activated_at);self.assertFalse(SquarePaymentCardBinding.objects.exists())
        self.assertEqual(ParentContentEntitlement.objects.count(),1)
        self.assertEqual(len(client.modern_requests),1)
