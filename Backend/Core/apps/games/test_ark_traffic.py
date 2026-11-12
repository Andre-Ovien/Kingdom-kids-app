"""Pure replay tests: these need no Django settings or database."""

import copy
import os
import unittest

from .ark_traffic import (
    MAX_COMMANDS, build_ark_traffic_config, public_ark_traffic_config,
    replay_ark_traffic, validate_ark_traffic_config,
)


def simple_config(*, species='rabbit', terrain='trail', gate=False, progress=0):
    return {
        'mode': 'ark_traffic',
        'traffic': {
            'tick_ms': 100, 'time_limit_ticks': 1800, 'target_jam_ticks': 100,
            'nodes': [
                {'id': 'home', 'x': .10, 'y': .50},
                {'id': 'junction', 'x': .30, 'y': .50},
                {'id': 'detour', 'x': .30, 'y': .30},
                {'id': 'ark', 'x': .50, 'y': .50},
            ],
            'edges': [
                {'id': 'first', 'a': 'home', 'b': 'junction', 'width': .12,
                 'terrain': terrain, 'gate': 'gate-a' if gate else None, 'route_group': 'bridge'},
                {'id': 'last', 'a': 'junction', 'b': 'ark', 'width': .12,
                 'terrain': 'trail', 'gate': None},
                {'id': 'branch', 'a': 'junction', 'b': 'detour', 'width': .12,
                 'terrain': 'trail', 'gate': None, 'route_group': 'east'},
                {'id': 'return', 'a': 'detour', 'b': 'ark', 'width': .12,
                 'terrain': 'trail', 'gate': None},
            ],
            'animals': [{'id': 'friend', 'species': species, 'start_node': 'home',
                         'route': ['home', 'junction', 'ark'], 'start_progress': progress}],
            'gates': [{'id': 'gate-a', 'open': False}] if gate else [],
            'ark_node': 'ark',
            'replay_challenges': [
                {'id': 'smooth', 'kind': 'no_jam', 'label': 'Smooth rescue'},
                {'id': 'explore', 'kind': 'different_routes', 'label': 'Other trails'},
            ],
        },
    }


def result(ticks=100, commands=None):
    return {'elapsed_ticks': ticks, 'commands': commands or []}


