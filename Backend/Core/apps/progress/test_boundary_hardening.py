import uuid

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.stories.catalogue_policy import UNAVAILABLE_STORY_SLUGS
from apps.stories.models import Story
from .models import KidActivityEvent
from .progression import XP_PER_COMPLETED_STORY
from .services import build_kid_profile_summary, build_reward_receipt, _level_payload


class EditorialActivityBoundaryTests(TestCase):
    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        self.parent = User.objects.create_user(
            email='editorial-boundary@example.test', password='Strong-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(parent=self.parent, display_name='Ada', avatar_key='kai')
        self.story = Story.objects.get(slug='lost-sheep')
        # Editorial policy must also protect stale-published rows.
        self.story.is_published = True
        self.story.save(update_fields=['is_published'])
        self.client = APIClient()
        self.client.force_authenticate(self.parent)
        self.url = f'/api/progress/kid-profiles/{self.profile.pk}/activity-events/'

    def payload(self, operation):
        return {'operation_id': str(operation), 'story_id': str(self.story.pk),
                'event_type': KidActivityEvent.EventType.STORY_COMPLETED}

    def test_hidden_library_story_cannot_accept_fresh_activity_or_rewards(self):
        for event_type in KidActivityEvent.EventType.values:
            payload = self.payload(uuid.uuid4())
            payload['event_type'] = event_type
            response = self.client.post(self.url, payload, format='json')
            self.assertEqual(response.status_code, 404)
        self.assertFalse(KidActivityEvent.objects.filter(profile=self.profile).exists())
        self.assertEqual(build_kid_profile_summary(self.profile)['xp_breakdown']['stories'], 0)

    def test_historical_hidden_story_operation_still_replays_without_extra_award(self):
        operation = uuid.uuid4()
        receipt = build_reward_receipt(_level_payload(0), xp_awarded=XP_PER_COMPLETED_STORY)
        event = KidActivityEvent.objects.create(
            profile=self.profile, story=self.story, operation_id=operation,
            event_type=KidActivityEvent.EventType.STORY_COMPLETED, reward_receipt=receipt,
        )
        response = self.client.post(self.url, self.payload(operation), format='json')
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['idempotent_replay'])
        self.assertEqual(response.data['event_id'], str(event.pk))
        self.assertEqual(response.data['xp_awarded'], XP_PER_COMPLETED_STORY)
        self.assertEqual(KidActivityEvent.objects.filter(profile=self.profile).count(), 1)
        summary = build_kid_profile_summary(self.profile)
        self.assertEqual(summary['xp_breakdown']['stories'], XP_PER_COMPLETED_STORY)

    def test_visible_summary_counts_match_library_policy_without_erasing_history(self):
        KidActivityEvent.objects.create(
            profile=self.profile, story=self.story, operation_id=uuid.uuid4(),
            event_type=KidActivityEvent.EventType.STORY_COMPLETED,
            reward_receipt={'xp_awarded': XP_PER_COMPLETED_STORY},
        )
        summary = build_kid_profile_summary(self.profile)
        expected = Story.objects.filter(is_published=True).exclude(slug__in=UNAVAILABLE_STORY_SLUGS).count()
        self.assertEqual(summary['stats']['total_stories'], expected)
        self.assertEqual(summary['stats']['stories_started'], 0)
        self.assertEqual(summary['stats']['stories_completed'], 0)
        self.assertEqual(summary['xp_breakdown']['stories'], XP_PER_COMPLETED_STORY)

    def test_repeat_receipt_chunks_keep_one_historical_award(self):
        KidActivityEvent.objects.bulk_create([
            KidActivityEvent(
                profile=self.profile, story=self.story, operation_id=uuid.uuid4(),
                event_type=KidActivityEvent.EventType.STORY_COMPLETED,
                reward_receipt={'xp_awarded': XP_PER_COMPLETED_STORY if i == 0 else 0},
            )
            for i in range(1500)
        ])
        summary = build_kid_profile_summary(self.profile)
        self.assertEqual(summary['xp_breakdown']['stories'], XP_PER_COMPLETED_STORY)
        self.assertEqual(summary['stats']['stories_completed'], 0)
