"""Builders retirement keeps earned history while removing the empty Order room."""
import importlib

from . import test_path_retirement as path_retirement


RETIREMENT = importlib.import_module('apps.games.migrations.0020_retire_wise_and_foolish_builders')


class WiseBuildersRetirementTests(path_retirement.RedSeaPathRetirementTests):
    game_slug = 'wise-and-foolish-builders'
    retire_function = staticmethod(RETIREMENT.retire_wise_builders)

    def test_remaining_catalogue_keeps_aim_maze_and_selected_quizzes_and_puzzles(self):
        response = self.client.get('/api/games/', {'profile_id': self.profile.pk})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 12)
        slugs = {game['slug'] for game in response.data}
        self.assertTrue({'david-sling-shot', 'jonah-ocean-maze', 'puzzle-quest', 'esther-quiz'} <= slugs)
        self.assertNotIn('creation-order', slugs)
        self.assertNotIn('wise-and-foolish-builders', slugs)
        self.assertFalse(any(game['game_type'] == 'ordering' for game in response.data))
        self.assertEqual(sum(game['game_type'] == 'quiz' for game in response.data), 5)
        self.assertEqual(sum(game['game_type'] == 'puzzle' for game in response.data), 5)
