"""Selected catalogue pruning must preserve content, receipts and lifetime XP."""
import importlib
import uuid
from collections import Counter
from types import SimpleNamespace

from django.apps import apps
from django.db import connection
from django.db.migrations.loader import MigrationLoader
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.progress.models import KidActivityEvent, StreakDailyVisit
from apps.progress.services import build_kid_profile_summary, build_profile_level
from apps.stories.models import NarratorVoice, Story, StoryNarration

from .models import Game, GameAttempt, GameLevel, KidGameProgress


PRUNING = importlib.import_module('apps.games.migrations.0021_prune_quiz_and_puzzle_catalogue')
RETIRED_SLUGS = set(PRUNING.RETIRED_GAME_SLUGS)
KEPT_PUZZLES = {
    'puzzle-quest', 'puzzle-esther', 'puzzle-noah', 'puzzle-david', 'puzzle-lost-sheep',
}
KEPT_QUIZZES = {'esther-quiz', 'noah-quiz', 'david-quiz', 'jonah-quiz', 'lost-sheep-quiz'}
KEPT_SLUGS = KEPT_PUZZLES | KEPT_QUIZZES | {'david-sling-shot', 'jonah-ocean-maze'}


def rows(model):
    return list(model.objects.order_by('pk').values())


class CataloguePruningTests(TestCase):
    def setUp(self):
        # Isolate the earlier pruning contract from the later action-game
        # pause; this historical fixture deliberately republishes its two games.
        Game.objects.filter(slug__in=('david-sling-shot', 'jonah-ocean-maze')).update(is_published=True)
        self.parent = User.objects.create_user(
            email='catalogue-pruning@example.com', password='Pruning-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent, display_name='Ada', avatar_key='lion',
        )
        self.client = APIClient()
        self.client.force_authenticate(self.parent)
        self.editor = SimpleNamespace(connection=connection)

    @staticmethod
    def perfect_result(level):
        if level.game.game_type == Game.Type.QUIZ:
            return {'answers': [
                {'question_id': question['id'], 'option_id': question['correct_option_id']}
                for question in level.config['questions']
            ]}
        return {
            'placements': [
                {'piece_id': piece, 'slot_id': slot}
                for piece, slot in level.config['solution'].items()
            ],
            'moves': level.config['target_moves'],
            'elapsed_seconds': level.config['target_seconds'],
        }

    def saved_history(self):
        for game in Game.objects.filter(slug__in=RETIRED_SLUGS):
            level = game.levels.get(level_number=1)
            # An old completion had the previous 100-XP rate. Keeping its
            # missing receipt also exercises the historical reward fallback.
            KidGameProgress.objects.create(
                profile=self.profile, game=game, highest_completed_level=1,
                total_stars=3,
                level_progress={
                    '1': {'completed': True, 'best_stars': 3,
                          'best_score': 100, 'attempts': 1},
                },
            )
            GameAttempt.objects.create(
                operation_id=uuid.uuid4(), profile=self.profile, game=game,
                level=level, submitted_result=self.perfect_result(level),
                completed=True, score=100, stars=3,
                feedback='Saved historical completion.', evaluation={},
            )

    def test_exact_published_selection_has_twelve_games_and_thirty_six_rounds(self):
        response = self.client.get('/api/games/', {'profile_id': self.profile.pk})
        self.assertEqual(response.status_code, 200)
        self.assertEqual({game['slug'] for game in response.data}, KEPT_SLUGS)
        self.assertEqual(Counter(game['game_type'] for game in response.data),
                         {'puzzle': 5, 'quiz': 5, 'aim': 1, 'maze': 1})
        self.assertEqual(sum(game['total_levels'] for game in response.data), 36)
        self.assertEqual(Game.objects.count(), 29)
        self.assertEqual(GameLevel.objects.count(), 87)
        self.assertEqual(Game.objects.filter(slug__in=RETIRED_SLUGS).count(), 11)
        self.assertEqual(GameLevel.objects.filter(game__slug__in=RETIRED_SLUGS).count(), 33)

    def test_retired_detail_new_submissions_and_saved_retries_are_hidden(self):
        self.saved_history()
        before_xp = build_profile_level(self.profile)
        before_attempts = rows(GameAttempt)
        before_progress = rows(KidGameProgress)
        for game in Game.objects.filter(slug__in=RETIRED_SLUGS):
            with self.subTest(slug=game.slug):
                self.assertFalse(game.is_published)
                self.assertEqual(self.client.get(
                    f'/api/games/{game.slug}/', {'profile_id': self.profile.pk},
                ).status_code, 404)
                attempt = GameAttempt.objects.get(game=game, profile=self.profile)
                for operation in (uuid.uuid4(), attempt.operation_id):
                    response = self.client.post(f'/api/games/{game.slug}/submit/', {
                        'profile_id': str(self.profile.pk), 'level_number': 1,
                        'operation_id': str(operation), 'result': attempt.submitted_result,
                    }, format='json')
                    self.assertEqual(response.status_code, 404)
        self.assertEqual(rows(GameAttempt), before_attempts)
        self.assertEqual(rows(KidGameProgress), before_progress)
        self.assertEqual(build_profile_level(self.profile), before_xp)
        self.assertEqual(before_xp['xp'], 11 * 160)

    def test_idempotent_retirement_and_noop_reverse_preserve_every_other_row(self):
        self.saved_history()
        Game.objects.filter(slug__in=RETIRED_SLUGS).update(is_published=True)
        edited = Game.objects.get(slug='puzzle-ruth-and-naomi')
        edited.description = 'An editor’s later description stays intact.'
        edited.save(update_fields=['description'])
        expected_games = rows(Game)
        for row in expected_games:
            if row['slug'] in RETIRED_SLUGS:
                row['is_published'] = False
        preserved = {model: rows(model) for model in (
            GameLevel, GameAttempt, KidGameProgress, KidProfile, KidActivityEvent,
            StreakDailyVisit, Story, StoryNarration, NarratorVoice,
        )}
        before_level = build_profile_level(self.profile)
        self.assertEqual(build_kid_profile_summary(self.profile)['stats']['completed_game_levels'], 11)

        for _ in range(2):
            PRUNING.retire_extra_quizzes_and_puzzles(apps, self.editor)
        PRUNING.Migration.operations[0].reverse_code(apps, self.editor)

        self.assertEqual(rows(Game), expected_games)
        for model, expected in preserved.items():
            self.assertEqual(rows(model), expected)
        self.assertEqual(build_profile_level(self.profile), before_level)
        summary = build_kid_profile_summary(self.profile)
        self.assertEqual(summary['xp_breakdown']['quests'], 11 * 160)
        self.assertEqual(summary['stats']['completed_game_levels'], 0)
        self.assertEqual(summary['stats']['game_stars'], 0)
        self.assertEqual(summary['stats']['games_started'], 0)
        self.assertEqual(summary['stats']['total_game_levels'], 36)

    def test_pruning_neither_creates_missing_entries_nor_republishes_or_broadly_retires(self):
        # Absent content must remain absent, and names outside the exact frozen
        # set must not be caught by game type, prefix or substring matching.
        Game.objects.filter(slug='ruth-and-naomi-quiz').delete()
        Game.objects.filter(slug='puzzle-esther').update(is_published=False)
        for slug, kind in (
            ('puzzle-red-sea-future', Game.Type.PUZZLE),
            ('creation-quiz-preview', Game.Type.QUIZ),
        ):
            Game.objects.create(
                slug=slug, title='Future editorial entry', subtitle='Future edition',
                description='Exact-slug retirement boundary fixture.', game_type=kind,
                cover_asset_key='assets/images/stories/creation-week-v2.webp',
                is_published=True,
            )
        games = rows(Game)
        levels = rows(GameLevel)
        PRUNING.retire_extra_quizzes_and_puzzles(apps, self.editor)
        self.assertEqual(rows(Game), games)
        self.assertEqual(rows(GameLevel), levels)
        self.assertFalse(Game.objects.filter(slug='ruth-and-naomi-quiz').exists())
        self.assertFalse(Game.objects.get(slug='puzzle-esther').is_published)

    def test_retained_quizzes_and_puzzles_still_score_and_award_once(self):
        for slug in sorted(KEPT_QUIZZES | KEPT_PUZZLES):
            with self.subTest(slug=slug):
                self.assertEqual(self.client.get(
                    f'/api/games/{slug}/', {'profile_id': self.profile.pk},
                ).status_code, 200)
                level = GameLevel.objects.get(game__slug=slug, level_number=1)
                payload = {
                    'profile_id': str(self.profile.pk), 'level_number': 1,
                    'operation_id': str(uuid.uuid4()), 'result': self.perfect_result(level),
                }
                created = self.client.post(f'/api/games/{slug}/submit/', payload, format='json')
                retry = self.client.post(f'/api/games/{slug}/submit/', payload, format='json')
                self.assertEqual((created.status_code, retry.status_code), (201, 200))
                self.assertEqual(created.data['attempt_id'], retry.data['attempt_id'])
                self.assertTrue(created.data['completed'])
                self.assertEqual((created.data['score'], created.data['stars']), (100, 3))
        self.assertEqual(GameAttempt.objects.count(), 10)
        self.assertEqual(build_profile_level(self.profile)['xp'], 10 * 110)

    def test_migration_is_additive_after_builders_and_does_not_reverse_publication(self):
        loader = MigrationLoader(None)
        node = ('games', '0021_prune_quiz_and_puzzle_catalogue')
        self.assertEqual(loader.disk_migrations[node].dependencies,
                         [('games', '0020_retire_wise_and_foolish_builders')])
        self.assertIn(('games', '0020_retire_wise_and_foolish_builders'),
                      loader.graph.forwards_plan(node))
        self.assertEqual(len(PRUNING.Migration.operations), 1)
        self.assertEqual(len(RETIRED_SLUGS), 11)
