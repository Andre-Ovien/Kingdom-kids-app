"""Scene-matching replay, API receipts and safe local catalogue installation."""

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
from .matching_collection import (
    build_creation_bloom_config, build_esther_table_config,
    build_sheep_reunion_config, example_scene_matching_result,
    public_scene_matching_config, replay_scene_matching,
    validate_scene_matching_config,
)
from .matching_studio import example_coat_studio_result
from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import evaluate_level, public_level_config
from .validators import validate_level_definition

CONTENT = Path(__file__).with_name('content') / 'matching_collection_v1.json'
BACKUP = 'apps.games.management.commands.install_matching_studio.backup_local_database'
BUILDERS = (build_sheep_reunion_config, build_creation_bloom_config, build_esther_table_config)
SLUGS = ('find-my-sheep', 'creation-match-bloom', 'esthers-celebration-table')
PREVIOUS_SLUGS = ('josephs-coat-studio', 'ruths-harvest')
RETIRED_SLUGS = ('ark-animal-match', 'moses-match', 'daniel-memory')


class MatchingCollectionReplayTests(SimpleTestCase):
    def test_all_nine_authored_rounds_are_valid_and_match_shared_replay_goldens(self):
        fixture = json.loads(CONTENT.read_text())
        for builder, key in zip(BUILDERS, ('sheep_rounds', 'creation_rounds', 'esther_rounds')):
            self.assertEqual(fixture[key], [builder(number) for number in (1, 2, 3)])
            for number in (1, 2, 3):
                config = builder(number)
                validate_level_definition(game_type='matching', config=config,
                                          max_score=100, star_thresholds=[60, 80, 95])
                result = example_scene_matching_result(config)
                outcome = replay_scene_matching(config, result)
                self.assertTrue(outcome['completed'])
                self.assertEqual(outcome['score'], 100)
                self.assertEqual((outcome['correct_placements'], outcome['mistakes'], outcome['attempts']), (6, 0, 6))
                self.assertEqual(sum(target['capacity'] for target in config['targets']), 6)
        self.assertEqual(len(fixture['golden']), 9)
        for golden in fixture['golden']:
            self.assertEqual(replay_scene_matching(golden['config'], golden['result']), golden['outcome'])

    def test_wrong_matches_are_nonfatal_but_reduce_completed_precision(self):
        for builder in BUILDERS:
            config = builder(2)
            result = example_scene_matching_result(config)
            first = config['items'][0]
            wrong = next(target for target in config['targets'] if target['match_key'] != first['match_key'])
            result['actions'].insert(0, {'item_id': first['id'], 'target_id': wrong['id']})
            outcome = replay_scene_matching(config, result)
            self.assertTrue(outcome['completed'])
            self.assertEqual((outcome['score'], outcome['mistakes'], outcome['attempts']), (96, 1, 7))
            partial = replay_scene_matching(config, {'actions': result['actions'][:1]})
            self.assertEqual((partial['score'], partial['correct_placements']), (0, 0))

    def test_sheep_color_alone_does_not_match_a_different_scarf_pattern(self):
        config = build_sheep_reunion_config(2)
        lamb = next(item for item in config['items'] if item['match_key'] == 'coral_dots')
        wrong = next(target for target in config['targets'] if target['match_key'] == 'coral_stripes')
        outcome = replay_scene_matching(config, {'actions': [{'item_id': lamb['id'], 'target_id': wrong['id']}]})
        self.assertFalse(outcome['completed'])
        self.assertEqual((outcome['correct_placements'], outcome['mistakes']), (0, 1))

    def test_partial_counts_follow_real_successful_placements_and_fill_capacity(self):
        config = build_sheep_reunion_config(1)
        target = config['targets'][0]
        family = [item for item in config['items'] if item['match_key'] == target['match_key']]
        other = next(item for item in config['items'] if item['match_key'] != target['match_key'])
        actions = [{'item_id': item['id'], 'target_id': target['id']} for item in family]
        actions.append({'item_id': other['id'], 'target_id': target['id']})
        outcome = replay_scene_matching(config, {'actions': actions})
        self.assertFalse(outcome['completed'])
        self.assertEqual((outcome['correct_placements'], outcome['mistakes'], outcome['score']), (2, 1, 17))
        self.assertEqual(list(outcome['placements'].values()).count(target['id']), target['capacity'])

    def test_untrusted_reward_claims_unknown_ids_duplicate_and_nested_fields_rejected(self):
        for builder in BUILDERS:
            config = builder(1)
            first = example_scene_matching_result(config)['actions'][0]
            invalid = [
                {'actions': [], 'score': 100}, {'actions': [], 'stars': 3},
                {'actions': [], 'completed': True}, {'actions': [], 'placements': {}},
                {'actions': [first, first]},
                {'actions': [{**first, 'correct': True}]},
                {'actions': [{'item_id': 'missing', 'target_id': first['target_id']}]},
                {'actions': [{'item_id': first['item_id'], 'target_id': 'missing'}]},
                {'actions': [{'item_id': [], 'target_id': first['target_id']}]},
                {'actions': [{'item_id': first['item_id'], 'target_id': True}]},
                {'actions': [None]}, {'actions': None}, {'actions': 'actions'}, [],
            ]
            for result in invalid:
                with self.subTest(mode=config['mode'], result=str(result)[:100]), self.assertRaises(ValueError):
                    replay_scene_matching(config, result)

    def test_attempt_cap_is_bounded_and_inputs_stop_after_completion(self):
        config = build_esther_table_config(1)
        first = config['items'][0]
        wrong_target = next(t for t in config['targets'] if t['match_key'] != first['match_key'])
        wrong = {'item_id': first['id'], 'target_id': wrong_target['id']}
        outcome = replay_scene_matching(config, {'actions': [wrong] * 120})
        self.assertEqual((outcome['attempts'], outcome['mistakes'], outcome['correct_placements']), (120, 120, 0))
        with self.assertRaises(ValueError):
            replay_scene_matching(config, {'actions': [wrong] * 121})
        result = example_scene_matching_result(config)
        result['actions'].append(wrong)
        with self.assertRaises(ValueError):
            replay_scene_matching(config, result)

    def test_config_rejects_bad_schema_and_capacity_not_backed_by_items(self):
        candidates = []
        for field, value in (('mode', 'unknown'), ('mode', []), ('scene', 'another_scene'),
                             ('round_number', True), ('round_number', 0), ('round_number', 4),
                             ('targets', []), ('items', []), ('score', 100)):
            config = build_sheep_reunion_config(1)
            config[field] = value
            candidates.append(config)
        for field, value in (('capacity', True), ('capacity', 0), ('capacity', 3),
                             ('match_key', 'unknown_dots'), ('id', ''), ('bonus', 1)):
            config = build_sheep_reunion_config(1)
            config['targets'][0][field] = value
            candidates.append(config)
        for list_name in ('targets', 'items'):
            config = build_sheep_reunion_config(1)
            config[list_name][1] = deepcopy(config[list_name][0])
            candidates.append(config)
        config = build_creation_bloom_config(1)
        config['items'][0]['match_key'] = 'meadow'
        candidates.append(config)
        config = build_esther_table_config(1)
        config['items'][0]['id'] = 'unicorn'
        candidates.append(config)
        for config in candidates:
            with self.subTest(config=config), self.assertRaises(ValueError):
                validate_scene_matching_config(config)
            with self.assertRaises(ValidationError):
                validate_level_definition(game_type='matching', config=config,
                                          max_score=100, star_thresholds=[60, 80, 95])

    def test_public_visual_references_are_copied_without_shared_mutable_state(self):
        for builder in BUILDERS:
            config = builder(1)
            public = public_scene_matching_config(config)
            self.assertEqual(public, config)
            public['items'][0]['match_key'] = 'changed'
            public['targets'][0]['capacity'] = 100
            self.assertNotEqual(public, config)
            validate_scene_matching_config(config)


