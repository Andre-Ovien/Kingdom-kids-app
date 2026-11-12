"""Creation retirement shares the history contract and preserves legacy scoring."""
import importlib
import uuid

from apps.progress.services import build_profile_level

from . import test_path_retirement as path_retirement
from .models import Game, GameLevel
from .wise_builders import example_builders_result


RETIREMENT = importlib.import_module('apps.games.migrations.0019_retire_creation_order')


class CreationOrderRetirementTests(path_retirement.RedSeaPathRetirementTests):
    game_slug = 'creation-order'
    retire_function = staticmethod(RETIREMENT.retire_creation_order)

    def test_legacy_builders_fixture_still_scores_without_reopening_creation(self):
        # Builders was subsequently retired too. Explicitly publish this one
        # legacy fixture to retain scoring and cross-game receipt coverage.
        Game.objects.filter(slug='wise-and-foolish-builders').update(is_published=True)
        response = self.client.get('/api/games/', {'profile_id': self.profile.pk})
        ordering = [game for game in response.data if game['game_type'] == 'ordering']
        self.assertEqual([game['slug'] for game in ordering], ['wise-and-foolish-builders'])
        level = GameLevel.objects.get(game__slug='wise-and-foolish-builders', level_number=1)
        response = self.client.get(
            '/api/games/wise-and-foolish-builders/', {'profile_id': self.profile.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data['levels']), 3)
        response = self.client.post('/api/games/wise-and-foolish-builders/submit/', {
            'profile_id': str(self.profile.pk), 'level_number': 1,
            'operation_id': str(self.operation), 'result': example_builders_result(level.config),
        }, format='json')
        # A used operation from the retired quest remains protected across games.
        self.assertEqual(response.status_code, 409)
        response = self.client.post('/api/games/wise-and-foolish-builders/submit/', {
            'profile_id': str(self.profile.pk), 'level_number': 1,
            'operation_id': str(uuid.uuid4()), 'result': example_builders_result(level.config),
        }, format='json')
        self.assertEqual(response.status_code, 201)
        self.assertTrue(response.data['completed'])
        self.assertEqual(response.data['stars'], 3)
        self.assertEqual(build_profile_level(self.profile)['xp'], 360)
