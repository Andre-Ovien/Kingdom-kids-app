import copy
import importlib
import uuid
from collections import deque
from types import SimpleNamespace

from django.apps import apps
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import connection
from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import KidProfile, User
from apps.progress.services import build_profile_level

from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import GameResultError, evaluate_level, public_level_config
from .validators import crossing_drop_contains, validate_crossing_config


class CrossingLandGeometryTests(SimpleTestCase):
    def setUp(self):
        self.crossing = {
            'time_limit_seconds': 45,
            'travellers': [{'id': 'traveller-1', 'label': 'Traveller 1'}],
            'drop_zone': {
                'left': 0.34, 'top': 0.43, 'right': 0.66, 'bottom': 0.70,
                'polygon': [[0.43, 0.33], [0.57, 0.33], [0.705, 0.43],
                            [0.855, 0.70], [0.145, 0.70], [0.295, 0.43]],
            },
        }

    def test_perspective_land_accepts_dry_edges_and_rejects_water(self):
        for reverse in (False, True):
            zone = copy.deepcopy(self.crossing['drop_zone'])
            if reverse:
                zone['polygon'].reverse()
            validate_crossing_config({**self.crossing, 'drop_zone': zone})
            for point in zone['polygon'] + [[0.25, 0.60], [0.75, 0.60], [0.5, 0.35]]:
                with self.subTest(reverse=reverse, point=point):
                    self.assertTrue(crossing_drop_contains(zone, *point))
            for point in [[0.10, 0.60], [0.93, 0.60], [0.5, 0.71], [0.2, 0.35]]:
                self.assertFalse(crossing_drop_contains(zone, *point))

    def test_legacy_rectangular_land_remains_inclusive(self):
        zone = self.crossing['drop_zone']
        del zone['polygon']
        validate_crossing_config(self.crossing)
        self.assertTrue(crossing_drop_contains(zone, 0.34, 0.43))
        self.assertTrue(crossing_drop_contains(zone, 0.66, 0.70))
        self.assertFalse(crossing_drop_contains(zone, 0.75, 0.60))

    def test_invalid_authored_polygons_cannot_be_published(self):
        invalid_polygons = [
            None, [], [[0.1, 0.1], [0.9, 0.9]],
            [[0.1, 0.1], [0.9, 0.9], [0.1, 0.9], [0.9, 0.1]],
            [[0.1, 0.1], [0.9, 0.1], [0.5, 0.5], [0.9, 0.9], [0.1, 0.9]],
            [[0.1, 0.1], [0.5, 0.5], [0.9, 0.9]],
            [[0.1, 0.1], [0.9, 0.1], [0.9, 0.1], [0.1, 0.9]],
            [[0.1, 0.1], [float('nan'), 0.1], [0.1, 0.9]],
            [[0.1, 0.1], [float('inf'), 0.1], [0.1, 0.9]],
            [[0.1, 0.1], [True, 0.1], [0.1, 0.9]],
            [[0.1, 0.1], [1.1, 0.1], [0.1, 0.9]],
            [[0.1, 0.1], [0.9, 0.1, 0.2], [0.1, 0.9]],
            [[0.1, 0.1]] * 17,
        ]
        for polygon in invalid_polygons:
            with self.subTest(polygon=polygon):
                self.crossing['drop_zone']['polygon'] = polygon
                with self.assertRaises(ValueError):
                    validate_crossing_config(self.crossing)

    def test_nonfinite_drop_coordinates_never_enter_land(self):
        for value in (float('nan'), float('inf'), True, None, '0.5'):
            self.assertFalse(crossing_drop_contains(self.crossing['drop_zone'], value, 0.60))
            self.assertFalse(crossing_drop_contains(self.crossing['drop_zone'], 0.5, value))


class RedSeaCrossingTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.parent = User.objects.create_user(
            email='red-sea-crossing@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        cls.profile = KidProfile.objects.create(
            parent=cls.parent,
            display_name='Path Helper',
            avatar_key=KidProfile.AvatarKey.STAR,
        )
        cls.game = Game.objects.get(slug='red-sea-path')
        # The shipped quest is retired. Explicitly publish this legacy fixture
        # so its preserved submission protocol and scorer remain covered.
        Game.objects.filter(pk=cls.game.pk).update(is_published=True)
        cls.game.is_published = True

    def setUp(self):
        self.level = self.game.levels.get(level_number=1)
        self.client = APIClient()
        token = RefreshToken.for_user(self.parent).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')

    @staticmethod
    def result(level, *, elapsed_ms=None, count=None):
        travellers = level.config['crossing']['travellers']
        if elapsed_ms is None:
            elapsed_ms = min(20_000, level.config['crossing']['time_limit_seconds'] * 500)
        count = len(travellers) if count is None else count
        return {'crossing': {
            'elapsed_ms': elapsed_ms,
            'placements': [
                {
                    'traveller_id': traveller['id'],
                    'x': 0.5,
                    'y': 0.6,
                    'released_at_ms': round(elapsed_ms * (index + 1) / len(travellers)),
                }
                for index, traveller in enumerate(travellers[:count])
            ],
        }}

    def submit(self, result, *, level_number=1, operation_id=None):
        return self.client.post(
            '/api/games/red-sea-path/submit/',
            {
                'profile_id': str(self.profile.pk),
                'operation_id': str(operation_id or uuid.uuid4()),
                'level_number': level_number,
                'result': result,
            },
            format='json',
        )

    def test_authored_family_courses_have_increasing_crowds_and_shorter_timers(self):
        response = self.client.get(
            '/api/games/red-sea-path/',
            {'profile_id': self.profile.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['estimated_duration_seconds'], 45)
        for number, public_level in enumerate(response.data['levels'], 1):
            crossing = public_level['config']['crossing']
            count, seconds = {1: (10, 45), 2: (15, 30), 3: (20, 15)}[number]
            self.assertEqual(crossing['time_limit_seconds'], seconds)
            self.assertEqual(
                [traveller['id'] for traveller in crossing['travellers']],
                [f'traveller-{index + 1}' for index in range(count)],
            )
            self.assertEqual(
                [traveller['label'].split()[0] for traveller in crossing['travellers'][:3]],
                ['Father', 'Mother', 'Child'],
            )
            self.assertIn(f'all {count} people', public_level['instructions'])
            self.assertIn(f'{seconds}-second', public_level['instructions'])
            self.assertEqual(crossing['drop_zone'], {
                'left': 0.34, 'top': 0.43, 'right': 0.66, 'bottom': 0.70,
                'polygon': [[0.43, 0.33], [0.57, 0.33], [0.705, 0.43],
                            [0.855, 0.70], [0.145, 0.70], [0.295, 0.43]],
            })
            self.assertIn('grid', public_level['config'])
            level = self.game.levels.get(level_number=number)
            level.full_clean()
            evaluated = evaluate_level(level, self.result(level))
            self.assertTrue(evaluated.completed)
            self.assertEqual(evaluated.details['rescued_count'], count)

    def test_each_round_accepts_its_final_drop_and_rejects_overrun(self):
        for level in self.game.levels.all():
            limit_ms = level.config['crossing']['time_limit_seconds'] * 1000
            with self.subTest(level=level.level_number):
                last_moment = self.result(level, elapsed_ms=limit_ms - 1)
                evaluated = evaluate_level(level, last_moment)
                self.assertTrue(evaluated.completed)
                self.assertEqual((evaluated.score, evaluated.stars), (65, 1))
                self.assertEqual(
                    evaluated.details['rescued_count'],
                    len(level.config['crossing']['travellers']),
                )
                incomplete = evaluate_level(
                    level, self.result(level, elapsed_ms=limit_ms, count=1),
                )
                self.assertFalse(incomplete.completed)
                self.assertEqual(incomplete.stars, 0)
                with self.assertRaises(GameResultError):
                    evaluate_level(level, self.result(level, elapsed_ms=limit_ms + 1))

    def test_family_migration_preserves_lane_grid_level_ids_and_earned_progress(self):
        submitted = self.submit(self.result(self.level))
        self.assertEqual(submitted.status_code, 201)
        original_progress = KidGameProgress.objects.filter(profile=self.profile).values().get()
        original_attempt = GameAttempt.objects.values().get()
        original_profile = KidProfile.objects.filter(pk=self.profile.pk).values().get()
        for level in self.game.levels.all():
            config = copy.deepcopy(level.config)
            old_count = {1: 6, 2: 8, 3: 10}[level.level_number]
            config['crossing']['travellers'] = config['crossing']['travellers'][:old_count]
            config['crossing']['time_limit_seconds'] = 45
            GameLevel.objects.filter(pk=level.pk).update(config=config)
        original_levels = list(self.game.levels.values())
        migration = importlib.import_module('apps.games.migrations.0013_crossing_family_rounds')
        migration.expand_crossing_families(apps, SimpleNamespace(connection=connection))
        self.assertEqual(
            original_progress,
            KidGameProgress.objects.filter(profile=self.profile).values().get(),
        )
        self.assertEqual(original_attempt, GameAttempt.objects.values().get())
        self.assertEqual(original_profile, KidProfile.objects.filter(pk=self.profile.pk).values().get())
        for original, updated in zip(original_levels, self.game.levels.values(), strict=True):
            self.assertEqual(original['id'], updated['id'])
            self.assertEqual(original['config']['grid'], updated['config']['grid'])
            self.assertEqual(
                original['config']['crossing']['drop_zone'],
                updated['config']['crossing']['drop_zone'],
            )
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)

    def test_server_scores_truthful_full_drops_by_active_placement_time(self):
        for elapsed_ms, expected in (
            (20_000, (100, 3)), (27_000, (100, 3)),
            (27_001, (85, 2)), (38_250, (85, 2)),
            (38_251, (65, 1)), (45_000, (65, 1)),
        ):
            with self.subTest(elapsed_ms=elapsed_ms):
                evaluated = evaluate_level(self.level, self.result(self.level, elapsed_ms=elapsed_ms))
                self.assertTrue(evaluated.completed)
                self.assertEqual((evaluated.score, evaluated.stars), expected)

    def test_walk_hold_and_paused_time_do_not_reduce_earned_star_rating(self):
        # The result describes only the placement timer. Sea-opening, app
        # pauses and a final walk can finish much later in real wall-clock time.
        operation = uuid.uuid4()
        result = self.result(self.level, elapsed_ms=20_000)
        created = self.submit(result, operation_id=operation)
        replay = self.submit(result, operation_id=operation)
        self.assertEqual(created.status_code, 201)
        self.assertEqual((created.data['score'], created.data['stars']), (100, 3))
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.data['stars'], 3)
        self.assertEqual(replay.data['attempt_id'], created.data['attempt_id'])
        self.assertEqual(GameAttempt.objects.count(), 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)

    def test_last_second_drop_is_accepted_independently_of_later_walk_finish(self):
        result = self.result(self.level, elapsed_ms=44_999)
        result['crossing']['placements'][-1]['released_at_ms'] = 44_999
        evaluated = evaluate_level(self.level, result)
        self.assertTrue(evaluated.completed)
        self.assertEqual((evaluated.score, evaluated.stars), (65, 1))

    def test_timeout_with_missing_travellers_is_an_honest_failed_attempt(self):
        for count in (0, 5):
            with self.subTest(count=count):
                response = self.submit(self.result(self.level, elapsed_ms=45_000, count=count))
                self.assertEqual(response.status_code, 201)
                self.assertFalse(response.data['completed'])
                self.assertEqual(response.data['stars'], 0)
                self.assertEqual(response.data['progress']['highest_completed_level'], 0)
                attempt = GameAttempt.objects.get(pk=response.data['attempt_id'])
                self.assertEqual(attempt.evaluation['rescued_count'], count)
        self.assertEqual(build_profile_level(self.profile)['xp'], 0)

    def test_water_drops_or_off_viewport_coordinates_are_rejected(self):
        for x, y in ((0.10, 0.6), (0.90, 0.6), (0.5, 0.32),
                     (0.5, 0.71), (-1, 0.6), (0.5, 2)):
            result = self.result(self.level)
            result['crossing']['placements'][0].update(x=x, y=y)
            self.assertEqual(self.submit(result).status_code, 400)
        self.assertEqual(GameAttempt.objects.count(), 0)
        self.assertEqual(KidGameProgress.objects.count(), 0)

    def test_authored_dry_zone_edges_are_valid_normalized_release_points(self):
        result = self.result(self.level)
        result['crossing']['placements'][0].update(x=0.43, y=0.33)
        result['crossing']['placements'][1].update(x=0.855, y=0.70)
        self.assertTrue(evaluate_level(self.level, result).completed)

    def test_visible_dry_ground_outside_old_rectangle_accepts_real_drops(self):
        result = self.result(self.level)
        result['crossing']['placements'][0].update(x=0.25, y=0.60)
        result['crossing']['placements'][1].update(x=0.75, y=0.60)
        result['crossing']['placements'][2].update(x=0.5, y=0.35)
        self.assertTrue(evaluate_level(self.level, result).completed)

    def test_older_crossing_course_keeps_its_rectangular_drop_rules(self):
        del self.level.config['crossing']['drop_zone']['polygon']
        result = self.result(self.level)
        result['crossing']['placements'][0].update(x=0.34, y=0.43)
        self.assertTrue(evaluate_level(self.level, result).completed)
        result['crossing']['placements'][0].update(x=0.25, y=0.60)
        with self.assertRaises(GameResultError):
            evaluate_level(self.level, result)

    def test_duplicate_unknown_and_extra_travellers_cannot_claim_completion(self):
        duplicate = self.result(self.level)
        duplicate['crossing']['placements'][-1]['traveller_id'] = 'traveller-1'
        unknown = self.result(self.level)
        unknown['crossing']['placements'][-1]['traveller_id'] = 'forged-traveller'
        extra = self.result(self.level)
        extra['crossing']['placements'].append(copy.deepcopy(extra['crossing']['placements'][0]))
        for result in (duplicate, unknown, extra):
            self.assertEqual(self.submit(result).status_code, 400)
        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_elapsed_and_release_times_must_be_integer_ordered_and_within_timer(self):
        for elapsed_ms in (-1, 45_001, 20_000.5, True, float('inf'), float('nan')):
            result = self.result(self.level)
            result['crossing']['elapsed_ms'] = elapsed_ms
            with self.assertRaises(GameResultError):
                evaluate_level(self.level, result)
        for release in (-1, 20_001, 100.5, True):
            result = self.result(self.level)
            result['crossing']['placements'][0]['released_at_ms'] = release
            self.assertEqual(self.submit(result).status_code, 400)
        reverse = self.result(self.level)
        reverse['crossing']['placements'][1]['released_at_ms'] = 1
        self.assertEqual(self.submit(reverse).status_code, 400)

    def test_nonfinite_boolean_and_missing_drop_data_are_rejected(self):
        for invalid in (float('nan'), float('inf'), True, None, '0.5'):
            for coordinate in ('x', 'y'):
                result = self.result(self.level)
                result['crossing']['placements'][0][coordinate] = invalid
                with self.assertRaises(GameResultError):
                    evaluate_level(self.level, result)
        for key in ('traveller_id', 'x', 'y', 'released_at_ms'):
            result = self.result(self.level)
            del result['crossing']['placements'][0][key]
            self.assertEqual(self.submit(result).status_code, 400)

    def test_client_cannot_supply_completion_counts_score_or_walk_duration(self):
        for key, value in (
            ('completed', True), ('rescued_count', 6), ('stars', 3),
            ('score', 100), ('walk_duration_ms', 10_000),
        ):
            result = self.result(self.level, count=1)
            result['crossing'][key] = value
            self.assertEqual(self.submit(result).status_code, 400)
            del result['crossing'][key]
            result['crossing']['placements'][0][key] = value
            self.assertEqual(self.submit(result).status_code, 400)
            del result['crossing']['placements'][0][key]
            result[key] = value
            self.assertEqual(self.submit(result).status_code, 400)
        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_best_quest_progress_xp_and_unlocks_are_unchanged(self):
        first = self.submit(self.result(self.level, elapsed_ms=45_000))
        self.assertEqual(first.status_code, 201)
        self.assertEqual(first.data['stars'], 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], 70)
        improvement = self.submit(self.result(self.level))
        self.assertEqual(improvement.status_code, 201)
        self.assertEqual(improvement.data['stars'], 3)
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)
        repeat = self.submit(self.result(self.level))
        self.assertEqual(repeat.status_code, 201)
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)
        third = self.game.levels.get(level_number=3)
        skipped = self.submit(self.result(third), level_number=3)
        self.assertEqual(skipped.status_code, 400)
        second = self.game.levels.get(level_number=2)
        unlocked = self.submit(self.result(second), level_number=2)
        self.assertEqual(unlocked.status_code, 201)
        self.assertEqual(unlocked.data['progress']['highest_completed_level'], 2)

    def test_legacy_red_sea_grid_submission_remains_valid(self):
        grid = self.level.config['grid']
        start, end = tuple(grid['start']), tuple(grid['end'])
        walls = {tuple(value) for value in grid['walls']}
        queue, seen = deque([(start, [start])]), {start}
        path = None
        while queue:
            (row, column), candidate = queue.popleft()
            if (row, column) == end:
                path = [list(value) for value in candidate]
                break
            for neighbor in ((row - 1, column), (row + 1, column),
                             (row, column - 1), (row, column + 1)):
                if (
                    0 <= neighbor[0] < grid['rows']
                    and 0 <= neighbor[1] < grid['columns']
                    and neighbor not in walls
                    and neighbor not in seen
                ):
                    seen.add(neighbor)
                    queue.append((neighbor, candidate + [neighbor]))
        self.assertIsNotNone(path)
        response = self.submit({'path': path})
        self.assertEqual(response.status_code, 201)
        self.assertTrue(response.data['completed'])
        self.assertEqual(response.data['stars'], 3)

    def test_public_config_omits_unrecognized_private_crossing_fields(self):
        self.level.config['crossing']['private_note'] = 'not public'
        self.level.config['crossing']['travellers'][0]['private_note'] = 'not public'
        self.level.config['crossing']['drop_zone']['private_note'] = 'not public'
        public = public_level_config(self.level)['crossing']
        self.assertNotIn('private_note', public)
        self.assertNotIn('private_note', public['travellers'][0])
        self.assertNotIn('private_note', public['drop_zone'])

    def test_admin_rejects_invalid_dry_zones_and_duplicate_travellers(self):
        original = copy.deepcopy(self.level.config)
        variants = []
        for field, value in (('left', float('nan')), ('right', 1.01),
                             ('top', 0.75), ('bottom', 0.42)):
            config = copy.deepcopy(original)
            config['crossing']['drop_zone'][field] = value
            variants.append(config)
        config = copy.deepcopy(original)
        config['crossing']['travellers'][1]['id'] = 'traveller-1'
        variants.append(config)
        config = copy.deepcopy(original)
        config['crossing']['time_limit_seconds'] = 0
        variants.append(config)
        for config in variants:
            self.level.config = config
            with self.assertRaises(DjangoValidationError):
                self.level.full_clean()
