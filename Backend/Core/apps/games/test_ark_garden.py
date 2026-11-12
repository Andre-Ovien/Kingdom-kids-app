"""Course/replay and real API receipt checks for the held Ark garden mode."""

import copy
import json
import math
import os
from pathlib import Path
import unittest

from .ark_garden import (
    MAX_TAPS, SPECIES, build_ark_garden_config, public_ark_garden_config,
    replay_ark_garden, validate_ark_garden_config,
)


def all_taps(config, tick=0):
    return [{'tick': tick, 'animal_id': animal['id']} for animal in config['garden']['animals']]


def submission(config, elapsed=600, taps=None):
    return {'elapsed_ticks': elapsed, 'taps': all_taps(config) if taps is None else taps}


def short_course():
    config = build_ark_garden_config()
    for animal in config['garden']['animals']:
        animal['body_length_units'] = .1
        animal['speed_units_per_second'] = 1
        animal['route'] = [
            {'x': 0, 'y': 0, 'z': 0, 'phase': 'garden'},
            {'x': .1, 'y': 0, 'z': 0, 'phase': 'stairs'},
            {'x': .1, 'y': .1, 'z': .1, 'phase': 'stairs'},
            {'x': .1, 'y': .2, 'z': .1, 'phase': 'door'},
            {'x': .1, 'y': .3, 'z': .1, 'phase': 'interior'},
        ]
    return config


