from dataclasses import FrozenInstanceError
from datetime import timedelta
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4
from unittest.mock import patch

from django.core.exceptions import ValidationError
from django.db import IntegrityError, connection, transaction
from django.test import SimpleTestCase, TestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.games.models import Game, GameAttempt, GameLevel
from apps.progress.models import KidActivityEvent, StreakDailyVisit
from apps.stories.models import NarratorVoice, Story, StoryNarration
from .models import ParentContentEntitlement, SquareSubscriptionIdentity, SquareCustomerIdentity
from .permissions import has_paid_content_access
from .plans import (ALL_CONTENT_FEATURE, POLICY_PATH, POLICY_SHA256,
                    confirmed_content_plan, square_catalogue_request)
from .tests import CONFIG, event_bytes, signature


class ConfirmedPlanTests(SimpleTestCase):
    def test_confirmed_999_usd_monthly_full_immediate_and_next_28th_terms_are_immutable(self):
        plan = confirmed_content_plan()
        data = json.loads(POLICY_PATH.read_text())
        self.assertEqual(hashlib.sha256(POLICY_PATH.read_bytes()).hexdigest(), POLICY_SHA256)
        self.assertEqual((plan.amount_minor, plan.currency, plan.cadence, plan.anchor_day, plan.can_prorate),
                         (999, 'USD', 'MONTHLY', 28, False))
        self.assertEqual(data['app_store_launch_country'], 'US')
        self.assertFalse(data['free_period'])
        self.assertEqual(data['first_charge'], 'full_amount_immediately')
        self.assertTrue(data['first_two_charges_disclosure_required'])
        with self.assertRaises(FrozenInstanceError):
            plan.amount_minor = 1900

    def test_catalogue_draft_is_deterministic_scoped_and_does_not_add_seller_item_eligibility(self):
        operation = uuid4()
        first = square_catalogue_request(operation_id=operation, location_id='test-location')
        self.assertEqual(first, square_catalogue_request(operation_id=operation, location_id='test-location'))
        self.assertNotEqual(first['idempotency_key'], square_catalogue_request(
            operation_id=uuid4(), location_id='test-location')['idempotency_key'])
        self.assertEqual(len(first['batches']), 1)
        plan, variation = first['batches'][0]['objects']
        self.assertEqual(plan['subscription_plan_data'], {'name': 'Kingdom Kids all stories and games'})
        self.assertEqual(variation['subscription_plan_variation_data']['subscription_plan_id'], plan['id'])
        fields = variation['subscription_plan_variation_data']
        self.assertEqual((fields['monthly_billing_anchor_date'], fields['can_prorate']), (28, False))
        self.assertEqual(fields['phases'], [{'ordinal': 0, 'cadence': 'MONTHLY',
            'pricing': {'type': 'STATIC', 'price_money': {'amount': 999, 'currency': 'USD'}}}])
        self.assertFalse(plan['present_at_all_locations'])
        self.assertEqual(plan['present_at_location_ids'], ['test-location'])
        first['batches'].clear()
        self.assertEqual(len(square_catalogue_request(operation_id=operation, location_id='test-location')['batches']), 1)

    def test_unreviewed_price_and_invalid_draft_identity_are_rejected(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'changed.json'
            path.write_text(POLICY_PATH.read_text().replace('999', '1900'))
            with patch('apps.billing.plans.POLICY_PATH', path), self.assertRaises(ValueError):
                confirmed_content_plan()
        with self.assertRaises(ValueError):
            square_catalogue_request(operation_id='', location_id='test-location')
        with self.assertRaises(ValueError):
            square_catalogue_request(operation_id=uuid4(), location_id='bad\nlocation')


@override_settings(PAID_CONTENT_ENFORCEMENT_ENABLED=True, PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='sandbox',
                   CONTENT_MEDIA_HOSTS=('media.paid-test.test',))
class PaidContentTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.parent = User.objects.create_user(email='paid-parent@example.test', password='Synthetic-test-123!',
                                               email_verified_at=timezone.now())
        cls.other = User.objects.create_user(email='paid-other@example.test', password='Synthetic-test-123!',
                                              email_verified_at=timezone.now())
        cls.child = KidProfile.objects.create(parent=cls.parent, display_name='Ada', avatar_key='lion')
        cls.foreign_child = KidProfile.objects.create(parent=cls.other, display_name='Other', avatar_key='dove')
        cls.story = Story.objects.create(slug='paid-test-story', title='Paid story', category='Faith',
                                         summary='A test.', body='A complete test story.')
        StoryNarration.objects.create(story=cls.story, narrator=NarratorVoice.objects.get(pk='lion'),
            status='ready', text_sha256=hashlib.sha256(cls.story.body.encode()).hexdigest(),
            audio_url='https://media.paid-test.test/approved.mp3', duration_seconds=30)
        cls.game = Game.objects.create(slug='paid-test-game', title='Paid game', game_type='quiz',
            subtitle='A test quest', description='A test game.', cover_asset_key='assets/images/test.png')
        cls.level = GameLevel.objects.create(game=cls.game, level_number=1, title='One', instructions='Choose.',
            config={'questions': [{'id': 'q', 'prompt': 'Who helped?',
                'options': [{'id': 'yes', 'text': 'Yes'}, {'id': 'no', 'text': 'No'}],
                'correct_option_id': 'yes'}], 'pass_score': 60})

    def setUp(self):
        self.now = timezone.now()
        self.client = APIClient()
        self.client.force_authenticate(self.parent)

    def fields(self, **changes):
        return dict(parent=self.parent, feature_code=ALL_CONTENT_FEATURE, provider='square', environment='sandbox',
            provider_account_id='synthetic-merchant', source_reference=str(uuid4()),
            valid_from=self.now - timedelta(days=1), valid_until=self.now + timedelta(days=1),
            payment_verified_at=self.now - timedelta(minutes=1), **changes)

    def grant(self, **changes):
        values = self.fields()
        values.update(changes)
        return ParentContentEntitlement.objects.create(**values)

    def game_body(self, profile=None):
        return {'profile_id': str(profile or self.child.pk), 'level_number': 1,
                'operation_id': str(uuid4()), 'result': {'answers': [{'question_id': 'q', 'option_id': 'yes'}]}}

    def activity_body(self):
        return {'story_id': str(self.story.pk), 'event_type': 'story_completed', 'operation_id': str(uuid4())}

    def paths(self):
        return [('/api/stories/', {}), (f'/api/stories/{self.story.slug}/', {}),
                ('/api/games/', {'profile_id': self.child.pk}),
                (f'/api/games/{self.game.slug}/', {'profile_id': self.child.pk})]

    def test_gate_off_keeps_existing_access_and_does_not_query_entitlements(self):
        with override_settings(PAID_CONTENT_ENFORCEMENT_ENABLED=False):
            with self.assertNumQueries(0):
                self.assertTrue(has_paid_content_access(self.parent))
            for path, query in self.paths():
                self.assertEqual(self.client.get(path, query).status_code, 200)
            self.assertEqual(self.client.post(f'/api/games/{self.game.slug}/submit/', self.game_body(), format='json').status_code, 201)
        self.assertEqual(ParentContentEntitlement.objects.count(), 0)

    def test_unpaid_parent_cannot_read_bodies_narration_rules_or_create_results_activity_streak(self):
        for path, query in self.paths():
            response = self.client.get(path, query)
            self.assertEqual(response.status_code, 403)
            self.assertEqual(response.json()['code'], 'subscription_required')
            self.assertNotIn(b'approved.mp3', response.content)
            self.assertNotIn(self.story.body.encode(), response.content)
        responses = [
            self.client.post(f'/api/games/{self.game.slug}/submit/', self.game_body(), format='json'),
            self.client.post(f'/api/progress/kid-profiles/{self.child.pk}/activity-events/', self.activity_body(), format='json'),
            self.client.post(f'/api/progress/kid-profiles/{self.child.pk}/streak-presentations/claim/', {'timezone_offset_minutes': 0}, format='json'),
        ]
        self.assertTrue(all(response.status_code == 403 for response in responses))
        self.assertEqual((GameAttempt.objects.count(), KidActivityEvent.objects.count(), StreakDailyVisit.objects.count()), (0, 0, 0))

    def test_verified_period_allows_all_content_and_writes_but_not_foreign_child(self):
        self.grant()
        for path, query in self.paths():
            self.assertEqual(self.client.get(path, query).status_code, 200)
        detail = self.client.get(f'/api/stories/{self.story.slug}/').json()
        self.assertEqual(detail['narrations'][0]['audio_url'], 'https://media.paid-test.test/approved.mp3')
        self.assertEqual(self.client.post(f'/api/games/{self.game.slug}/submit/', self.game_body(), format='json').status_code, 201)
        self.assertEqual(self.client.post(f'/api/progress/kid-profiles/{self.child.pk}/activity-events/', self.activity_body(), format='json').status_code, 201)
        self.assertEqual(self.client.post(f'/api/progress/kid-profiles/{self.child.pk}/streak-presentations/claim/', {'timezone_offset_minutes': 0}, format='json').status_code, 200)
        self.assertEqual(self.client.get('/api/games/', {'profile_id': self.foreign_child.pk}).status_code, 404)
        self.assertEqual(self.client.post(f'/api/games/{self.game.slug}/submit/', self.game_body(self.foreign_child.pk), format='json').status_code, 404)

    def test_paid_period_is_start_inclusive_end_exclusive_and_future_verification_never_grants(self):
        row = self.grant(valid_from=self.now, valid_until=self.now + timedelta(hours=1))
        self.assertTrue(has_paid_content_access(self.parent, at=row.valid_from))
        self.assertFalse(has_paid_content_access(self.parent, at=row.valid_from - timedelta(microseconds=1)))
        self.assertFalse(has_paid_content_access(self.parent, at=row.valid_until))
        row.payment_verified_at = self.now + timedelta(minutes=1)
        row.save()
        self.assertFalse(has_paid_content_access(self.parent, at=self.now))
        with self.assertRaises(ValueError):
            has_paid_content_access(self.parent, at=self.now.replace(tzinfo=None))
        with self.assertRaises(ValidationError):
            self.grant(valid_from=self.now.replace(tzinfo=None))

    def test_revocation_takes_effect_immediately_while_renewal_cancellation_retains_paid_period(self):
        row = self.grant()
        customer = SquareCustomerIdentity.objects.create(parent=self.parent, merchant_id='synthetic-merchant', customer_id='synthetic-customer')
        SquareSubscriptionIdentity.objects.create(customer=customer, subscription_id='synthetic-subscription', provider_status='CANCELED')
        self.assertTrue(has_paid_content_access(self.parent, at=self.now))
        row.revoked_at = self.now + timedelta(minutes=1)
        row.save()
        self.assertTrue(has_paid_content_access(self.parent, at=self.now))
        self.assertFalse(has_paid_content_access(self.parent, at=row.revoked_at))
        row.revoked_at = self.now
        row.save()
        self.assertEqual(self.client.get('/api/stories/').status_code, 403)

    def test_parent_environment_feature_and_inactive_identity_are_isolated(self):
        self.grant(parent=self.other)
        self.grant(environment='production')
        self.grant(feature_code='another_product')
        self.assertFalse(has_paid_content_access(self.parent, at=self.now))
        self.grant(provider='app_store')
        self.assertTrue(has_paid_content_access(self.parent, at=self.now))
        self.parent.is_active = False
        self.assertFalse(has_paid_content_access(self.parent, at=self.now))
        with override_settings(PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='unknown'):
            self.assertFalse(has_paid_content_access(self.other, at=self.now))

    def test_unsupported_empty_and_control_evidence_fail_model_and_read_defenses(self):
        for changes in [{'provider': 'unknown'}, {'provider_account_id': ''}, {'source_reference': ''},
                        {'provider_account_id': ' '}, {'source_reference': 'bad\nproof'}]:
            with self.subTest(changes=changes), self.assertRaises(ValidationError):
                self.grant(**changes)
        for changes in [{'provider': 'unknown'}, {'provider_account_id': ''}, {'source_reference': ''}]:
            fields = self.fields(); fields.update(changes)
            with self.subTest(changes=changes), self.assertRaises(IntegrityError), transaction.atomic():
                ParentContentEntitlement.objects.bulk_create([ParentContentEntitlement(**fields)])
        for value in (' ', '\t', '\x1f', 'bad\nproof'):
            fields = self.fields(); fields['source_reference'] = value
            ParentContentEntitlement.objects.bulk_create([ParentContentEntitlement(**fields)])
        self.assertFalse(has_paid_content_access(self.parent, at=self.now))

    def test_evidence_cannot_be_cloned_to_another_parent_and_period_must_be_positive(self):
        row = self.grant()
        with self.assertRaises(ValidationError):
            self.grant(parent=self.other, source_reference=row.source_reference)
        with self.assertRaises(ValidationError):
            self.grant(valid_until=self.now - timedelta(days=2))

    def test_client_claims_and_signed_active_webhook_never_grant_entitlement(self):
        self.assertEqual(self.client.get('/api/stories/', {'subscription_active': 'true'}, HTTP_X_SUBSCRIPTION_ACTIVE='true').status_code, 403)
        body = self.game_body(); body['subscription_status'] = 'ACTIVE'
        self.assertEqual(self.client.post(f'/api/games/{self.game.slug}/submit/', body, format='json').status_code, 403)
        self.assertEqual(self.client.post('/api/billing/entitlements/', {'active': True}, format='json').status_code, 404)
        with override_settings(**CONFIG):
            raw = event_bytes(data={'id': 'synthetic-subscription', 'object': {'status': 'ACTIVE'}})
            self.assertEqual(self.client.post('/api/billing/square/webhook/', raw, content_type='application/json',
                HTTP_X_SQUARE_HMACSHA256_SIGNATURE=signature(raw)).status_code, 200)
        self.assertEqual(ParentContentEntitlement.objects.count(), 0)
        self.assertEqual(self.client.get('/api/stories/').status_code, 403)

    def test_parent_management_summary_recovery_and_deletion_validation_stay_accessible(self):
        self.assertEqual(self.client.get('/api/accounts/me/').status_code, 200)
        self.assertEqual(self.client.get('/api/accounts/kid-profiles/').status_code, 200)
        self.assertEqual(self.client.get(f'/api/progress/kid-profiles/{self.child.pk}/summary/').status_code, 200)
        for path in ('/api/accounts/account-deletion/request/', '/api/accounts/account-deletion/confirm/',
                     '/api/accounts/password-reset/request/'):
            response = self.client.post(path, {}, format='json')
            self.assertEqual(response.status_code, 400)
            self.assertNotIn('subscription_required', response.content.decode())

    @skipUnlessDBFeature('has_select_for_update')
    def test_early_success_closes_server_side_entitlement_cursor(self):
        self.grant()
        with connection.cursor() as cursor:
            cursor.execute('SELECT count(*) FROM pg_cursors')
            before = cursor.fetchone()[0]
        self.assertTrue(has_paid_content_access(self.parent, at=self.now))
        with connection.cursor() as cursor:
            cursor.execute('SELECT count(*) FROM pg_cursors')
            self.assertEqual(cursor.fetchone()[0], before)
