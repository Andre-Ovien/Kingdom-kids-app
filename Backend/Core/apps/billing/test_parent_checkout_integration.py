"""Real Django login/quote/reserve/confirm/status path; mocked Square only."""
from datetime import timedelta
from unittest.mock import patch

from django.core.cache import cache
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from .models import SquareBillingTerm, ParentContentEntitlement
from .test_checkout import PASSWORD, make_parent
from .test_modern_web import ModernWebFixture, CHARGE_SOURCE
from .test_parent_checkout_web import WEB


@override_settings(**WEB)
class ParentCheckoutIntegrationTests(TestCase):
    base = '/api/billing/square/checkout-intents/'

    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)

    def begin(self, period='monthly', provider=None):
        parent = make_parent('website-' + period)
        client = APIClient(HTTP_HOST='checkout.example.test')
        provider = provider or ModernWebFixture()
        login = client.post('/api/accounts/login/', {'email': parent.email, 'password': PASSWORD}, format='json')
        self.assertEqual(login.status_code, 200)
        client.credentials(HTTP_AUTHORIZATION='Bearer ' + login.data['access'])
        self.assertEqual(client.get('/api/billing/content-access/').data['access_state'], 'unpaid')
        with patch('apps.billing.views.configured_client', return_value=provider):
            quote = client.get(self.base, {'billing_period': period})
            self.assertEqual(quote.status_code, 200)
            self.assertIsNone(quote.data['first_renewal_at'])
            consent = {'password': PASSWORD, 'accepted': True, 'billing_period': period,
                       'disclosure_version': quote.data['disclosure_version'],
                       'disclosure_sha256': quote.data['disclosure_sha256']}
            reserve = client.post(self.base, consent, format='json')
            self.assertEqual(reserve.status_code, 200)
        return parent, client, provider, reserve.data['id'], consent

    def checkout(self, period):
        parent, client, provider, intent_id, _ = self.begin(period)
        with patch('apps.billing.views.configured_client', return_value=provider):
            confirm = client.post(self.base + intent_id + '/confirm/',
                                  {'password': PASSWORD, 'charge_source_id': CHARGE_SOURCE}, format='json')
            self.assertEqual(confirm.status_code, 200)
            recover = client.post(self.base + intent_id + '/confirm/', {'password': PASSWORD}, format='json')
            self.assertEqual(recover.status_code, 200)
        after = client.get('/api/billing/content-access/')
        self.assertEqual(after.status_code, 200)
        self.assertEqual(after.data['access_state'], 'paid')
        self.assertEqual(after.data['parent_id'], str(parent.pk))
        self.assertEqual(len(provider.modern_requests), 1)
        term = SquareBillingTerm.objects.get(agreement__parent=parent)
        grant = ParentContentEntitlement.objects.get(parent=parent)
        self.assertEqual(after.data['access_until'], grant.valid_until.isoformat())
        self.assertEqual(term.valid_from, term.captured_at)
        return term

    def test_monthly_verified_parent_flow_grants_exact_30day_capture_period(self):
        term = self.checkout('monthly')
        self.assertEqual(term.amount_minor, 999)
        self.assertEqual(term.valid_until-term.captured_at, timedelta(days=30))

    def test_yearly_verified_parent_flow_grants_9990_calendar_year(self):
        from .coverage import coverage_end
        term = self.checkout('yearly')
        self.assertEqual(term.amount_minor, 9990)
        self.assertEqual(term.valid_until, coverage_end(term.captured_at, 'calendar_year_1', 'America/New_York'))

    def test_canonical_failed_payment_offers_only_explicit_guarded_restart(self):
        parent, client, provider, old_id, consent = self.begin()
        provider.payment_status = 'FAILED'
        with patch('apps.billing.views.configured_client', return_value=provider):
            failed = client.post(self.base+old_id+'/confirm/',
                                 {'password': PASSWORD, 'charge_source_id': CHARGE_SOURCE}, format='json')
            self.assertEqual(failed.status_code, 200)
            status = client.get('/api/billing/content-access/')
            self.assertEqual(status.data['access_state'], 'unpaid')
            self.assertTrue(status.data['purchase_recovery']['restart_allowed'])
            restart = client.post(self.base+old_id+'/restart/', consent, format='json')
            self.assertEqual(restart.status_code, 200)
            new_id = restart.data['id']
            self.assertNotEqual(new_id, old_id)
            self.assertEqual(len(provider.modern_requests), 1)  # Restart did not charge.
            provider.payment_status = 'COMPLETED'
            paid = client.post(self.base+new_id+'/confirm/',
                               {'password': PASSWORD, 'charge_source_id': CHARGE_SOURCE+'-fresh'}, format='json')
            self.assertEqual(paid.status_code, 200)
        self.assertEqual(client.get('/api/billing/content-access/').data['access_state'], 'paid')
        self.assertEqual(ParentContentEntitlement.objects.filter(parent=parent).count(), 1)
        self.assertEqual(len(provider.modern_requests), 2)  # One failed, one explicitly new payment.

    def test_paid_but_card_setup_failed_stays_paid_and_recovers_without_new_charge(self):
        provider = ModernWebFixture(); provider.reject_card_storage = True
        _, client, provider, intent_id, _ = self.begin(provider=provider)
        with patch('apps.billing.views.configured_client', return_value=provider):
            uncertain = client.post(self.base+intent_id+'/confirm/',
                                    {'password': PASSWORD, 'charge_source_id': CHARGE_SOURCE}, format='json')
            self.assertEqual(uncertain.status_code, 503)
            paid = client.get('/api/billing/content-access/')
            self.assertEqual(paid.data['access_state'], 'paid')
            self.assertTrue(paid.data['purchase_recovery']['setup_required'])
            self.assertFalse(paid.data['purchase_recovery']['renewals_ready'])
            provider.reject_card_storage = False
            recover = client.post(self.base+intent_id+'/confirm/', {'password': PASSWORD}, format='json')
            self.assertEqual(recover.status_code, 200)
        ready = client.get('/api/billing/content-access/')
        self.assertEqual(ready.data['access_state'], 'paid')
        self.assertTrue(ready.data['purchase_recovery']['renewals_ready'])
        self.assertFalse(ready.data['purchase_recovery']['setup_required'])
        self.assertEqual(len(provider.modern_requests), 1)
