"""Catalogue removal must preserve the retired quest's immutable history."""
import importlib
import uuid
from types import SimpleNamespace

from django.apps import apps
from django.db import connection
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.progress.services import build_kid_profile_summary, build_profile_level
from apps.stories.models import Story, StoryNarration

from .models import Game, GameAttempt, GameLevel, KidGameProgress


RETIREMENT = importlib.import_module('apps.games.migrations.0018_retire_red_sea_path')


class RedSeaPathRetirementTests(TestCase):
    game_slug = 'red-sea-path'
    retire_function = staticmethod(RETIREMENT.retire_red_sea_path)

    def setUp(self):
        # These historical retirement checks predate the independent action
        # pause. Republish its two legacy fixtures only within the test DB.
        Game.objects.filter(slug__in=('david-sling-shot', 'jonah-ocean-maze')).update(is_published=True)
        self.parent = User.objects.create_user(
            email='path-retirement@example.com', password='Path-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent, display_name='Ada', avatar_key='lion',
        )
        self.game = Game.objects.get(slug=self.game_slug)
        self.level = self.game.levels.get(level_number=1)
        self.operation = uuid.uuid4()
        KidGameProgress.objects.create(
            profile=self.profile, game=self.game, highest_completed_level=2,
            total_stars=5, level_progress={
                '1': {'completed': True, 'best_stars': 3, 'best_score': 100, 'attempts': 2},
                '2': {'completed': True, 'best_stars': 2, 'best_score': 85,
                      'attempts': 1, 'completion_xp': 50},
            },
        )
        GameAttempt.objects.create(
            operation_id=self.operation, profile=self.profile, game=self.game,
            level=self.level, submitted_result={}, completed=True, score=100,
            stars=3, feedback='Saved historical result.',
            evaluation={'rescued_count': 10},
        )
        self.client = APIClient()
        self.client.force_authenticate(self.parent)

    def test_quest_is_hidden_and_stale_links_or_retries_cannot_play_it(self):
        response = self.client.get('/api/games/', {'profile_id': self.profile.pk})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 12)
        self.assertNotIn(self.game_slug, {game['slug'] for game in response.data})
        self.assertNotIn('path', {game['game_type'] for game in response.data})
        self.assertEqual(sum(game['game_type'] == 'quiz' for game in response.data), 5)
        self.assertEqual(
            self.client.get(f'/api/games/{self.game_slug}/', {'profile_id': self.profile.pk}).status_code,
            404,
        )
        # Neither a new stale submission nor retrying an old operation may
        # reopen the retired quest or change its saved reward.
        for operation in (uuid.uuid4(), self.operation):
            response = self.client.post(f'/api/games/{self.game_slug}/submit/', {
                'profile_id': str(self.profile.pk), 'level_number': 1,
                'operation_id': str(operation), 'result': {},
            }, format='json')
            self.assertEqual(response.status_code, 404)
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], 250)

    def test_idempotent_retirement_preserves_all_content_history_and_earned_xp(self):
        Game.objects.filter(pk=self.game.pk).update(is_published=True)
        old_game = Game.objects.values().get(pk=self.game.pk)
        other_games = list(Game.objects.exclude(pk=self.game.pk).order_by('pk').values())
        levels = list(GameLevel.objects.order_by('pk').values())
        attempts = list(GameAttempt.objects.order_by('pk').values())
        progress = list(KidGameProgress.objects.order_by('pk').values())
        profiles = list(KidProfile.objects.order_by('pk').values())
        stories = list(Story.objects.order_by('pk').values())
        narrations = list(StoryNarration.objects.order_by('pk').values())
        earned_level = build_profile_level(self.profile)
        self.assertEqual(earned_level['xp'], 250)
        self.assertEqual(build_kid_profile_summary(self.profile)['stats']['completed_game_levels'], 2)

        for _ in range(2):
            self.retire_function(apps, SimpleNamespace(connection=connection))

        self.assertEqual(Game.objects.values().get(pk=self.game.pk), {
            **old_game, 'is_published': False,
        })
        self.assertEqual(list(Game.objects.exclude(pk=self.game.pk).order_by('pk').values()), other_games)
        self.assertEqual(list(GameLevel.objects.order_by('pk').values()), levels)
        self.assertEqual(list(GameAttempt.objects.order_by('pk').values()), attempts)
        self.assertEqual(list(KidGameProgress.objects.order_by('pk').values()), progress)
        self.assertEqual(list(KidProfile.objects.order_by('pk').values()), profiles)
        self.assertEqual(list(Story.objects.order_by('pk').values()), stories)
        self.assertEqual(list(StoryNarration.objects.order_by('pk').values()), narrations)
        self.assertEqual(build_profile_level(self.profile), earned_level)
        summary = build_kid_profile_summary(self.profile)
        self.assertEqual(summary['xp_breakdown']['quests'], 250)
        self.assertEqual(summary['stats']['completed_game_levels'], 0)
        self.assertEqual(summary['stats']['game_stars'], 0)
        self.assertEqual(summary['stats']['games_started'], 0)
        self.assertEqual(summary['stats']['total_game_levels'], 36)
