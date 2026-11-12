"""Authoritative replay, content parity and preservation for new matching games."""

from copy import deepcopy
import io
import json
from pathlib import Path
import uuid
from unittest.mock import patch

from django.core.exceptions import ValidationError
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.progress.services import build_profile_level
from .matching_studio import (
    GRAINS, HarvestState, XorShift32, available_three_chains,
    build_coat_studio_config, build_harvest_chain_config, ensure_harvest_move,
    example_coat_studio_result, example_harvest_chain_result,
    replay_coat_studio, replay_harvest_chain,
)
from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import GameResultError, evaluate_level, public_level_config
from .validators import validate_level_definition

CONTENT = Path(__file__).with_name('content')
BACKUP = 'apps.games.management.commands.install_matching_studio.backup_local_database'


class MatchingStudioReplayTests(SimpleTestCase):
    def test_authored_rounds_and_dart_goldens_match_exact_replay(self):
        fixture = json.loads((CONTENT / 'matching_studio_v1.json').read_text())
        golden = json.loads((CONTENT / 'harvest_chain_golden_v1.json').read_text())
        for number in (1, 2, 3):
            coat, harvest = build_coat_studio_config(number), build_harvest_chain_config(number)
            self.assertEqual(fixture['coat_rounds'][number - 1], coat)
            self.assertEqual(fixture['harvest_rounds'][number - 1], harvest)
            coat_outcome = replay_coat_studio(coat, example_coat_studio_result(coat))
            self.assertTrue(coat_outcome['completed'])
            self.assertEqual(coat_outcome['score'], 100)
            expected = golden['rounds'][number - 1]
            state = HarvestState(harvest)
            self.assertEqual(expected['initial'], state.outcome())
            state.apply(expected['first_chain'])
            self.assertEqual(expected['after_first'], state.outcome())
            outcome = replay_harvest_chain(harvest, expected['winning_result'])
            self.assertEqual(outcome, expected['winning_outcome'])
            self.assertTrue(outcome['completed'])
            self.assertLessEqual(outcome['chains_used'], harvest['max_chains'])
            for config in (coat, harvest):
                validate_level_definition(game_type='matching', config=config,
                                          max_score=100, star_thresholds=[60, 80, 95])

    def test_coat_requires_pattern_as_well_as_color_and_wrong_attempt_is_nonfatal(self):
        config = build_coat_studio_config(2)
        result = example_coat_studio_result(config)
        target = config['panels'][0]
        wrong = next(s for s in config['swatches'] if s['color'] == target['color'] and s['pattern'] != target['pattern'])
        result['actions'].insert(0, {'panel_id': target['id'], 'swatch_id': wrong['id']})
        outcome = replay_coat_studio(config, result)
        self.assertTrue(outcome['completed'])
        self.assertEqual(outcome['mistakes'], 1)
        self.assertEqual(outcome['score'], 96)
        self.assertEqual(replay_coat_studio(config, {'actions': result['actions'][:1]})['filled_panels'], [])

    def test_coat_malformed_claims_duplicate_stitches_and_overlong_input_rejected(self):
        config = build_coat_studio_config(1)
        first = example_coat_studio_result(config)['actions'][0]
        invalid = [
            {'actions': [], 'score': 100}, {'actions': None},
            {'actions': [first, first]},
            {'actions': [{'panel_id': [], 'swatch_id': 'fabric_1'}]},
            {'actions': [{'panel_id': 'missing', 'swatch_id': 'fabric_1'}]},
            {'actions': [{**first, 'correct': True}]},
            {'actions': [first] * 121},
        ]
        for result in invalid:
            with self.subTest(result=str(result)[:100]), self.assertRaises(ValueError):
                replay_coat_studio(config, result)

    def test_xorshift_unsigned_vector_and_refill_are_platform_independent(self):
        random = XorShift32(1)
        self.assertEqual([random.next() for _ in range(5)],
                         [270369, 67634689, 2647435461, 307599695, 2398689233])
        state = HarvestState(build_harvest_chain_config(1))
        self.assertEqual(state.random.state, 1924455416)
        before = list(state.board)
        state.apply([0, 5, 6])
        # Column zero loses top two cells. Its unaffected lower four remain.
        self.assertEqual([state.board[r * 5] for r in range(2, 6)],
                         [before[r * 5] for r in range(2, 6)])
        self.assertEqual(state.collected, {'wheat': 0, 'barley': 0, 'oats': 3})
        self.assertEqual(state.random.state, 2518953779)

    def test_stuck_board_repair_consumes_no_rng_and_preserves_playable_boards(self):
        # Force a component-free field by using unique labels. Only the helper
        # is tested here; valid gameplay always uses the three authored grains.
        board = [str(index) for index in range(30)]
        self.assertIsNone(next(available_three_chains(board), None))
        self.assertTrue(ensure_harvest_move(board))
        self.assertEqual(board[:3], ['0', '0', '0'])
        before = list(board)
        self.assertFalse(ensure_harvest_move(board))
        self.assertEqual(board, before)
        for number in (1, 2, 3):
            state = HarvestState(build_harvest_chain_config(number))
            for _ in range(150):
                choices = list(available_three_chains(state.board))
                self.assertTrue(choices)
                if state.completed or len(state.chains) == state.config['max_chains']:
                    state = HarvestState(state.config)
                else:
                    state.apply(choices[-1])

    def test_harvest_invalid_cells_jumps_mixed_grains_and_client_state_rejected(self):
        config = build_harvest_chain_config(1)
        invalid = [
            {'chains': [[0, 5]]}, {'chains': [[0, 5, 0]]},
            {'chains': [[0, 5, True]]}, {'chains': [[0, 5, 30]]},
            {'chains': [[0, 5, 27]]}, {'chains': [[0, 1, 2]]},
            {'chains': [], 'board': [0] * 30}, {'chains': [], 'collected': {'oats': 100}},
            {'chains': None}, {'chains': [[0, 5, 6]] * 31},
        ]
        for result in invalid:
            with self.subTest(result=str(result)[:100]), self.assertRaises(ValueError):
                replay_harvest_chain(config, result)

    def test_no_commands_after_goal_or_move_limit_and_no_partial_reward(self):
        config = build_harvest_chain_config(1)
        winning = example_harvest_chain_result(config)
        state = HarvestState(config)
        for chain in winning['chains']:
            state.apply(chain)
        with self.assertRaises(ValueError):
            state.apply(next(available_three_chains(state.board)))
        limited = deepcopy(config)
        limited['max_chains'] = 3
        result = {'chains': winning['chains'][:3]}
        self.assertFalse(replay_harvest_chain(limited, result)['completed'])
        with self.assertRaises(ValueError):
            replay_harvest_chain(limited, {'chains': winning['chains'][:4]})
        self.assertEqual(replay_harvest_chain(config, {'chains': []})['score'], 0)

    def test_schema_rejects_bool_seed_bad_goals_duplicate_attrs_and_unknown_fields(self):
        candidates = []
        for field, value in (('seed', True), ('seed', 0), ('seed', 2 ** 32),
                             ('rows', True), ('columns', 30), ('min_chain', 2),
                             ('max_chains', 0), ('goals', {'wheat': 1}), ('score', 100)):
            config = build_harvest_chain_config(1)
            config[field] = value
            candidates.append(config)
        config = build_coat_studio_config(1)
        config['swatches'][0] = deepcopy(config['swatches'][1])
        candidates.append(config)
        for config in candidates:
            with self.subTest(config=config), self.assertRaises(ValidationError):
                validate_level_definition(game_type='matching', config=config,
                                          max_score=100, star_thresholds=[60, 80, 95])


