import copy
import importlib
from types import SimpleNamespace

from django.apps import apps
from django.core.exceptions import ValidationError
from django.db import connection
from django.test import TestCase

from .models import Game, GameLevel
from .services import GameResultError, evaluate_level, public_level_config


class ArkBoardingTests(TestCase):
    def setUp(self):
        self.level = GameLevel.objects.get(game__slug='ark-animal-match', level_number=1)
        # Keep exercising the earlier boarding contract after the catalogue
        # moves this game's saved levels to the new traffic mode.
        migration = importlib.import_module('apps.games.migrations.0009_playful_gameplay')
        self.level.config = migration.ark_config(8, 45, 5)

    def result(self, count, *, elapsed=45):
        return {
            'pairs': [
                {'left_id': left, 'right_id': right}
                for left, right in list(self.level.config['expected_pairs'].items())[:count]
            ],
            'elapsed_seconds': elapsed,
        }

    def test_round_presents_animals_and_goal_without_private_answer_key(self):
        public = public_level_config(self.level)
        self.assertEqual(public['mode'], 'ark_boarding')
        self.assertEqual(public['time_limit_seconds'], 45)
        self.assertEqual(public['goal_pairs'], 5)
        self.assertEqual(len(public['left_items']), 8)
        self.assertEqual(len(public['right_items']), 8)
        self.assertNotIn('expected_pairs', public)

    def test_successful_partial_round_is_scored_from_pairs_not_claimed_points(self):
        evaluation = evaluate_level(self.level, self.result(5))
        self.assertTrue(evaluation.completed)
        self.assertEqual(evaluation.score, 62)
        self.assertEqual(evaluation.stars, 1)
        self.assertEqual(evaluation.details['animals_boarded'], 10)
        self.assertEqual(evaluation.details['elapsed_seconds'], 45)
        with self.assertRaises(GameResultError):
            evaluate_level(self.level, {**self.result(5), 'score': 100})

    def test_below_goal_does_not_unlock_level_or_award_stars(self):
        evaluation = evaluate_level(self.level, self.result(4))
        self.assertFalse(evaluation.completed)
        self.assertEqual(evaluation.stars, 0)
        self.assertEqual(evaluation.score, 50)
        self.assertIn('another round', evaluation.feedback)

    def test_every_pair_boards_for_a_perfect_round(self):
        evaluation = evaluate_level(self.level, self.result(8, elapsed=18))
        self.assertTrue(evaluation.completed)
        self.assertEqual(evaluation.score, 100)
        self.assertEqual(evaluation.stars, 3)

    def test_wrong_partner_does_not_count_as_a_rescue(self):
        result = self.result(5)
        first, second = result['pairs'][:2]
        first['right_id'], second['right_id'] = second['right_id'], first['right_id']
        evaluation = evaluate_level(self.level, result)
        self.assertEqual(evaluation.details['correct_pairs'], 3)
        self.assertFalse(evaluation.completed)

    def test_impossible_duplicate_unknown_and_malformed_ids_are_rejected(self):
        duplicate = self.result(1)
        duplicate['pairs'] *= 2
        unknown = self.result(1)
        unknown['pairs'][0]['left_id'] = 'unicorn-1'
        non_text = self.result(1)
        non_text['pairs'][0]['right_id'] = ['lion-2']
        for result in (duplicate, unknown, non_text):
            with self.subTest(result=result), self.assertRaises(GameResultError):
                evaluate_level(self.level, result)

    def test_round_time_must_be_bounded_real_integer(self):
        for elapsed in (46, -1, True, 1.2, '5', None):
            with self.subTest(elapsed=elapsed), self.assertRaises(GameResultError):
                evaluate_level(self.level, self.result(5, elapsed=elapsed))
        with self.assertRaises(GameResultError):
            evaluate_level(self.level, {'pairs': self.result(5)['pairs']})

    def test_moses_matching_preserves_untimed_contract(self):
        level = GameLevel.objects.get(game__slug='moses-match', level_number=1)
        pairs = [
            {'left_id': left, 'right_id': right}
            for left, right in level.config['expected_pairs'].items()
        ]
        self.assertNotIn('mode', public_level_config(level))
        self.assertTrue(evaluate_level(level, {'pairs': pairs}).completed)
        with self.assertRaises(GameResultError):
            evaluate_level(level, {'pairs': pairs, 'elapsed_seconds': 10})

    def test_authoring_rejects_invalid_time_goal_and_mismatched_animal_portraits(self):
        source = copy.deepcopy(self.level.config)
        for key, value in (
            ('goal_pairs', 9), ('goal_pairs', True), ('time_limit_seconds', 0),
            ('time_limit_seconds', 181), ('time_limit_seconds', True),
        ):
            self.level.config = {**copy.deepcopy(source), key: value}
            with self.subTest(key=key, value=value), self.assertRaises(ValidationError):
                self.level.full_clean()
        self.level.config = copy.deepcopy(source)
        self.level.config['right_items'][0]['asset_key'] = 'animal:lion'
        with self.assertRaises(ValidationError):
            self.level.full_clean()

    def test_content_refresh_preserves_catalogue_and_level_ids(self):
        before = set(GameLevel.objects.values_list('pk', flat=True))
        game_ids = set(Game.objects.values_list('pk', flat=True))
        migration = importlib.import_module('apps.games.migrations.0009_playful_gameplay')
        migration.refresh_gameplay(apps, SimpleNamespace(connection=connection))
        self.assertEqual(set(GameLevel.objects.values_list('pk', flat=True)), before)
        self.assertEqual(set(Game.objects.values_list('pk', flat=True)), game_ids)
        self.assertEqual(GameLevel.objects.count(), len(before))
        for level in GameLevel.objects.filter(game__slug='ark-animal-match'):
            level.full_clean()