class MatchingCollectionApiTests(TestCase):
    def setUp(self):
        with patch(BACKUP, return_value=Path('/private/tmp/test-matching-backup.sqlite3')):
            call_command('install_matching_collection', publish=True, stdout=io.StringIO())
        self.parent = User.objects.create_user(email='matching-collection@example.com',
            password='Collection-test-123!', email_verified_at=timezone.now())
        self.profile = KidProfile.objects.create(parent=self.parent, display_name='Ada', avatar_key='lion')
        self.client = APIClient()
        self.client.force_authenticate(self.parent)

    def level(self, slug, number=1):
        return GameLevel.objects.select_related('game').get(game__slug=slug, level_number=number)

    def submit(self, level, result=None, *, operation=None, profile=None):
        return self.client.post(f'/api/games/{level.game.slug}/submit/', {
            'profile_id': str(profile or self.profile.pk), 'level_number': level.level_number,
            'operation_id': str(operation or uuid.uuid4()),
            'result': example_scene_matching_result(level.config) if result is None else result}, format='json')

    def test_all_nine_levels_public_metadata_and_authoritative_completion(self):
        for slug in SLUGS:
            response = self.client.get(f'/api/games/{slug}/', {'profile_id': self.profile.pk})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data['game_type'], 'matching')
            self.assertEqual(response.data['total_levels'], 3)
            for number in (1, 2, 3):
                level = self.level(slug, number)
                self.assertEqual(response.data['levels'][number - 1]['config'], level.config)
                self.assertEqual(public_level_config(level), level.config)
                evaluation = evaluate_level(level, example_scene_matching_result(level.config))
                self.assertEqual((evaluation.completed, evaluation.score, evaluation.stars), (True, 100, 3))
                receipt = self.submit(level)
                self.assertEqual(receipt.status_code, 201)
                self.assertEqual((receipt.data['completed'], receipt.data['score'], receipt.data['stars']), (True, 100, 3))
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 9)
        self.assertEqual(build_profile_level(self.profile)['xp'], 9 * (50 + 3 * 20))

    def test_retries_unlocks_conflicts_and_replays_cannot_duplicate_completion_xp(self):
        for slug in SLUGS:
            level = self.level(slug)
            self.assertEqual(self.submit(self.level(slug, 2)).status_code, 400)
            operation = uuid.uuid4()
            first = self.submit(level, operation=operation)
            retry = self.submit(level, operation=operation)
            conflict = self.submit(level, {'actions': []}, operation=operation)
            replay = self.submit(level)
            self.assertEqual((first.status_code, retry.status_code, conflict.status_code, replay.status_code), (201, 200, 409, 201))
            self.assertEqual(first.data['attempt_id'], retry.data['attempt_id'])
            self.assertTrue(retry.data['idempotent_replay'])
            progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
            self.assertEqual(progress.level_progress['1']['completion_xp'], 50)
            self.assertEqual(progress.level_progress['1']['attempts'], 2)
            self.assertEqual(self.submit(self.level(slug, 2)).status_code, 201)
        self.assertEqual(build_profile_level(self.profile)['xp'], 6 * (50 + 3 * 20))

    def test_partial_is_nonrewarding_and_forged_or_foreign_submissions_rejected(self):
        foreign = User.objects.create_user(email='foreign-collection@example.com', password='Foreign-test-123!')
        other = KidProfile.objects.create(parent=foreign, display_name='Other', avatar_key='lion')
        for slug in SLUGS:
            level = self.level(slug)
            partial = {'actions': example_scene_matching_result(level.config)['actions'][:2]}
            response = self.submit(level, partial)
            self.assertEqual(response.status_code, 201)
            self.assertFalse(response.data['completed'])
            self.assertEqual(response.data['stars'], 0)
            self.assertEqual(self.submit(level, {**partial, 'score': 100}).status_code, 400)
            self.assertEqual(self.submit(level, profile=other.pk).status_code, 404)
        self.assertEqual(build_profile_level(self.profile)['xp'], 0)
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 3)

    def test_unknown_item_and_duplicate_claims_become_api_400_not_server_errors(self):
        for slug in SLUGS:
            level = self.level(slug)
            action = example_scene_matching_result(level.config)['actions'][0]
            for result in ({'actions': [action, action]},
                           {'actions': [{'item_id': [], 'target_id': action['target_id']}]},
                           {'actions': [{'item_id': 'unknown', 'target_id': action['target_id']}]}):
                self.assertEqual(self.submit(level, result).status_code, 400)
        self.assertFalse(GameAttempt.objects.filter(profile=self.profile).exists())