class ArkTrafficReplayTests(unittest.TestCase):
    def test_authored_rounds_preserve_legacy_fields_and_hide_answers(self):
        legacy = {
            'left_items': [{'id': 'lion-1', 'label': 'Lion', 'asset_key': 'animal:lion'}],
            'right_items': [{'id': 'lion-2', 'label': 'Lion', 'asset_key': 'animal:lion'}],
            'expected_pairs': {'lion-1': 'lion-2'}, 'goal_pairs': 1,
        }
        for number, count, limit in ((1, 8, 1200), (2, 10, 1500), (3, 12, 1800)):
            with self.subTest(number=number):
                config = build_ark_traffic_config(number, legacy)
                validate_ark_traffic_config(config)
                self.assertEqual(config['expected_pairs'], legacy['expected_pairs'])
                public = public_ark_traffic_config(config)
                self.assertNotIn('expected_pairs', public)
                self.assertNotIn('goal_pairs', public)
                self.assertEqual(public['traffic']['time_limit_ticks'], limit)
                self.assertEqual(len(public['traffic']['animals']), count)
                public['traffic']['nodes'][0]['x'] = .99
                self.assertNotEqual(public['traffic']['nodes'][0], config['traffic']['nodes'][0])

    def test_replay_boards_animal_and_derives_score(self):
        details = replay_ark_traffic(simple_config(), result())
        self.assertTrue(details['completed'])
        self.assertEqual(details['animals_boarded'], 1)
        self.assertEqual(details['jam_ticks'], 0)
        self.assertEqual(details['score'], 90)
        self.assertEqual(details['challenges_achieved'], ['smooth'])
        self.assertEqual(details['positions']['friend'], [.5, .5])

    def test_authored_rounds_require_child_drawn_routes_to_board(self):
        for number in (1, 2, 3):
            config = build_ark_traffic_config(number)
            details = replay_ark_traffic(config, result(config['traffic']['time_limit_ticks']))
            self.assertEqual(details['animals_boarded'], 0)
            self.assertFalse(details['completed'])

    def test_one_edge_per_tick_discards_leftover_distance(self):
        details = replay_ark_traffic(simple_config(), result(20))
        self.assertAlmostEqual(details['positions']['friend'][0], .3)
        details = replay_ark_traffic(simple_config(), result(21))
        self.assertAlmostEqual(details['positions']['friend'][0], .3105)

    def test_wait_resume_excludes_deliberate_wait_from_jams(self):
        details = replay_ark_traffic(simple_config(), result(50, [
            {'tick': 0, 'op': 'wait', 'animal_id': 'friend'},
            {'tick': 30, 'op': 'resume', 'animal_id': 'friend'},
        ]))
        self.assertFalse(details['completed'])
        self.assertEqual(details['jam_ticks'], 0)
        self.assertAlmostEqual(details['positions']['friend'][0], .3)

    def test_gate_blocks_mid_edge_and_toggle_releases_it(self):
        config = simple_config(gate=True, progress=.5)
        details = replay_ark_traffic(config, result(10))
        self.assertEqual(details['jam_ticks'], 10)
        self.assertEqual(details['positions']['friend'], [.2, .5])
        details = replay_ark_traffic(config, result(80, [
            {'tick': 10, 'op': 'gate', 'gate_id': 'gate-a'},
        ]))
        self.assertTrue(details['completed'])
        self.assertEqual(details['jam_ticks'], 10)
        self.assertEqual(details['score'], 88)

    def test_mid_edge_route_preserves_travel_to_upcoming_junction(self):
        config = simple_config(progress=.5)
        command = {'tick': 0, 'op': 'route', 'animal_id': 'friend',
                   'nodes': ['junction', 'detour', 'ark']}
        details = replay_ark_traffic(config, result(1, [command]))
        self.assertAlmostEqual(details['positions']['friend'][0], .2105)
        self.assertEqual(details['positions']['friend'][1], .5)
        details = replay_ark_traffic(config, result(100, [command]))
        self.assertTrue(details['completed'])
        self.assertEqual(details['score'], 100)
        self.assertEqual(details['challenges_achieved'], ['smooth', 'explore'])
        command['nodes'] = ['home', 'junction', 'ark']
        with self.assertRaises(ValueError):
            replay_ark_traffic(config, result(1, [command]))

    def test_route_can_stop_at_junction(self):
        details = replay_ark_traffic(simple_config(progress=.5), result(100, [
            {'tick': 0, 'op': 'route', 'animal_id': 'friend', 'nodes': ['junction']},
        ]))
        self.assertFalse(details['completed'])
        self.assertEqual(details['positions']['friend'], [.3, .5])
        self.assertEqual(details['jam_ticks'], 0)

    def test_collision_stops_follower_and_counts_its_jams(self):
        config = simple_config()
        config['traffic']['animals'].append({
            'id': 'blocker', 'species': 'elephant', 'start_node': 'junction',
        })
        details = replay_ark_traffic(config, result(100))
        self.assertFalse(details['completed'])
        self.assertGreater(details['animal_jam_ticks']['friend'], 0)
        self.assertEqual(details['animal_jam_ticks']['blocker'], 0)
        self.assertLess(details['positions']['friend'][0], .30 - (.018 + .038) * .90)

    def test_initial_overlap_allows_increasing_separation(self):
        config = simple_config()
        config['traffic']['animals'].append({
            'id': 'other', 'species': 'rabbit', 'start_node': 'home',
        })
        details = replay_ark_traffic(config, result(1))
        self.assertAlmostEqual(details['positions']['friend'][0], .1105)
        self.assertEqual(details['jam_ticks'], 0)

    def test_wait_yields_to_recover_a_blocked_junction(self):
        config = simple_config()
        config['traffic']['animals'].append({
            'id': 'blocker', 'species': 'elephant', 'start_node': 'junction',
        })
        details = replay_ark_traffic(config, result(120, [
            {'tick': 20, 'op': 'wait', 'animal_id': 'blocker'},
            {'tick': 60, 'op': 'route', 'animal_id': 'blocker', 'nodes': ['junction', 'ark']},
            {'tick': 60, 'op': 'resume', 'animal_id': 'blocker'},
        ]))
        self.assertTrue(details['completed'])
        self.assertGreater(details['jam_ticks'], 0)
        self.assertEqual(details['animal_jam_ticks']['blocker'], 0)

    def test_mud_species_speeds(self):
        rabbit = replay_ark_traffic(simple_config(terrain='mud'), result(1))
        goat = replay_ark_traffic(simple_config(species='goat', terrain='mud'), result(1))
        self.assertAlmostEqual(rabbit['positions']['friend'][0], .1 + .0105 * .45)
        self.assertAlmostEqual(goat['positions']['friend'][0], .1 + .0072 * .75)

    def test_unknown_extra_result_fields_are_rejected(self):
        for field in ('score', 'stars', 'completed', 'positions'):
            with self.subTest(field=field), self.assertRaises(ValueError):
                replay_ark_traffic(simple_config(), {**result(), field: 100})

    def test_time_and_command_bounds_are_strict_real_integers(self):
        for ticks in (-1, True, 1.2, '1', None, 1801):
            with self.subTest(ticks=ticks), self.assertRaises(ValueError):
                replay_ark_traffic(simple_config(), result(ticks))
        with self.assertRaises(ValueError):
            replay_ark_traffic(simple_config(), result(1, [
                {'tick': 0, 'op': 'wait', 'animal_id': 'friend'},
            ] * (MAX_COMMANDS + 1)))

    def test_invalid_commands_are_rejected_even_at_final_tick(self):
        invalid = [
            {'tick': 0, 'op': 'wait', 'animal_id': 'missing'},
            {'tick': 0, 'op': 'gate', 'gate_id': 'missing'},
            {'tick': True, 'op': 'wait', 'animal_id': 'friend'},
            {'tick': 2, 'op': 'wait', 'animal_id': 'friend'},
            {'tick': 0, 'op': 'route', 'animal_id': 'friend', 'nodes': ['home', 'ark']},
            {'tick': 0, 'op': 'route', 'animal_id': 'friend', 'nodes': [[], 'ark']},
            {'tick': 0, 'op': 'wait', 'animal_id': 'friend', 'score': 100},
            {'tick': 0, 'op': 'fly', 'animal_id': 'friend'},
        ]
        for command in invalid:
            with self.subTest(command=command), self.assertRaises(ValueError):
                replay_ark_traffic(simple_config(), result(1, [command]))
        with self.assertRaises(ValueError):
            replay_ark_traffic(simple_config(), result(1, [
                {'tick': 1, 'op': 'wait', 'animal_id': 'friend'},
                {'tick': 0, 'op': 'resume', 'animal_id': 'friend'},
            ]))

    def test_final_tick_command_applies_without_movement(self):
        config = simple_config(gate=True)
        details = replay_ark_traffic(config, result(1, [
            {'tick': 1, 'op': 'gate', 'gate_id': 'gate-a'},
        ]))
        self.assertEqual(details['positions']['friend'], [.1, .5])
        self.assertEqual(details['jam_ticks'], 1)

    def test_boarded_animal_commands_are_rejected(self):
        with self.assertRaises(ValueError):
            replay_ark_traffic(simple_config(), result(100, [
                {'tick': 100, 'op': 'wait', 'animal_id': 'friend'},
            ]))

    def test_unsuitable_edges_and_malformed_configs_are_rejected(self):
        mutations = [
            lambda t: t.update(tick_ms=True),
            lambda t: t.update(time_limit_ticks=1801),
            lambda t: t['nodes'][0].update(x=float('nan')),
            lambda t: t['nodes'][0].update(x=10 ** 1000),
            lambda t: t['nodes'][1].update(id='home'),
            lambda t: t['animals'][0].update(species=[]),
            lambda t: t['animals'][0].update(start_progress=1),
            lambda t: t['edges'][0].update(width=.03),
            lambda t: t['edges'][0].update(terrain='rocky'),
            lambda t: t['edges'][0].update(gate='unknown'),
            lambda t: t['edges'][0].update(route_group='unknown'),
            lambda t: t.update(unknown=True),
        ]
        for mutate in mutations:
            config = simple_config()
            mutate(config['traffic'])
            with self.subTest(config=config), self.assertRaises(ValueError):
                validate_ark_traffic_config(config)

    def test_replay_is_deterministic_and_does_not_mutate_inputs(self):
        config, submission = build_ark_traffic_config(3), result(500)
        before_config, before_result = copy.deepcopy(config), copy.deepcopy(submission)
        self.assertEqual(replay_ark_traffic(config, submission), replay_ark_traffic(config, submission))
        self.assertEqual(config, before_config)
        self.assertEqual(submission, before_result)


