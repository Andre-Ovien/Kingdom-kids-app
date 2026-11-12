"""Real PostgreSQL lock races with synthetic checkout capabilities only."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.db import connections, transaction
from django.test import TransactionTestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone
from rest_framework.test import APIRequestFactory

from .browser_handoff import HandoffUnavailable, issue_handoff, redeem_handoff
from .handoff_models import ParentCheckoutHandoff


ORIGIN = 'https://checkout.example.test'


def isolated(operation):
    connections.close_all()
    try:
        return operation()
    finally:
        connections.close_all()


@override_settings(PARENT_CHECKOUT_HANDOFF_ENABLED=True, SQUARE_ENVIRONMENT='sandbox',
    PARENT_CHECKOUT_ORIGIN=ORIGIN, ALLOWED_HOSTS=['checkout.example.test'], SECURE_SSL_REDIRECT=False)
@skipUnlessDBFeature('has_select_for_update_of')
class HandoffPostgresRaces(TransactionTestCase):
    def setUp(self):
        self.parent = get_user_model().objects.create_user(email='concurrent-checkout@example.test',
            password='synthetic-parent-password', email_verified_at=timezone.now())
        public = patch('apps.billing.parent_checkout_web.public_checkout_configuration',
            return_value={'environment': 'sandbox', 'origin': ORIGIN})
        capability = patch('apps.billing.parent_checkout_web.checkout_capability', return_value={'state': 'available'})
        public.start(); capability.start()
        self.addCleanup(public.stop); self.addCleanup(capability.stop)
        self.value = issue_handoff(parent=self.parent, purpose='purchase', billing_period='monthly',
            access_expiry=int((timezone.now()+timedelta(minutes=15)).timestamp()))

    def redeem(self):
        request = APIRequestFactory().post('/api/billing/checkout-handoffs/redeem/',
            secure=True, HTTP_HOST='checkout.example.test', HTTP_ORIGIN=ORIGIN)
        return redeem_handoff(code=self.value['code'], request=request)

    def test_two_parallel_redeems_have_exactly_one_winner(self):
        barrier = Barrier(2)
        def attempt():
            barrier.wait(timeout=10)
            try:
                result = self.redeem()
                self.assertEqual(result['parent']['id'], str(self.parent.pk))
                return 'redeemed'
            except HandoffUnavailable:
                return 'consumed'
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(isolated, attempt) for _ in range(2)]
            outcomes = [future.result(timeout=15) for future in futures]
        self.assertCountEqual(outcomes, ['redeemed', 'consumed'])
        row = ParentCheckoutHandoff.objects.get()
        self.assertIsNotNone(row.consumed_at)
        self.assertIsNotNone(row.session_expires_at)

    def test_redeem_does_not_wait_for_parent_row_lock(self):
        # Issuance/deletion can hold parent -> handoff locks. Redemption must
        # lock only its own row, never join-lock parent in the opposite order.
        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                get_user_model().objects.select_for_update().get(pk=self.parent.pk)
                future = pool.submit(isolated, self.redeem)
                result = future.result(timeout=5)
                self.assertEqual(result['parent']['id'], str(self.parent.pk))
        self.assertIsNotNone(ParentCheckoutHandoff.objects.get().consumed_at)
