import hashlib
from unittest.mock import patch

from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.db import connection
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import User
from .models import Story, StoryNarration


@override_settings(CONTENT_MEDIA_HOSTS={'media.audit.example'})
class NarrationResolutionPerformanceTests(TestCase):
    def setUp(self):
        parent = User.objects.create_user(
            email='narration-cost@example.test', password='A-strong-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.client = APIClient()
        self.client.force_authenticate(parent)
        self.story = Story.objects.get(slug='david-and-goliath')
        StoryNarration.objects.filter(story=self.story).update(
            status=StoryNarration.Status.READY,
            audio_file='hardening/audio.mp3',
            text_sha256=hashlib.sha256(self.story.body.encode()).hexdigest(),
            duration_seconds=30, segments=[], words=[],
        )
        self.storage = StoryNarration._meta.get_field('audio_file').storage
        self.url = '/api/stories/david-and-goliath/'

    def test_ready_narrations_resolve_storage_once_per_object_per_request(self):
        with patch.object(self.storage, 'exists', return_value=True) as exists, \
             patch.object(self.storage, 'url', side_effect=lambda name: f'https://media.audit.example/{name}'):
            response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        narrations = response.data['narrations']
        audio_calls = [call for call in exists.call_args_list
                       if call.args[0].startswith('hardening/')]
        self.assertEqual(len(audio_calls), len(narrations))
        self.assertTrue(all(item['audio_available'] for item in narrations))
        self.assertTrue(all(item['audio_url'] == 'https://media.audit.example/hardening/audio.mp3'
                            for item in narrations))

    def test_resolution_cache_does_not_advertise_deleted_audio_on_next_request(self):
        with patch.object(self.storage, 'exists', return_value=True), \
             patch.object(self.storage, 'url', side_effect=lambda name: f'https://media.audit.example/{name}'):
            first = self.client.get(self.url)
        self.assertTrue(all(item['audio_available'] for item in first.data['narrations']))
        with patch.object(self.storage, 'exists', return_value=False) as exists:
            second = self.client.get(self.url)
        self.assertTrue(all(not item['audio_available'] for item in second.data['narrations']))
        self.assertTrue(all(item['audio_url'] is None for item in second.data['narrations']))
        self.assertEqual(sum(call.args[0].startswith('hardening/') for call in exists.call_args_list),
                         len(second.data['narrations']))

    def test_detail_prefetch_reuses_one_story_body_for_all_narrations(self):
        from .views import StoryViewSet
        view = StoryViewSet()
        view.action = 'retrieve'
        view.request = type('Request', (), {'query_params': {}})()
        with CaptureQueriesContext(connection) as queries:
            story = view.get_queryset().get(pk=self.story.pk)
            narrations = list(story.narrations.all())
            self.assertTrue(all(item.story is story for item in narrations))
        self.assertEqual(len(queries), 2)
        self.assertNotIn('JOIN "stories_story"', queries[1]['sql'])