# Django's test runner adds these HTTP/persistence checks to the same suite;
# ordinary unittest keeps the pure replay suite usable without Django setup.
if os.environ.get('DJANGO_SETTINGS_MODULE'):
    import importlib
    import uuid
    from types import SimpleNamespace

    from django.apps import apps
    from django.db import connection
    from django.test import TestCase
    from django.utils import timezone
    from rest_framework.test import APIClient

    from apps.accounts.models import KidProfile, User
    from apps.progress.services import build_profile_level
    from .models import GameAttempt, GameLevel, KidGameProgress

    class ArkTrafficApiTests(TestCase):
        def setUp(self):
            self.parent = User.objects.create_user(
                email='ark-traffic@example.com', password='ArkTraffic-test-123!',
                email_verified_at=timezone.now(),
            )
            self.profile = KidProfile.objects.create(
                parent=self.parent, display_name='Ada', avatar_key=KidProfile.AvatarKey.DOVE,
            )
            self.client = APIClient()
            self.client.force_authenticate(self.parent)
            self.level = GameLevel.objects.get(game__slug='ark-animal-match', level_number=1)
            # The catalogue retires Match. Publish only this test fixture to
            # keep the preserved Ark command protocol and scoring covered.
            self.level.game.is_published = True
            self.level.game.save(update_fields=['is_published'])

        def submit(self, submission, *, operation_id=None, profile=None, level=1):
            return self.client.post('/api/games/ark-animal-match/submit/', {
                'profile_id': str(profile or self.profile.pk),
                'level_number': level, 'operation_id': str(operation_id or uuid.uuid4()),
                'result': submission,
            }, format='json')

        def easy_round(self, number=1):
            level = GameLevel.objects.get(game=self.level.game, level_number=number)
            level.config = simple_config()
            level.save(update_fields=['config'])

        def test_authored_public_map_has_no_private_matching_key(self):
            response = self.client.get('/api/games/ark-animal-match/', {
                'profile_id': str(self.profile.pk),
            })
            self.assertEqual(response.status_code, 200)
            for level in response.data['levels']:
                self.assertEqual(level['config']['mode'], 'ark_traffic')
                self.assertIn('traffic', level['config'])
                self.assertNotIn('expected_pairs', level['config'])
            self.level.full_clean()

        def test_command_result_is_authoritative_and_failed_round_does_not_unlock(self):
            response = self.submit(result(100))
            self.assertEqual(response.status_code, 201)
            self.assertFalse(response.data['completed'])
            self.assertEqual(response.data['stars'], 0)
            self.assertEqual(response.data['progress']['highest_completed_level'], 0)
            self.assertEqual(build_profile_level(self.profile)['xp'], 0)
            for submission in ({**result(), 'score': 100}, {**result(), 'completed': True},
                               result(1, [{'tick': 0, 'op': 'wait', 'animal_id': 'unicorn'}])):
                self.assertEqual(self.submit(submission).status_code, 400)
            self.assertEqual(GameAttempt.objects.count(), 1)

        def test_completion_and_idempotent_replay_keep_50_xp_plus_star_award(self):
            self.easy_round()
            operation = uuid.uuid4()
            first = self.submit(result(), operation_id=operation)
            replay = self.submit(result(), operation_id=operation)
            conflict = self.submit(result(99), operation_id=operation)
            self.assertEqual(first.status_code, 201)
            self.assertEqual(replay.status_code, 200)
            self.assertEqual(conflict.status_code, 409)
            self.assertEqual(first.data['attempt_id'], replay.data['attempt_id'])
            self.assertTrue(first.data['completed'])
            self.assertEqual(first.data['score'], 90)
            stars = first.data['stars']
            self.assertEqual(build_profile_level(self.profile)['xp'], 50 + stars * 20)
            progress = KidGameProgress.objects.get(profile=self.profile, game=self.level.game)
            self.assertEqual(progress.level_progress['1']['completion_xp'], 50)
            self.assertEqual(progress.level_progress['1']['attempts'], 1)
            self.assertEqual(GameAttempt.objects.count(), 1)

        def test_locked_round_requires_previous_completion(self):
            self.easy_round(1)
            self.easy_round(2)
            self.assertEqual(self.submit(result(), level=2).status_code, 400)
            self.assertEqual(GameAttempt.objects.count(), 0)
            self.assertEqual(self.submit(result(), level=1).status_code, 201)
            self.assertEqual(self.submit(result(), level=2).status_code, 201)
            progress = KidGameProgress.objects.get(profile=self.profile, game=self.level.game)
            self.assertEqual(progress.highest_completed_level, 2)

        def test_another_parents_profile_cannot_submit(self):
            other = User.objects.create_user(email='other-ark@example.com', password='Other-test-123!')
            profile = KidProfile.objects.create(parent=other, display_name='Other', avatar_key=KidProfile.AvatarKey.DOVE)
            self.assertEqual(self.submit(result(), profile=profile.pk).status_code, 404)
            self.assertEqual(GameAttempt.objects.count(), 0)

        def test_content_refresh_preserves_all_catalogue_and_ark_level_ids(self):
            before = set(GameLevel.objects.values_list('pk', flat=True))
            ark_ids = set(GameLevel.objects.filter(game=self.level.game).values_list('pk', flat=True))
            legacy = copy.deepcopy(self.level.config['expected_pairs'])
            migration = importlib.import_module('apps.games.migrations.0014_ark_traffic_routes')
            migration.author_ark_traffic(apps, SimpleNamespace(connection=connection))
            self.assertEqual(set(GameLevel.objects.values_list('pk', flat=True)), before)
            self.assertEqual(set(GameLevel.objects.filter(game=self.level.game).values_list('pk', flat=True)), ark_ids)
            self.level.refresh_from_db()
            self.assertEqual(self.level.config['expected_pairs'], legacy)


if __name__ == '__main__':
    unittest.main()
