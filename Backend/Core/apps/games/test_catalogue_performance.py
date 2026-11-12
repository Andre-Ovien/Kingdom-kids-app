from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.stories.models import Story
from .models import Game


class CataloguePerformanceTests(TestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='catalogue-performance@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent, display_name='Ada', avatar_key='lion',
        )
        self.client = APIClient()
        self.client.force_authenticate(self.parent)

    def test_game_catalogue_does_not_load_level_configs_or_add_queries_per_game(self):
        with CaptureQueriesContext(connection) as queries:
            response = self.client.get('/api/games/', {'profile_id': self.profile.pk})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), Game.objects.filter(is_published=True).count())
        self.assertTrue(all(item['total_levels'] > 0 for item in response.data))
        self.assertLessEqual(len(queries), 3)
        self.assertFalse(any('"config"' in query['sql'] for query in queries))

    def test_story_catalogue_does_not_load_full_text_or_narration_timings(self):
        with CaptureQueriesContext(connection) as queries:
            response = self.client.get('/api/stories/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), Story.objects.filter(is_published=True).count())
        self.assertLessEqual(len(queries), 1)
        self.assertFalse(any('stories_storynarration' in query['sql'] for query in queries))
        self.assertFalse(any('"body"' in query['sql'] for query in queries))

    def test_story_detail_keeps_full_text_and_character_narrations(self):
        response = self.client.get('/api/stories/david-and-goliath/')
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['body'])
        self.assertEqual(len(response.data['narrations']), 3)