class ArkGardenReplayTests(unittest.TestCase):
    def test_draft_has_ten_unique_species_and_public_copy_is_detached(self):
        config = build_ark_garden_config()
        public = public_ark_garden_config(config)
        self.assertEqual(config['garden']['time_limit_ticks'], 600)
        self.assertEqual(tuple(animal['species'] for animal in public['garden']['animals']), SPECIES)
        public['garden']['animals'][0]['route'][0]['x'] = 9
        self.assertEqual(config['garden']['animals'][0]['route'][0]['x'], 3)

    def test_shared_course_and_replay_fixtures_match_the_authoritative_contract(self):
        content = Path(__file__).with_name('content')
        course = json.loads((content / 'ark_garden_course_v1.json').read_text())
        self.assertEqual(course, build_ark_garden_config())
        golden = json.loads((content / 'ark_garden_replay_v1.json').read_text())
        for scenario in golden['scenarios']:
            with self.subTest(scenario=scenario['name']):
                self.assertEqual(replay_ark_garden(course, scenario['result']), scenario['expected'])
        for scenario in golden['rejections']:
            with self.subTest(scenario=scenario['name']), self.assertRaises(ValueError):
                replay_ark_garden(course, scenario['result'])

    def test_no_animal_moves_or_boards_without_a_tap(self):
        config = build_ark_garden_config()
        replay = replay_ark_garden(config, submission(config, taps=[]))
        self.assertFalse(replay['completed'])
        self.assertEqual(replay['score'], 0)
        self.assertEqual(replay['animals_boarded'], 0)
        for animal in config['garden']['animals']:
            self.assertEqual(replay['phases'][animal['id']], 'idle')
            self.assertEqual(replay['positions'][animal['id']],
                             [animal['route'][0][axis] for axis in ('x', 'y', 'z')])

    def test_distance_carries_across_joins_and_stair_elevation_is_interpolated(self):
        config = short_course()
        replay = replay_ark_garden(config, submission(config, elapsed=2))
        # First .1 unit garden segment consumes the first tick; second tick
        # moves .1 units along the .1414 unit three-dimensional stair segment.
        self.assertAlmostEqual(replay['positions']['elephant'][0], .1)
        self.assertAlmostEqual(replay['positions']['elephant'][1], .1 / math.sqrt(2))
        self.assertAlmostEqual(replay['positions']['elephant'][2], .1 / math.sqrt(2))
        self.assertEqual(replay['phases']['elephant'], 'stairs')
        self.assertEqual(replay['animals_boarded'], 0)

    def test_head_at_door_is_not_boarded_and_only_full_interior_arrival_counts(self):
        config = short_course()
        at_door = replay_ark_garden(config, submission(config, elapsed=4))
        inside = replay_ark_garden(config, submission(config, elapsed=5))
        self.assertLess(at_door['positions']['elephant'][1], .3)
        self.assertEqual(at_door['phases']['elephant'], 'interior')
        self.assertFalse(at_door['completed'])
        self.assertEqual(inside['arrival_ticks'], {species: 5 for species in SPECIES})
        self.assertEqual(inside['phases'], {species: 'boarded' for species in SPECIES})
        self.assertTrue(inside['completed'])
        self.assertEqual(inside['score'], 100)

    def test_repeated_taps_do_not_restart_or_accelerate_animal(self):
        config = short_course()
        taps = all_taps(config) + [{'tick': 3, 'animal_id': 'elephant'}]
        repeated = replay_ark_garden(config, submission(config, elapsed=5, taps=taps))
        original = replay_ark_garden(config, submission(config, elapsed=5))
        self.assertEqual(repeated, original)

    def test_all_ten_tapped_is_not_completion_until_all_arrive(self):
        config = short_course()
        taps = all_taps(config)[:-1] + [{'tick': 598, 'animal_id': 'rabbit'}]
        result = replay_ark_garden(config, submission(config, taps=taps))
        self.assertEqual(result['animals_boarded'], 9)
        self.assertEqual(result['score'], 90)
        self.assertFalse(result['completed'])
        self.assertNotIn('rabbit', result['arrival_ticks'])
        self.assertEqual(replay_ark_garden(config, submission(config, taps=all_taps(config)[:-1]))['animals_boarded'], 9)

    def test_snapshot_tick_tap_has_no_movement_and_deadline_tap_is_rejected(self):
        config = short_course()
        result = replay_ark_garden(config, submission(config, elapsed=500, taps=all_taps(config, tick=500)))
        self.assertEqual(result['animals_boarded'], 0)
        self.assertEqual(result['positions']['elephant'], [0, 0, 0])
        with self.assertRaises(ValueError):
            replay_ark_garden(config, submission(config, taps=all_taps(config, tick=600)))

    def test_cheating_unknown_malformed_late_and_unbounded_taps_are_rejected(self):
        config = short_course()
        invalid = [
            {**submission(config), 'score': 100},
            {**submission(config), 'completed': True},
            {**submission(config), 'arrival_ticks': {'elephant': 1}},
            submission(config, taps=[{'tick': 0, 'animal_id': 'unicorn'}]),
            submission(config, taps=[{'tick': 601, 'animal_id': 'elephant'}]),
            submission(config, taps=[{'tick': 2, 'animal_id': 'elephant'}, {'tick': 1, 'animal_id': 'lion'}]),
            submission(config, taps=[{'tick': 0, 'animal_id': 'elephant'}] * (MAX_TAPS + 1)),
            submission(config, taps=[{'tick': True, 'animal_id': 'elephant'}]),
            submission(config, taps=[{'tick': 0, 'animal_id': []}]),
            submission(config, elapsed=True), submission(config, elapsed=601),
            submission(config, elapsed=-1), submission(config, elapsed=2.5),
            {'elapsed_ticks': 600}, {'taps': []},
        ]
        for value in invalid:
            with self.subTest(result=value), self.assertRaises(ValueError):
                replay_ark_garden(config, value)

    def test_invalid_or_unwinnable_authored_geometry_is_rejected(self):
        mutations = [
            lambda g: g.update(version=True),
            lambda g: g.update(tick_ms=50),
            lambda g: g.update(time_limit_ticks=1801),
            lambda g: g['animals'].pop(),
            lambda g: g['animals'][0].update(species='lion'),
            lambda g: g['animals'][0].update(species=[]),
            lambda g: g['animals'][0].update(label='   '),
            lambda g: g['animals'][0].update(speed_units_per_second=.05),
            lambda g: g['animals'][0].update(body_length_units=10),
            lambda g: g['animals'][0]['route'][0].update(x=float('nan')),
            lambda g: g['animals'][0]['route'][0].update(x=10 ** 1000),
            lambda g: g['animals'][0]['route'][0].update(z=1),
            lambda g: g['animals'][0]['route'][3].update(z=0),
            lambda g: g['animals'][0]['route'][-2].update(z=4.4),
            lambda g: g['animals'][0]['route'][-1].update(phase='door'),
            lambda g: g['animals'][0]['route'][1].update(phase='interior'),
            lambda g: g['animals'][0].update(unknown=True),
        ]
        for mutate in mutations:
            config = build_ark_garden_config()
            mutate(config['garden'])
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                validate_ark_garden_config(config)

    def test_replay_is_deterministic_and_never_mutates_course_or_result(self):
        config = build_ark_garden_config()
        result = submission(config, elapsed=500)
        before = copy.deepcopy((config, result))
        self.assertEqual(replay_ark_garden(config, result), replay_ark_garden(config, result))
        self.assertEqual((config, result), before)