class MatchingCollectionInstallerTests(TestCase):
    def setUp(self):
        with patch(BACKUP, return_value=Path('/private/tmp/test-previous-backup.sqlite3')):
            call_command('install_matching_studio', publish=True, stdout=io.StringIO())
        self.parent = User.objects.create_user(email='matching-install@example.com',
            password='Install-test-123!', email_verified_at=timezone.now())
        self.profile = KidProfile.objects.create(parent=self.parent, display_name='Ada', avatar_key='lion')
        self.client = APIClient()
        self.client.force_authenticate(self.parent)
        level = GameLevel.objects.get(game__slug=PREVIOUS_SLUGS[0], level_number=1)
        response = self.client.post(f'/api/games/{level.game.slug}/submit/', {
            'profile_id': str(self.profile.pk), 'level_number': 1,
            'operation_id': str(uuid.uuid4()), 'result': example_coat_studio_result(level.config)}, format='json')
        self.assertEqual(response.status_code, 201)
        retired = Game.objects.get(slug=RETIRED_SLUGS[0])
        KidGameProgress.objects.create(profile=self.profile, game=retired, highest_completed_level=1,
            level_progress={'1': {'completed': True, 'completion_xp': 100, 'best_stars': 3}})

    @staticmethod
    def snapshot_existing():
        return {
            'games': list(Game.objects.exclude(slug__in=SLUGS).order_by('pk').values()),
            'levels': list(GameLevel.objects.exclude(game__slug__in=SLUGS).order_by('pk').values()),
            'progress': list(KidGameProgress.objects.order_by('pk').values()),
            'attempts': list(GameAttempt.objects.order_by('pk').values()),
            'parents': list(User.objects.order_by('pk').values()),
            'profiles': list(KidProfile.objects.order_by('pk').values()),
        }

    def test_default_stage_is_unpublished_idempotent_and_preserves_every_existing_game_and_history(self):
        before = self.snapshot_existing()
        with patch(BACKUP, return_value=Path('/private/tmp/test-collection-backup.sqlite3')) as backup:
            call_command('install_matching_collection', stdout=io.StringIO())
            staged_games = list(Game.objects.filter(slug__in=SLUGS).order_by('pk').values())
            staged_levels = list(GameLevel.objects.filter(game__slug__in=SLUGS).order_by('pk').values())
            call_command('install_matching_collection', stdout=io.StringIO())
            self.assertEqual(backup.call_count, 1)
        self.assertEqual(Game.objects.filter(slug__in=SLUGS, is_published=False).count(), 3)
        self.assertEqual(GameLevel.objects.filter(game__slug__in=SLUGS).count(), 9)
        self.assertEqual(self.snapshot_existing(), before)
        self.assertEqual(list(Game.objects.filter(slug__in=SLUGS).order_by('pk').values()), staged_games)
        self.assertEqual(list(GameLevel.objects.filter(game__slug__in=SLUGS).order_by('pk').values()), staged_levels)
        for slug in SLUGS:
            self.assertEqual(self.client.get(f'/api/games/{slug}/', {'profile_id': self.profile.pk}).status_code, 404)

    def test_publish_adds_only_new_three_and_preserves_first_two_and_retired_history(self):
        before = self.snapshot_existing()
        published_before = set(Game.objects.filter(is_published=True).values_list('slug', flat=True))
        with patch(BACKUP, return_value=Path('/private/tmp/test-collection-backup.sqlite3')) as backup:
            call_command('install_matching_collection', stdout=io.StringIO())
            ids = list(GameLevel.objects.filter(game__slug__in=SLUGS).order_by('pk').values_list('pk', flat=True))
            call_command('install_matching_collection', publish=True, stdout=io.StringIO())
            call_command('install_matching_collection', publish=True, stdout=io.StringIO())
            self.assertEqual(backup.call_count, 2)
        self.assertEqual(self.snapshot_existing(), before)
        self.assertEqual(set(Game.objects.filter(is_published=True).values_list('slug', flat=True)), published_before | set(SLUGS))
        self.assertEqual(list(GameLevel.objects.filter(game__slug__in=SLUGS).order_by('pk').values_list('pk', flat=True)), ids)
        self.assertFalse(Game.objects.filter(slug__in=RETIRED_SLUGS, is_published=True).exists())
        response = self.client.get('/api/games/', {'profile_id': self.profile.pk})
        matching_slugs = {item['slug'] for item in response.data if item['game_type'] == 'matching'}
        self.assertTrue(set(SLUGS + PREVIOUS_SLUGS) <= matching_slugs)

    def test_dry_run_and_conflicting_existing_identity_do_not_create_partial_collection(self):
        before = self.snapshot_existing()
        with patch(BACKUP) as backup:
            call_command('install_matching_collection', dry_run=True, stdout=io.StringIO())
            backup.assert_not_called()
        self.assertFalse(Game.objects.filter(slug__in=SLUGS).exists())
        self.assertEqual(self.snapshot_existing(), before)
        # The middle identity conflicts, so the first new game must not be
        # created either, even though its definition was checked earlier.
        Game.objects.create(slug=SLUGS[1], title='Existing unrelated game', subtitle='Keep me',
            description='Preserve this identity', game_type=Game.Type.AIM,
            cover_asset_key='story:david', is_published=False)
        with patch(BACKUP) as backup, self.assertRaises(CommandError):
            call_command('install_matching_collection', publish=True, stdout=io.StringIO())
        backup.assert_not_called()
        self.assertFalse(Game.objects.filter(slug__in=(SLUGS[0], SLUGS[2])).exists())

    def test_played_new_rules_cannot_be_overwritten_by_a_later_install(self):
        with patch(BACKUP, return_value=Path('/private/tmp/test-collection-backup.sqlite3')):
            call_command('install_matching_collection', publish=True, stdout=io.StringIO())
        level = GameLevel.objects.get(game__slug=SLUGS[0], level_number=1)
        response = self.client.post(f'/api/games/{level.game.slug}/submit/', {
            'profile_id': str(self.profile.pk), 'level_number': 1,
            'operation_id': str(uuid.uuid4()),
            'result': example_scene_matching_result(level.config)}, format='json')
        self.assertEqual(response.status_code, 201)
        config = deepcopy(level.config)
        config['targets'].reverse()
        validate_scene_matching_config(config)
        GameLevel.objects.filter(pk=level.pk).update(config=config)
        before = list(GameAttempt.objects.order_by('pk').values())
        with patch(BACKUP) as backup, self.assertRaises(CommandError):
            call_command('install_matching_collection', stdout=io.StringIO())
        backup.assert_not_called()
        level.refresh_from_db()
        self.assertEqual(level.config, config)
        self.assertEqual(list(GameAttempt.objects.order_by('pk').values()), before)

    def test_installer_uses_real_bundled_cover_assets_and_rejects_nonlocal_database(self):
        from .management.commands.install_matching_collection import DEFINITIONS
        mobile = Path(__file__).resolve().parents[4] / 'Frontend/mobile'
        for definition in DEFINITIONS:
            self.assertTrue((mobile / definition['cover_asset_key']).is_file(), definition['cover_asset_key'])
        with patch('apps.games.management.commands.install_matching_studio.settings.DATABASES',
                   {'default': {'ENGINE': 'django.db.backends.postgresql', 'NAME': 'unrelated'}}), patch(BACKUP) as backup:
            with self.assertRaises(CommandError):
                call_command('install_matching_collection', stdout=io.StringIO())
            backup.assert_not_called()