class MatchingStudioApiTests(TestCase):
    def setUp(self):
        with patch(BACKUP, return_value=Path('/private/tmp/test-matching-backup.sqlite3')):
            call_command('install_matching_studio', publish=True, stdout=io.StringIO())
        self.parent = User.objects.create_user(email='matching-studio@example.com',
            password='Matching-test-123!', email_verified_at=timezone.now())
        self.profile = KidProfile.objects.create(parent=self.parent, display_name='Ada', avatar_key='lion')
        self.client = APIClient()
        self.client.force_authenticate(self.parent)

    def level(self, slug, number=1):
        return GameLevel.objects.select_related('game').get(game__slug=slug, level_number=number)

    def result(self, level):
        return (example_coat_studio_result(level.config) if level.config['mode'] == 'coat_studio'
                else example_harvest_chain_result(level.config))

    def submit(self, level, result=None, operation=None, profile=None):
        return self.client.post(f'/api/games/{level.game.slug}/submit/', {
            'profile_id': str(profile or self.profile.pk), 'level_number': level.level_number,
            'operation_id': str(operation or uuid.uuid4()),
            'result': self.result(level) if result is None else result}, format='json')

    def test_new_modes_public_visual_metadata_preserved_and_server_scoring(self):
        for slug in ('josephs-coat-studio', 'ruths-harvest'):
            for number in (1, 2, 3):
                level = self.level(slug, number)
                public = public_level_config(level)
                self.assertEqual(public, level.config)
                public['scene'] = 'changed'
                self.assertNotEqual(public['scene'], level.config['scene'])
                evaluation = evaluate_level(level, self.result(level))
                self.assertTrue(evaluation.completed)
                self.assertGreaterEqual(evaluation.stars, 2)
                response = self.submit(level)
                self.assertEqual(response.status_code, 201)
                self.assertTrue(response.data['completed'])
                self.assertEqual(response.data['score'], evaluation.score)
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 6)
        for progress in KidGameProgress.objects.filter(profile=self.profile):
            self.assertEqual(progress.highest_completed_level, 3)
            self.assertTrue(all(value['completion_xp'] == 50 for value in progress.level_progress.values()))

    def test_both_games_use_idempotency_conflicts_level_locks_and_single_xp_award(self):
        for slug in ('josephs-coat-studio', 'ruths-harvest'):
            level = self.level(slug)
            self.assertEqual(self.submit(self.level(slug, 2)).status_code, 400)
            operation = uuid.uuid4()
            first = self.submit(level, operation=operation)
            retry = self.submit(level, operation=operation)
            empty = {'actions': []} if level.config['mode'] == 'coat_studio' else {'chains': []}
            conflict = self.submit(level, empty, operation=operation)
            self.assertEqual((first.status_code, retry.status_code, conflict.status_code), (201, 200, 409))
            self.assertEqual(first.data['attempt_id'], retry.data['attempt_id'])
            self.assertTrue(retry.data['idempotent_replay'])
            progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
            self.assertEqual(progress.level_progress['1']['completion_xp'], 50)
            self.assertEqual(progress.level_progress['1']['attempts'], 1)
        expected_xp = 100 + 20 * sum(progress.total_stars for progress in KidGameProgress.objects.filter(profile=self.profile))
        self.assertEqual(build_profile_level(self.profile)['xp'], expected_xp)
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 2)

    def test_partial_attempts_get_no_xp_and_claimed_rewards_and_foreign_profile_rejected(self):
        other = User.objects.create_user(email='foreign-matching@example.com', password='Foreign-test-123!')
        foreign = KidProfile.objects.create(parent=other, display_name='Other', avatar_key='lion')
        for slug in ('josephs-coat-studio', 'ruths-harvest'):
            level = self.level(slug)
            empty = {'actions': []} if level.config['mode'] == 'coat_studio' else {'chains': []}
            response = self.submit(level, empty)
            self.assertEqual(response.status_code, 201)
            self.assertFalse(response.data['completed'])
            self.assertEqual(response.data['stars'], 0)
            self.assertEqual(self.submit(level, {**self.result(level), 'score': 100}).status_code, 400)
            self.assertEqual(self.submit(level, profile=foreign.pk).status_code, 404)
        self.assertEqual(build_profile_level(self.profile)['xp'], 0)

    def test_staging_idempotence_and_legacy_history_preserved(self):
        retired = Game.objects.get(slug='ark-animal-match')
        progress = KidGameProgress.objects.create(profile=self.profile, game=retired,
            highest_completed_level=1, level_progress={'1': {'completed': True, 'completion_xp': 100, 'best_stars': 3}})
        previous = (retired.pk, retired.is_published, deepcopy(progress.level_progress))
        ids = list(GameLevel.objects.filter(game__slug__in=('josephs-coat-studio', 'ruths-harvest')).values_list('pk', flat=True))
        with patch(BACKUP) as backup:
            call_command('install_matching_studio', stdout=io.StringIO())
            call_command('install_matching_studio', stdout=io.StringIO())
            backup.assert_not_called()
        progress.refresh_from_db()
        retired.refresh_from_db()
        self.assertEqual((retired.pk, retired.is_published, progress.level_progress), previous)
        self.assertEqual(list(GameLevel.objects.filter(game__slug__in=('josephs-coat-studio', 'ruths-harvest')).values_list('pk', flat=True)), ids)

    def test_conflicting_rules_with_played_history_fail_before_backup(self):
        level = self.level('josephs-coat-studio')
        self.assertEqual(self.submit(level).status_code, 201)
        config = deepcopy(level.config)
        config['panels'][0]['color'], config['panels'][1]['color'] = config['panels'][1]['color'], config['panels'][0]['color']
        GameLevel.objects.filter(pk=level.pk).update(config=config)
        with patch(BACKUP) as backup, self.assertRaises(CommandError):
            call_command('install_matching_studio', stdout=io.StringIO())
        backup.assert_not_called()
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 1)

    def test_dry_run_has_no_writes_and_default_install_is_unpublished(self):
        Game.objects.filter(slug__in=('josephs-coat-studio', 'ruths-harvest')).delete()
        with patch(BACKUP) as backup:
            call_command('install_matching_studio', dry_run=True, stdout=io.StringIO())
            backup.assert_not_called()
        self.assertFalse(Game.objects.filter(slug='josephs-coat-studio').exists())
        with patch(BACKUP, return_value=Path('/private/tmp/test-backup.sqlite3')):
            call_command('install_matching_studio', stdout=io.StringIO())
        self.assertEqual(Game.objects.filter(slug__in=('josephs-coat-studio', 'ruths-harvest'), is_published=False).count(), 2)
