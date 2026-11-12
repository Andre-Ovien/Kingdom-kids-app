"""Cross-language curve and shared-corridor fixtures; no game is published."""

import copy
import json
import os
from pathlib import Path
import unittest

from .ark_garden import replay_ark_garden, validate_ark_garden_config
from .ark_garden_path import GardenPath


def course():
    return json.loads(Path(__file__).with_name('content').joinpath(
        'ark_garden_curve_contract_v2.json').read_text())


class ArkGardenCurveTests(unittest.TestCase):
    def test_python_dart_shared_curve_and_queue_snapshots(self):
        config = course()
        content = Path(__file__).with_name('content')
        fixtures = Path(__file__).resolve().parents[4] / 'Frontend/mobile/test/fixtures'
        for name in ('ark_garden_curve_contract_v2.json', 'ark_garden_curve_replay_v2.json'):
            self.assertEqual(json.loads((content / name).read_text()),
                             json.loads((fixtures / name).read_text()))
        for scenario in json.loads((content / 'ark_garden_curve_replay_v2.json').read_text())['scenarios']:
            with self.subTest(scenario=scenario['name']):
                self.assertEqual(replay_ark_garden(config, scenario['result']), scenario['expected'])

    def test_curved_distance_not_straight_shortcut_and_heading_flows_into_stairs(self):
        animal = course()['garden']['animals'][0]
        path = GardenPath(animal['route'], animal['approach_curves'])
        direct = ((animal['route'][1]['x'] - animal['route'][0]['x']) ** 2 +
                  (animal['route'][1]['y'] - animal['route'][0]['y']) ** 2) ** .5
        self.assertGreater(path.approach_length, direct)
        turn = path.sample(path.approach_length * .5)
        self.assertNotEqual(turn['curvature'], 0)
        before = path.sample(path.approach_length - 1e-6)
        after = path.sample(path.approach_length + 1e-6)
        self.assertLess(abs(before['heading'] - after['heading']), 1e-5)
        self.assertLess(abs(before['curvature']), 1e-5)

    def test_one_owner_boards_before_next_animal_moves_and_tap_is_not_repeated(self):
        config = course()
        taps = [{'tick': 0, 'animal_id': a['id']} for a in config['garden']['animals']]
        first = replay_ark_garden(config, {'taps': taps, 'elapsed_ticks': 10})
        self.assertNotEqual(first['positions']['elephant'], [3, 1, 0])
        self.assertEqual(first['positions']['lion'], [3, 2.2, 0])
        done = replay_ark_garden(config, {'taps': taps, 'elapsed_ticks': 600})
        self.assertEqual(done['animals_boarded'], 10)
        self.assertLess(done['arrival_ticks']['elephant'], done['arrival_ticks']['lion'])
        self.assertEqual(done, replay_ark_garden(config, {
            'taps': taps + [{'tick': 100, 'animal_id': 'elephant'}], 'elapsed_ticks': 600,
        }))

    def test_bounded_authored_tangents_clearance_and_gate_are_required(self):
        changes = [
            lambda a: a.update(body_rear_units=2),
            lambda a: a.update(body_width_units=0),
            lambda a: a.update(queue_gate_distance_units=100),
            lambda a: a.pop('queue_gate_distance_units'),
            lambda a: a['approach_curves'][0][1].update(z=.1),
            lambda a: a['approach_curves'][0][-1].update(x=27),
            lambda a: a['approach_curves'][0][-2].update(x=27),
            lambda a: a.update(approach_curves=[]),
            lambda a: a.update(approach_curves=[a['approach_curves'][0]] * 5),
            lambda a: a['approach_curves'][0][0].update(x=float('nan')),
        ]
        for change in changes:
            config = course()
            change(config['garden']['animals'][0])
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_ark_garden_config(config)

    def test_failed_deadline_and_missing_animals_cannot_complete(self):
        config = course()
        taps = [{'tick': 0, 'animal_id': a['id']} for a in config['garden']['animals'][:-1]]
        missing = replay_ark_garden(config, {'taps': taps, 'elapsed_ticks': 600})
        late = replay_ark_garden(config, {
            'taps': taps + [{'tick': 599, 'animal_id': 'rabbit'}], 'elapsed_ticks': 600,
        })
        self.assertFalse(missing['completed'])
        self.assertFalse(late['completed'])
        self.assertEqual(missing['animals_boarded'], 9)
        self.assertEqual(late['animals_boarded'], 9)

    def test_replay_does_not_mutate_authored_geometry(self):
        config = course()
        before = copy.deepcopy(config)
        replay_ark_garden(config, {'taps': [], 'elapsed_ticks': 600})
        self.assertEqual(config, before)


if os.environ.get('DJANGO_SETTINGS_MODULE'):
    import uuid
    from django.test import TestCase
    from apps.progress.services import build_profile_level
    from .models import GameAttempt, KidGameProgress
    from .test_ark_garden import ArkGardenApiTests

    class ArkGardenCurveApiTests(TestCase):
        publish_test_fixture = ArkGardenApiTests.publish_test_fixture
        submit = ArkGardenApiTests.submit

        def setUp(self):
            ArkGardenApiTests.setUp(self)
            self.level.config = course()
            self.level.save(update_fields=['config'])

        def test_queue_replay_and_receipt_retries_award_completion_only_once(self):
            self.publish_test_fixture()
            taps = [{'tick': 0, 'animal_id': a['id']} for a in self.level.config['garden']['animals']]
            result = {'elapsed_ticks': 379, 'taps': taps}
            operation = uuid.uuid4()
            first = self.submit(result, operation_id=operation)
            retry = self.submit(result, operation_id=operation)
            replay = self.submit(result)
            self.assertEqual(first.status_code, 201)
            self.assertTrue(first.data['completed'])
            self.assertEqual(first.data['score'], 100)
            self.assertEqual(first.data['stars'], 3)
            self.assertEqual(retry.status_code, 200)
            self.assertEqual(first.data['attempt_id'], retry.data['attempt_id'])
            self.assertEqual(replay.status_code, 201)
            self.assertEqual(GameAttempt.objects.count(), 2)
            self.assertEqual(build_profile_level(self.profile)['xp'], 110)
            progress = KidGameProgress.objects.get(profile=self.profile, game=self.game)
            self.assertEqual(progress.highest_completed_level, 1)

        def test_ten_taps_before_queue_finished_cannot_earn_completion(self):
            self.publish_test_fixture()
            taps = [{'tick': 0, 'animal_id': a['id']} for a in self.level.config['garden']['animals']]
            response = self.submit({'elapsed_ticks': 100, 'taps': taps})
            self.assertEqual(response.status_code, 201)
            self.assertFalse(response.data['completed'])
            self.assertEqual(response.data['score'], 20)
            self.assertEqual(response.data['stars'], 0)
            self.assertEqual(build_profile_level(self.profile)['xp'], 0)

        def test_js_arrival_or_position_claims_cannot_replace_authoritative_replay(self):
            self.publish_test_fixture()
            response = self.submit({'elapsed_ticks': 1, 'taps': [],
                                    'positions': {'elephant': [28, 13, 4.3]}})
            self.assertEqual(response.status_code, 400)
            self.assertEqual(GameAttempt.objects.count(), 0)