if os.environ.get('DJANGO_SETTINGS_MODULE'):
    import uuid
    from django.core.exceptions import ValidationError
    from django.test import TestCase
    from django.utils import timezone
    from rest_framework.test import APIClient
    from apps.accounts.models import KidProfile, User
    from apps.progress.services import build_profile_level
    from .models import Game, GameAttempt, GameLevel, KidGameProgress

    class ArkGardenApiTests(TestCase):
        def setUp(self):
            self.parent = User.objects.create_user(
                email='ark-garden@example.com', password='ArkGarden-test-123!',
                email_verified_at=timezone.now(),
            )
            self.profile = KidProfile.objects.create(
                parent=self.parent, display_name='Ada', avatar_key=KidProfile.AvatarKey.DOVE,
            )
            self.client = APIClient()
            self.client.force_authenticate(self.parent)
            # This brand-new unpublished test record never edits the old Ark
            # matching/traffic IDs or account history.
            self.game = Game.objects.create(
                slug='noahs-ark-garden', title="Noah's Ark Garden", subtitle='Help everyone aboard',
                description='Tap each animal to walk into the Ark.', game_type=Game.Type.MATCHING,
                cover_asset_key='story:noah', is_published=False,
            )
            self.level = GameLevel.objects.create(
                game=self.game, level_number=1, title='All aboard',
                instructions='Find all ten animals and help them inside before time runs out.',
                config=short_course(),
            )

        def publish_test_fixture(self):
            self.game.is_published = True
            self.game.save(update_fields=['is_published'])

        def submit(self, result=None, *, operation_id=None, profile=None, level=1):
            return self.client.post('/api/games/noahs-ark-garden/submit/', {
                'profile_id': str(profile or self.profile.pk), 'level_number': level,
                'operation_id': str(operation_id or uuid.uuid4()),
                'result': result if result is not None else submission(self.level.config, elapsed=5),
            }, format='json')

        def test_held_game_is_not_listed_playable_or_allowed_to_submit(self):
            catalogue = self.client.get('/api/games/', {'profile_id': str(self.profile.pk)})
            self.assertNotIn(self.game.slug, [game['slug'] for game in catalogue.data])
            detail = self.client.get('/api/games/noahs-ark-garden/', {'profile_id': str(self.profile.pk)})
            self.assertEqual(detail.status_code, 404)
            self.assertEqual(self.submit().status_code, 404)
            self.assertEqual(GameAttempt.objects.count(), 0)

        def test_published_fixture_exposes_only_one_authored_garden_level(self):
            self.publish_test_fixture()
            detail = self.client.get('/api/games/noahs-ark-garden/', {'profile_id': str(self.profile.pk)})
            self.assertEqual(detail.status_code, 200)
            self.assertEqual(len(detail.data['levels']), 1)
            self.assertEqual(detail.data['levels'][0]['config'], self.level.config)
            self.assertEqual(self.submit(level=2).status_code, 404)
            self.assertFalse(Game.objects.get(slug='ark-animal-match').is_published)

        def test_retry_and_new_operation_replay_do_not_duplicate_xp_or_completion(self):
            self.publish_test_fixture()
            operation = uuid.uuid4()
            first = self.submit(operation_id=operation)
            retry = self.submit(operation_id=operation)
            new_replay = self.submit()
            conflict = self.submit(submission(self.level.config, elapsed=6), operation_id=operation)
            self.assertEqual(first.status_code, 201)
            self.assertTrue(first.data['completed'])
            self.assertEqual(first.data['score'], 100)
            self.assertEqual(first.data['stars'], 3)
            self.assertEqual(retry.status_code, 200)
            self.assertEqual(first.data['attempt_id'], retry.data['attempt_id'])
            self.assertEqual(new_replay.status_code, 201)
            self.assertEqual(conflict.status_code, 409)
            self.assertEqual(build_profile_level(self.profile)['xp'], 50 + 3 * 20)
            progress = KidGameProgress.objects.get(profile=self.profile, game=self.game)
            self.assertEqual(progress.highest_completed_level, 1)
            self.assertEqual(progress.level_progress['1']['completion_xp'], 50)
            self.assertEqual(progress.level_progress['1']['attempts'], 2)
            self.assertEqual(GameAttempt.objects.count(), 2)

        def test_missing_or_late_animal_does_not_complete_or_award_xp(self):
            self.publish_test_fixture()
            taps = all_taps(self.level.config)[:-1]
            incomplete = self.submit(submission(self.level.config, taps=taps))
            late_taps = taps + [{'tick': 599, 'animal_id': 'rabbit'}]
            late = self.submit(submission(self.level.config, taps=late_taps))
            self.assertEqual(incomplete.status_code, 201)
            self.assertEqual(late.status_code, 201)
            for response in (incomplete, late):
                self.assertFalse(response.data['completed'])
                self.assertEqual(response.data['stars'], 0)
                self.assertEqual(response.data['progress']['highest_completed_level'], 0)
            self.assertEqual(build_profile_level(self.profile)['xp'], 0)

        def test_claimed_result_and_other_parents_profile_cannot_earn_awards(self):
            self.publish_test_fixture()
            invalid = {**submission(self.level.config), 'completed': True, 'score': 100}
            self.assertEqual(self.submit(invalid).status_code, 400)
            other = User.objects.create_user(email='other-garden@example.com', password='Other-test-123!')
            profile = KidProfile.objects.create(parent=other, display_name='Other', avatar_key=KidProfile.AvatarKey.DOVE)
            self.assertEqual(self.submit(profile=profile.pk).status_code, 404)
            self.assertEqual(GameAttempt.objects.count(), 0)

        def test_authoring_full_clean_routes_through_garden_validator(self):
            self.level.config['garden']['animals'][0]['body_length_units'] = 5
            with self.assertRaises(ValidationError):
                self.level.full_clean()


if __name__ == '__main__':
    unittest.main()
