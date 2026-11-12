import copy
import uuid
from collections import deque

from django.core.exceptions import ValidationError as DjangoValidationError
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import KidProfile, User
from apps.progress.services import build_profile_level

from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import GameResultError, evaluate_level, public_level_config


class OceanVoyageTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        # Keep exercising the preserved sailing engine while its catalogue
        # availability is paused by a later editorial migration.
        Game.objects.filter(slug='jonah-ocean-maze').update(is_published=True)
        cls.parent = User.objects.create_user(
            email='ocean-voyage@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        cls.profile = KidProfile.objects.create(
            parent=cls.parent,
            display_name='Ocean Explorer',
            avatar_key=KidProfile.AvatarKey.STAR,
        )
        cls.game = Game.objects.get(slug='jonah-ocean-maze')

    def setUp(self):
        self.level = self.game.levels.get(level_number=1)
        self.client = APIClient()
        token = RefreshToken.for_user(self.parent).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')

    @staticmethod
    def voyage(level, *, hit_indices=(), sample_interval=100):
        """Steer a continuous, speed-bounded route through the actual course."""

        sailing = level.config['sailing']
        keys = [(0, 0.0)]
        for index, obstacle in enumerate(sailing['obstacles']):
            x = (
                obstacle['x'] if index in hit_indices
                else (-0.6 if obstacle['x'] >= 0 else 0.6)
            )
            keys.append((round(obstacle['progress'] * 60_000), x))
        keys.append((60_000, keys[-1][1]))
        samples = []
        index = 0
        for milliseconds in range(0, 60_001, sample_interval):
            while index + 1 < len(keys) - 1 and keys[index + 1][0] < milliseconds:
                index += 1
            start, end = keys[index], keys[index + 1]
            fraction = (milliseconds - start[0]) / (end[0] - start[0])
            samples.append([milliseconds, start[1] + (end[1] - start[1]) * fraction])
        return {'voyage': {'duration_ms': 60_000, 'samples': samples}}

    def submit(self, result, *, operation_id=None):
        return self.client.post(
            '/api/games/jonah-ocean-maze/submit/',
            {
                'profile_id': str(self.profile.pk),
                'operation_id': str(operation_id or uuid.uuid4()),
                'level_number': 1,
                'result': result,
            },
            format='json',
        )

    @staticmethod
    def grid_route(grid):
        start, end = tuple(grid['start']), tuple(grid['end'])
        walls = {tuple(coordinate) for coordinate in grid['walls']}
        queue = deque([(start, [start])])
        seen = {start}
        while queue:
            (row, column), path = queue.popleft()
            if (row, column) == end:
                return [list(coordinate) for coordinate in path]
            for neighbor in ((row - 1, column), (row + 1, column),
                             (row, column - 1), (row, column + 1)):
                if (
                    0 <= neighbor[0] < grid['rows']
                    and 0 <= neighbor[1] < grid['columns']
                    and neighbor not in walls
                    and neighbor not in seen
                ):
                    seen.add(neighbor)
                    queue.append((neighbor, path + [neighbor]))
        raise AssertionError('The legacy route must remain traversable.')

    def test_published_courses_offer_full_minute_sailing_and_legacy_grid(self):
        response = self.client.get(
            '/api/games/jonah-ocean-maze/',
            {'profile_id': self.profile.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['estimated_duration_seconds'], 60)
        self.assertEqual(len(response.data['levels']), 3)
        for number, public_level in enumerate(response.data['levels'], 1):
            config = public_level['config']
            self.assertIn('grid', config)
            sailing = config['sailing']
            self.assertEqual(sailing['duration_seconds'], 60)
            self.assertEqual(sailing['distance_m'], 1200)
            self.assertEqual(sailing['max_hits'], 3)
            self.assertEqual(sailing['steer_speed'], 1.4)
            self.assertEqual(sailing['ship_radius'], 0.09)
            obstacles = sailing['obstacles']
            self.assertEqual(len(obstacles), {1: 12, 2: 15, 3: 19}[number])
            self.assertGreater(obstacles[0]['progress'], 0.12)
            self.assertLess(obstacles[-1]['progress'], 0.9)
            spacing = 0.06 if number == 1 else 0.035
            self.assertTrue(all(
                following['progress'] - previous['progress'] >= spacing
                for previous, following in zip(obstacles, obstacles[1:])
            ))
            level = self.game.levels.get(level_number=number)
            level.full_clean()
            safe = evaluate_level(level, self.voyage(level))
            self.assertTrue(safe.completed)
            self.assertEqual(safe.details['hit_count'], 0)
            self.assertEqual((safe.score, safe.stars), (100, 3))

    def test_public_sailing_config_does_not_leak_unrecognized_authored_fields(self):
        self.level.config['sailing']['private_hint'] = 'not public'
        self.level.config['sailing']['obstacles'][0]['private_note'] = 'not public'
        public = public_level_config(self.level)['sailing']
        self.assertNotIn('private_hint', public)
        self.assertNotIn('private_note', public['obstacles'][0])

    def test_collisions_are_unique_obstacles_and_control_score_and_stars(self):
        for hits, expected in ((0, (True, 100, 3)), (1, (True, 85, 2)),
                               (2, (True, 65, 1)), (3, (False, 35, 0))):
            with self.subTest(hits=hits):
                evaluated = evaluate_level(
                    self.level,
                    self.voyage(self.level, hit_indices=range(hits)),
                )
                self.assertEqual(
                    (evaluated.completed, evaluated.score, evaluated.stars),
                    expected,
                )
                self.assertEqual(evaluated.details['hit_count'], hits)
                self.assertEqual(len(evaluated.details['hit_obstacle_ids']), hits)

    def test_sparse_but_supported_samples_score_the_same_course(self):
        result = evaluate_level(self.level, self.voyage(self.level, sample_interval=250))
        self.assertTrue(result.completed)
        self.assertEqual(result.details['hit_count'], 0)

    def test_truncated_or_falsely_short_voyages_are_rejected(self):
        truncated = self.voyage(self.level)
        truncated['voyage']['samples'] = truncated['voyage']['samples'][:-1]
        falsely_short = self.voyage(self.level)
        falsely_short['voyage']['duration_ms'] = 59_900
        for result in (truncated, falsely_short):
            self.assertEqual(self.submit(result).status_code, 400)
        self.assertEqual(GameAttempt.objects.count(), 0)
        self.assertEqual(KidGameProgress.objects.count(), 0)

    def test_teleporting_or_missing_time_cannot_bypass_rocks(self):
        teleport = self.voyage(self.level)
        teleport['voyage']['samples'][1][1] = 1.0
        missing = self.voyage(self.level)
        del missing['voyage']['samples'][1:4]
        duplicate = self.voyage(self.level)
        duplicate['voyage']['samples'][2][0] = 100
        reverse = self.voyage(self.level)
        reverse['voyage']['samples'][2][0] = 50
        dense_speed = self.voyage(self.level)
        dense_speed['voyage']['samples'][1:1] = [[1, 0.002], [2, 0.004]]
        for result in (teleport, missing, duplicate, reverse, dense_speed):
            self.assertEqual(self.submit(result).status_code, 400)
        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_samples_require_finite_bounded_coordinates_and_integer_time(self):
        for invalid in (
            [100, float('nan')], [100, float('inf')], [100, -1.01],
            [100, True], [100.5, 0], [True, 0], [100], {'time': 100, 'x': 0},
        ):
            with self.subTest(invalid=invalid):
                result = self.voyage(self.level)
                result['voyage']['samples'][1] = invalid
                with self.assertRaises(GameResultError):
                    evaluate_level(self.level, result)
        bad_start = self.voyage(self.level)
        bad_start['voyage']['samples'][0] = [0, 0.1]
        self.assertEqual(self.submit(bad_start).status_code, 400)

    def test_client_cannot_supply_hit_counts_completion_or_score(self):
        for field, value in (('hit_count', 0), ('completed', True), ('score', 100)):
            result = self.voyage(self.level, hit_indices=range(3))
            result['voyage'][field] = value
            self.assertEqual(self.submit(result).status_code, 400)
            del result['voyage'][field]
            result[field] = value
            self.assertEqual(self.submit(result).status_code, 400)
        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_valid_full_voyage_is_idempotent_and_preserves_quest_xp_rules(self):
        operation = uuid.uuid4()
        result = self.voyage(self.level)
        created = self.submit(result, operation_id=operation)
        replay = self.submit(result, operation_id=operation)
        self.assertEqual(created.status_code, 201)
        self.assertEqual(replay.status_code, 200)
        self.assertTrue(replay.data['idempotent_replay'])
        self.assertEqual(replay.data['attempt_id'], created.data['attempt_id'])
        self.assertTrue(created.data['completed'])
        self.assertEqual(created.data['progress']['highest_completed_level'], 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)
        self.assertEqual(GameAttempt.objects.count(), 1)
        new_replay = self.submit(result)
        self.assertEqual(new_replay.status_code, 201)
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)

    def test_three_actual_hits_are_saved_as_failure_and_do_not_unlock(self):
        response = self.submit(self.voyage(self.level, hit_indices=range(3)))
        self.assertEqual(response.status_code, 201)
        self.assertFalse(response.data['completed'])
        self.assertEqual(response.data['stars'], 0)
        self.assertEqual(response.data['progress']['highest_completed_level'], 0)
        attempt = GameAttempt.objects.get(pk=response.data['attempt_id'])
        self.assertEqual(attempt.evaluation['hit_count'], 3)
        self.assertEqual(build_profile_level(self.profile)['xp'], 0)

    def test_legacy_jonah_grid_and_red_sea_path_evaluations_still_work(self):
        for slug in ('jonah-ocean-maze', 'red-sea-path'):
            level = GameLevel.objects.get(game__slug=slug, level_number=1)
            evaluated = evaluate_level(level, {'path': self.grid_route(level.config['grid'])})
            self.assertTrue(evaluated.completed)
            self.assertEqual((evaluated.score, evaluated.stars), (100, 3))
            if slug == 'red-sea-path':
                self.assertNotIn('sailing', public_level_config(level))
                with self.assertRaises(GameResultError):
                    evaluate_level(level, self.voyage(self.level))

    def test_admin_rejects_unsafe_sailing_geometry_and_duplicate_obstacles(self):
        original = copy.deepcopy(self.level.config)
        variants = []
        for field, value in (
            ('duration_seconds', 5), ('ship_radius', float('nan')),
            ('collision_window', 0), ('max_hits', 0), ('steer_speed', 0),
        ):
            config = copy.deepcopy(original)
            config['sailing'][field] = value
            variants.append(config)
        config = copy.deepcopy(original)
        config['sailing']['obstacles'][1]['id'] = config['sailing']['obstacles'][0]['id']
        variants.append(config)
        config = copy.deepcopy(original)
        config['sailing']['obstacles'][1]['progress'] = 0.151
        variants.append(config)
        for config in variants:
            self.level.config = config
            with self.assertRaises(DjangoValidationError):
                self.level.full_clean()
