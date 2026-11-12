"""The Old Testament library must not remove games or earned learning."""
import importlib
from types import SimpleNamespace
import uuid

from django.apps import apps
from django.db import connection
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.games.models import Game, GameAttempt, GameLevel, KidGameProgress
from apps.progress.models import KidActivityEvent, StreakDailyVisit
from apps.progress.services import build_profile_xp_breakdown

from .models import NarratorVoice, Story, StoryNarration


MIGRATION = importlib.import_module(
    'apps.stories.migrations.0011_old_testament_story_library'
)
HIDDEN_SLUGS = {'lost-sheep', 'good-samaritan'}


def rows(model):
    return list(model.objects.order_by('pk').values())


class StoryLibraryScopeTests(TestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='story-library@example.com', password='Library-test-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent, display_name='Ada', avatar_key='lion',
        )
        self.client = APIClient()
        self.client.force_authenticate(self.parent)
        self.editor = SimpleNamespace(connection=connection)

    def test_stale_publication_cannot_reopen_list_search_or_detail(self):
        Story.objects.filter(slug__in=HIDDEN_SLUGS).update(is_published=True)
        response = self.client.get('/api/stories/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 11)
        self.assertFalse(HIDDEN_SLUGS & {item['slug'] for item in response.data})
        for slug, search in [('lost-sheep', 'sheep'), ('good-samaritan', 'Samaritan')]:
            with self.subTest(slug=slug):
                self.assertEqual(self.client.get(f'/api/stories/{slug}/').status_code, 404)
                self.assertNotIn(slug, {
                    item['slug']
                    for item in self.client.get('/api/stories/', {'search': search}).data
                })
        self.assertEqual(
            self.client.get('/api/stories/ruth-and-naomi/').status_code, 200,
        )

    def test_unpublish_is_idempotent_and_preserves_content_games_and_earned_xp(self):
        Story.objects.filter(slug__in=HIDDEN_SLUGS).update(is_published=True)
        for slug in HIDDEN_SLUGS:
            KidActivityEvent.objects.create(
                profile=self.profile, story=Story.objects.get(slug=slug),
                operation_id=uuid.uuid4(),
                event_type=KidActivityEvent.EventType.STORY_COMPLETED,
                reward_receipt={'xp_awarded': 50},
            )
        stories_before = {item['slug']: item for item in rows(Story)}
        preserved_models = (
            StoryNarration, NarratorVoice, Game, GameLevel, GameAttempt,
            KidGameProgress, KidActivityEvent, StreakDailyVisit,
        )
        preserved = {model: rows(model) for model in preserved_models}
        xp_before = build_profile_xp_breakdown(self.profile)
        self.assertEqual(xp_before['stories'], 100)

        MIGRATION.unpublish_new_testament_stories(apps, self.editor)
        once = rows(Story)
        MIGRATION.unpublish_new_testament_stories(apps, self.editor)
        self.assertEqual(rows(Story), once)
        for story in once:
            expected = {**stories_before[story['slug']]}
            if story['slug'] in HIDDEN_SLUGS:
                expected['is_published'] = False
            self.assertEqual(story, expected)
        for model in preserved_models:
            self.assertEqual(rows(model), preserved[model], model.__name__)
        self.assertEqual(build_profile_xp_breakdown(self.profile), xp_before)
        self.assertEqual(Story.objects.count(), 13)
        self.assertEqual(StoryNarration.objects.count(), 39)
