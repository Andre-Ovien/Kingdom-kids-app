"""Isolated PostgreSQL guards across yearly/monthly purchase choices."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest.mock import patch
from django.test import TransactionTestCase, override_settings, skipUnlessDBFeature
from .checkout import CheckoutConflict, CheckoutRejected
from .models import SquareCheckoutIntent, SquareBillingTerm
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, make_parent
from .test_checkout_concurrency import isolated
from .test_modern_web import ModernWebFixture, CHARGE_SOURCE
from .test_annual_terms import annual_intent
from .terms import reserve_term_checkout, term_disclosure, confirm_term_checkout, prepare_due_term

@override_settings(**CHECKOUT_CONFIG)
@skipUnlessDBFeature('has_select_for_update')
class AnnualPlanPostgresRaces(TransactionTestCase):
    def setUp(self):self.parent=make_parent()
    def test_simultaneous_monthly_and_yearly_choices_one_open_purchase_no_payment(self):
        client=ModernWebFixture();start=Barrier(2)
        def reserve(period):
            quote=term_disclosure('America/New_York',billing_period=period);start.wait(10)
            try:
                return reserve_term_checkout(parent=self.parent,password=PASSWORD,accepted=True,billing_period=period,
                    disclosure_version=quote['disclosure_version'],disclosure_sha256=quote['disclosure_sha256'],client=client)
            except CheckoutConflict:return None
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(isolated,lambda p=p:reserve(p)) for p in ['monthly','yearly']]
            outcomes=[f.result(15) for f in futures]
        self.assertEqual(sum(o is not None for o in outcomes),1)
        self.assertEqual(SquareCheckoutIntent.objects.filter(is_open=True).count(),1)
        self.assertFalse(SquareBillingTerm.objects.exists());self.assertFalse(client.modern_requests)
    def test_simultaneous_yearly_renewal_materialization_one_exact_future_term(self):
        client=ModernWebFixture();intent=annual_intent(self.parent,client)
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client)
        initial=SquareBillingTerm.objects.get();start=Barrier(2)
        def renew():
            start.wait(10)
            try:return prepare_due_term(agreement_id=initial.agreement_id)
            except CheckoutRejected:return None
        with patch('apps.billing.terms.timezone.now',return_value=initial.valid_until):
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures=[pool.submit(isolated,renew) for _ in range(2)]
                outcomes=[f.result(15) for f in futures]
        self.assertEqual(len({o.pk for o in outcomes}),1)
        term=SquareBillingTerm.objects.exclude(pk=initial.pk).get()
        self.assertEqual((term.request_not_before,term.amount_minor,term.cadence),(initial.valid_until,9990,'ANNUAL'))
        self.assertIsNone(term.valid_from);self.assertIsNone(term.valid_until)
        self.assertEqual(len(client.modern_requests),1)
