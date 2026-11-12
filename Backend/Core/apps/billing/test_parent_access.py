"""Isolated parent-access discovery tests; no provider or runtime requests."""
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from django.core.cache import cache
from django.db import DatabaseError
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from .access_status import parent_content_access
from .models import ParentContentEntitlement, SquareCheckoutIntent
from .plans import ALL_CONTENT_FEATURE
from .term_plans import MONTHLY_POLICY_ID, YEARLY_POLICY_ID
from .test_checkout import make_parent


@override_settings(PARENT_CONTENT_ACCESS_STATUS_ENABLED=True,
                   PARENT_CHECKOUT_SANDBOX_ENABLED=False,
                   SQUARE_SANDBOX_TEST_PARENT_IDS=','.join(str(value) for value in range(1, 101)),
                   PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='sandbox',
                   PAID_CONTENT_ENFORCEMENT_ENABLED=False)
class ParentAccessTests(TestCase):
    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        self.parent = make_parent('access'); self.other = make_parent('other-access')
        self.now = timezone.now()

    def proof(self, **changes):
        data = dict(parent=self.parent, provider='square', environment='sandbox',
                    provider_account_id='merchant-fixture', source_reference='proof-fixture',
                    feature_code=ALL_CONTENT_FEATURE, valid_from=self.now-timedelta(days=1),
                    valid_until=self.now+timedelta(days=29), payment_verified_at=self.now)
        data.update(changes)
        return ParentContentEntitlement.objects.create(**data)

    def intent(self, **changes):
        data = dict(parent=self.parent, merchant_id='merchant-fixture', location_id='location-fixture',
                    policy_id=MONTHLY_POLICY_ID, policy_sha256='a'*64, disclosure_version='fixture',
                    consented_at=self.now, reauthenticated_at=self.now, request_sha256='b'*64,
                    checkout_mode='payments', billing_timezone='America/New_York')
        data.update(changes)
        return SquareCheckoutIntent.objects.create(**data)

    def test_flag_off_is_unknown_and_never_queries_or_calls_provider(self):
        with override_settings(PARENT_CONTENT_ACCESS_STATUS_ENABLED=False), self.assertNumQueries(0):
            result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unknown')
        self.assertFalse(result['content_enforcement_enabled'])
        self.assertEqual(result['checkout']['state'], 'unavailable')

    def test_rollout_bypass_does_not_masquerade_as_paid(self):
        result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unpaid')
        self.assertIsNone(result['access_until'])
        self.assertFalse(result['parent_plan_routing_enabled'])

    def test_valid_proof_is_paid_even_with_enforcement_off_and_conservative_expiry(self):
        self.proof(valid_until=self.now+timedelta(days=30))
        cap = self.now+timedelta(hours=2)
        self.proof(source_reference='second-proof', revoked_at=cap)
        with patch('apps.billing.configuration.configured_client', side_effect=AssertionError('Unexpected network')):
            result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'paid')
        self.assertEqual(result['access_until'], cap.isoformat())

    def test_other_parent_environment_future_unverified_expired_and_revoked_do_not_grant(self):
        cases = [dict(parent=self.other), dict(environment='production'),
                 dict(valid_from=self.now+timedelta(minutes=1)),
                 dict(payment_verified_at=self.now+timedelta(minutes=1)),
                 dict(valid_until=self.now), dict(revoked_at=self.now)]
        for index, changes in enumerate(cases):
            self.proof(source_reference=f'proof-{index}', **changes)
        result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unpaid')

    def test_malformed_legacy_proof_identity_is_ignored(self):
        proof = self.proof()
        ParentContentEntitlement.objects.filter(pk=proof.pk).update(source_reference='invalid proof with spaces')
        self.assertEqual(parent_content_access(self.parent, at=self.now)['access_state'], 'unpaid')

    def test_pending_owned_purchase_stays_unknown_and_reuses_its_reference(self):
        intent = self.intent()
        result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unknown')
        self.assertEqual(result['purchase_recovery']['intent_id'], str(intent.pk))
        self.assertTrue(result['purchase_recovery']['source_allowed'])
        self.assertNotIn('merchant_id', result['purchase_recovery'])
        intent.processing_lease = uuid4()
        intent.save(update_fields=('processing_lease',))
        leased = parent_content_access(self.parent, at=self.now)
        self.assertFalse(leased['purchase_recovery']['source_allowed'])

    def test_uncertain_or_multiple_purchases_never_offer_a_new_source(self):
        self.intent(state='uncertain')
        result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unknown')
        self.assertFalse(result['purchase_recovery']['source_allowed'])
        self.intent(policy_id=YEARLY_POLICY_ID)
        result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unknown')
        self.assertNotIn('intent_id', result['purchase_recovery'])

    def test_paid_proof_wins_over_uncertain_future_purchase(self):
        self.proof(); self.intent(state='uncertain')
        self.assertEqual(parent_content_access(self.parent, at=self.now)['access_state'], 'paid')

    def test_sandbox_purchase_cannot_change_production_discovery(self):
        self.intent(state='uncertain')
        with override_settings(PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='production'):
            result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unpaid')
        self.assertIsNone(result['purchase_recovery'])

    def test_database_error_is_sanitized_unknown_not_unpaid(self):
        with patch.object(ParentContentEntitlement.objects, 'filter', side_effect=DatabaseError('synthetic private detail')):
            result = parent_content_access(self.parent, at=self.now)
        self.assertEqual(result['access_state'], 'unknown')
        self.assertNotIn('synthetic private', str(result))

    def test_api_is_owned_authenticated_no_store_and_account_remains_accessible(self):
        client = APIClient()
        self.assertEqual(client.get('/api/billing/content-access/').status_code, 401)
        self.proof(parent=self.other)
        client.force_authenticate(self.parent)
        response = client.get('/api/billing/content-access/', {'parent_id': str(self.other.pk)})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['parent_id'], str(self.parent.pk))
        self.assertEqual(response.data['access_state'], 'unpaid')
        self.assertIn('no-store', response['Cache-Control'])
        self.assertEqual(client.get('/api/accounts/me/').status_code, 200)
