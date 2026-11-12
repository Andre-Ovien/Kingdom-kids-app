from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.progress.services import build_kid_profile_summary
from apps.stories.models import Story
from .models import Game, GameLevel, KidGameProgress


class CatalogueQueryHardeningTests(TestCase):
    def setUp(self):
        parent = User.objects.create_user(
            email='query-hardening@example.test', password='A-strong-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=parent, display_name='Audit Child', avatar_key='kai',
        )
        self.client = APIClient()
        self.client.force_authenticate(parent)

    def add_catalogue(self, count):
        games = Game.objects.bulk_create([
            Game(slug=f'query-game-{i}', title=f'Query Game {i}', game_type='quiz',
                 description='large unused summary metadata ' * 250)
            for i in range(count)
        ])
        GameLevel.objects.bulk_create([
            GameLevel(game=game, level_number=1, title='First level',
                      config={'questions': [], 'padding': 'x' * 4096})
            for game in games
        ])
        KidGameProgress.objects.bulk_create([
            KidGameProgress(profile=self.profile, game=game) for game in games
        ])
        Story.objects.bulk_create([
            Story(slug=f'query-story-{i}', title=f'Query Story {i}', category='Faith',
                  summary='A short summary', body='Long body. ' * 2000)
            for i in range(count)
        ])

    def capture(self, path, data=None):
        with CaptureQueriesContext(connection) as queries:
            response = self.client.get(path, data or {})
        self.assertEqual(response.status_code, 200)
        return response, list(queries)

    def test_catalogue_and_summary_query_budgets_do_not_grow_per_item(self):
        game_before, game_queries = self.capture('/api/games/', {'profile_id': self.profile.pk})
        story_before, story_queries = self.capture('/api/stories/')
        summary_path = f'/api/progress/kid-profiles/{self.profile.pk}/summary/'
        summary_before, summary_queries = self.capture(summary_path)
        self.add_catalogue(30)
        game_after, more_game_queries = self.capture('/api/games/', {'profile_id': self.profile.pk})
        story_after, more_story_queries = self.capture('/api/stories/')
        summary_after, more_summary_queries = self.capture(summary_path)
        self.assertEqual(len(game_after.data), len(game_before.data) + 30)
        self.assertEqual(len(story_after.data), len(story_before.data) + 30)
        self.assertEqual(summary_after.data['stats']['total_game_levels'],
                         summary_before.data['stats']['total_game_levels'] + 30)
        for before, after, budget in (
            (game_queries, more_game_queries, 3),
            (story_queries, more_story_queries, 1),
            (summary_queries, more_summary_queries, 12),
        ):
            self.assertEqual(len(after), len(before))
            self.assertLessEqual(len(after), budget)

    def test_games_progress_lookup_does_not_repeat_the_level_aggregate(self):
        self.add_catalogue(5)
        response, queries = self.capture('/api/games/', {'profile_id': self.profile.pk})
        progress_sql = next(item['sql'] for item in queries
                            if 'FROM "games_kidgameprogress"' in item['sql'])
        self.assertNotIn('games_gamelevel', progress_sql)
        self.assertNotIn('JOIN "games_game"', progress_sql)
        self.assertNotIn('ORDER BY', progress_sql)
        aggregate_queries = [item for item in queries if 'games_gamelevel' in item['sql']]
        self.assertEqual(len(aggregate_queries), 1)
        added = [item for item in response.data if item['slug'].startswith('query-game-')]
        self.assertEqual(len(added), 5)
        self.assertTrue(all(item['total_levels'] == 1 for item in added))

    def test_profile_summary_avoids_unused_catalogue_text_and_configs(self):
        self.add_catalogue(5)
        with CaptureQueriesContext(connection) as queries:
            summary = build_kid_profile_summary(self.profile)
        game_sql = next(item['sql'] for item in queries
                        if 'FROM "games_game"' in item['sql'])
        self.assertNotIn('"description"', game_sql)
        self.assertNotIn('"cover_asset_key"', game_sql)
        self.assertNotIn('"title"', game_sql)
        self.assertFalse(any('"config"' in item['sql'] for item in queries))
        self.assertGreaterEqual(summary['stats']['total_game_levels'], 5)
