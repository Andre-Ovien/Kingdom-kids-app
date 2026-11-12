import copy
import uuid

from django.core.exceptions import ValidationError as DjangoValidationError
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import KidProfile, User

from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import evaluate_level


PASSWORD = 'A-strong-password-123!'
PUZZLE_SLUG = 'puzzle-quest'


class PuzzleQuestTests(TestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='puzzle-parent@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Maya',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        self.client = APIClient()
        token = RefreshToken.for_user(self.parent).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')
        self.game = Game.objects.get(slug=PUZZLE_SLUG)

    def detail(self):
        return self.client.get(
            f'/api/games/{PUZZLE_SLUG}/',
            {'profile_id': self.profile.pk},
        )

    def submit(self, result, *, level_number=1):
        return self.client.post(
            f'/api/games/{PUZZLE_SLUG}/submit/',
            {
                'profile_id': str(self.profile.pk),
                'level_number': level_number,
                'operation_id': str(uuid.uuid4()),
                'result': result,
            },
            format='json',
        )

    def perfect_result(self, level_number=1, *, extra_moves=0, extra_seconds=0):
        level = self.game.levels.get(level_number=level_number)
        return {
            'placements': [
                {'piece_id': piece_id, 'slot_id': slot_id}
                for piece_id, slot_id in level.config['solution'].items()
            ],
            'moves': level.config['target_moves'] + extra_moves,
            'elapsed_seconds': level.config['target_seconds'] + extra_seconds,
        }

    def test_seeded_public_contract_uses_sharp_shared_artwork_assets(self):
        response = self.detail()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['game_type'], Game.Type.PUZZLE)
        self.assertEqual(response.data['cover_asset_key'], (
            'assets/images/games/puzzle_quest/puzzle-quest-cover-v1.webp'
        ))
        self.assertEqual(
            [level['config']['artwork']['asset_key'] for level in response.data['levels']],
            [
                (
                    'assets/images/games/puzzle_quest/'
                    'noahs-ark-rainbow-v1.webp'
                ),
                (
                    'assets/images/games/puzzle_quest/'
                    'david-shepherd-hills-v1.webp'
                ),
                (
                    'assets/images/games/puzzle_quest/'
                    'puzzle-quest-cover-v1.webp'
                ),
            ],
        )
        self.assertEqual(
            [
                (
                    level['config']['grid']['rows'],
                    level['config']['grid']['columns'],
                )
                for level in response.data['levels']
            ],
            [(2, 2), (2, 3), (3, 3)],
        )

        for level in response.data['levels']:
            config = level['config']
            rows = config['grid']['rows']
            columns = config['grid']['columns']
            expected_positions = {
                (row, column)
                for row in range(rows)
                for column in range(columns)
            }
            self.assertNotIn('solution', config)
            self.assertEqual(len(config['pieces']), rows * columns)
            self.assertEqual(len(config['slots']), rows * columns)
            self.assertEqual(
                {
                    (piece['source_row'], piece['source_column'])
                    for piece in config['pieces']
                },
                expected_positions,
            )
            self.assertEqual(
                {(slot['row'], slot['column']) for slot in config['slots']},
                expected_positions,
            )
            self.assertTrue(all(piece['label'] for piece in config['pieces']))
            self.assertTrue(config['artwork']['alt_text'])
            self.assertEqual(config['artwork']['aspect_ratio'], 1)

    def test_perfect_arrangement_awards_standard_progress_xp_and_badge(self):
        response = self.submit(self.perfect_result())

        self.assertEqual(response.status_code, 201)
        self.assertTrue(response.data['completed'])
        self.assertEqual(response.data['score'], 100)
        self.assertEqual(response.data['stars'], 3)
        self.assertEqual(response.data['progress']['highest_completed_level'], 1)
        self.assertEqual(response.data['progress']['total_stars'], 3)
        progress = KidGameProgress.objects.get(profile=self.profile, game=self.game)
        self.assertEqual(progress.level_progress['1']['best_score'], 100)
        self.assertEqual(progress.level_progress['1']['best_stars'], 3)

        summary = self.client.get(
            f'/api/progress/kid-profiles/{self.profile.pk}/summary/',
        )
        self.assertEqual(summary.status_code, 200)
        self.assertEqual(summary.data['stats']['completed_game_levels'], 1)
        self.assertEqual(summary.data['stats']['game_stars'], 3)
        self.assertEqual(summary.data['level']['xp'], 110)
        first_play = next(
            badge for badge in summary.data['badges'] if badge['key'] == 'first-play'
        )
        self.assertTrue(first_play['earned'])

    def test_efficiency_scoring_is_deterministic(self):
        level = self.game.levels.get(level_number=1)
        result = self.perfect_result(extra_moves=5, extra_seconds=25)

        first = evaluate_level(level, result)
        second = evaluate_level(level, copy.deepcopy(result))

        self.assertEqual(first, second)
        self.assertTrue(first.completed)
        self.assertEqual(first.score, 87)
        self.assertEqual(first.stars, 2)
        self.assertEqual(first.details['moves_over_target'], 5)
        self.assertEqual(first.details['seconds_over_target'], 25)

    def test_wrong_full_arrangement_does_not_complete_or_unlock_next_level(self):
        level = self.game.levels.get(level_number=1)
        result = self.perfect_result()
        first_slot = result['placements'][0]['slot_id']
        second_slot = result['placements'][1]['slot_id']
        result['placements'][0]['slot_id'] = second_slot
        result['placements'][1]['slot_id'] = first_slot

        response = self.submit(result)

        self.assertEqual(response.status_code, 201)
        self.assertFalse(response.data['completed'])
        self.assertEqual(response.data['stars'], 0)
        self.assertEqual(
            GameAttempt.objects.get().evaluation['correct_placements'],
            len(level.config['solution']) - 2,
        )
        locked = self.submit(self.perfect_result(2), level_number=2)
        self.assertEqual(locked.status_code, 400)
        self.assertIn('previous level', str(locked.data))

    def test_malformed_or_impossible_results_are_rejected_without_attempts(self):
        perfect = self.perfect_result()
        first = perfect['placements'][0]
        second = perfect['placements'][1]
        invalid_results = (
            {
                **perfect,
                'placements': [first, {**second, 'piece_id': first['piece_id']}],
            },
            {
                **perfect,
                'placements': [first, {**second, 'slot_id': first['slot_id']}],
            },
            {
                **perfect,
                'placements': [
                    {**first, 'piece_id': 'invented-piece'},
                    *perfect['placements'][1:],
                ],
            },
            {
                **perfect,
                'placements': [
                    {**first, 'piece_id': ['not', 'an', 'id']},
                    *perfect['placements'][1:],
                ],
            },
            {
                **perfect,
                'placements': [{**first, 'answer': True}, *perfect['placements'][1:]],
            },
            {**perfect, 'moves': len(perfect['placements']) - 1},
            {**perfect, 'moves': True},
            {**perfect, 'elapsed_seconds': 3_601},
            {**perfect, 'solution': {'please': 'trust me'}},
            {**perfect, 'score': 999, 'stars': 3, 'completed': True},
        )

        for result in invalid_results:
            with self.subTest(result=result):
                response = self.submit(result)
                self.assertEqual(response.status_code, 400)

        self.assertEqual(GameAttempt.objects.count(), 0)
        self.assertFalse(
            KidGameProgress.objects.filter(
                profile=self.profile,
                game=self.game,
            ).exists()
        )

    def test_puzzle_authoring_rejects_inconsistent_crop_solution(self):
        seeded = self.game.levels.get(level_number=1)
        game = Game.objects.create(
            slug='draft-puzzle',
            title='Draft Puzzle',
            subtitle='Not published',
            description='A puzzle validation fixture.',
            game_type=Game.Type.PUZZLE,
            cover_asset_key='assets/images/games/puzzle_quest/draft.webp',
            is_published=False,
        )
        invalid_config = copy.deepcopy(seeded.config)
        piece_ids = list(invalid_config['solution'])
        first_slot = invalid_config['solution'][piece_ids[0]]
        second_slot = invalid_config['solution'][piece_ids[1]]
        invalid_config['solution'][piece_ids[0]] = second_slot
        invalid_config['solution'][piece_ids[1]] = first_slot

        with self.assertRaises(DjangoValidationError) as invalid:
            GameLevel.objects.create(
                game=game,
                level_number=1,
                title='Broken Puzzle',
                instructions='This answer does not match its artwork crops.',
                config=invalid_config,
                max_score=100,
                star_thresholds=[60, 80, 95],
            )

        self.assertIn('config', invalid.exception.message_dict)
        self.assertIn('crop position', str(invalid.exception))

    def test_all_seeded_puzzle_definitions_pass_runtime_authoring_validation(self):
        for level in self.game.levels.all():
            with self.subTest(level=level.level_number):
                level.full_clean()
