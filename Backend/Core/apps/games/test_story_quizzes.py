"""Story content, safe catalogue retirement, and real scoring/receipt checks."""
import copy
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
from apps.progress.services import build_kid_profile_summary, build_profile_level
from apps.stories.models import NarratorVoice, Story, StoryNarration

from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import evaluate_level
from .story_quizzes_v1 import QUIZ_STORIES, quiz_games
from .validators import validate_level_definition


MIGRATION = importlib.import_module('apps.games.migrations.0017_story_quizzes_and_retire_memory')
QUIZ_SLUGS = {definition['slug'] for definition in QUIZ_STORIES}
RETIRED_GAME_SLUGS = MIGRATION.RETIRED_GAME_SLUGS


class StoryQuizCatalogueTests(TestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='story-quizzes@example.com', password='Quiz-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(parent=self.parent, display_name='Ada', avatar_key='lion')
        self.client = APIClient()
        self.client.force_authenticate(self.parent)

    def submit(self, level, result=None, operation=None):
        return self.client.post(f'/api/games/{level.game.slug}/submit/', {
            'profile_id': str(self.profile.pk), 'level_number': level.level_number,
            'operation_id': str(operation or uuid.uuid4()),
            'result': result if result is not None else self.perfect_result(level),
        }, format='json')

    @staticmethod
    def perfect_result(level):
        return {'answers': [
            {'question_id': question['id'], 'option_id': question['correct_option_id']}
            for question in level.config['questions']
        ]}

    def test_five_published_quizzes_and_no_playable_memory_or_matching(self):
        response = self.client.get('/api/games/', {'profile_id': self.profile.pk})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 10)
        self.assertEqual(Counter(item['game_type'] for item in response.data)['quiz'], 5)
        self.assertEqual(Counter(item['game_type'] for item in response.data)['memory'], 0)
        self.assertEqual(Counter(item['game_type'] for item in response.data)['matching'], 0)
        self.assertEqual(Game.objects.count(), 29)
        self.assertEqual(GameLevel.objects.count(), 87)
        self.assertEqual(GameLevel.objects.filter(game__is_published=True).count(), 30)
        for slug in RETIRED_GAME_SLUGS:
            with self.subTest(slug=slug):
                self.assertFalse(Game.objects.get(slug=slug).is_published)
                self.assertNotIn(slug, {item['slug'] for item in response.data})
                self.assertEqual(
                    self.client.get(f'/api/games/{slug}/', {'profile_id': self.profile.pk}).status_code,
                    404,
                )
                retired_level = GameLevel.objects.get(game__slug=slug, level_number=1)
                self.assertEqual(self.submit(retired_level, {}).status_code, 404)
                self.assertEqual(retired_level.game.levels.count(), 3)

    def test_all_81_questions_follow_story_text_and_use_current_cover_assets(self):
        question_ids = set()
        answer_positions = Counter()
        for definition in QUIZ_STORIES:
            game = Game.objects.get(slug=definition['slug'])
            story = Story.objects.get(slug=definition['story_slug'])
            self.assertEqual(game.cover_asset_key, story.cover_asset_key)
            levels = list(game.levels.all())
            self.assertEqual([level.level_number for level in levels], [1, 2, 3])
            for level in levels:
                with self.subTest(game=game.slug, level=level.level_number):
                    validate_level_definition(game_type='quiz', config=level.config,
                                              max_score=level.max_score, star_thresholds=level.star_thresholds)
                    self.assertEqual(len(level.config['questions']), 3)
                    self.assertEqual(level.config['story_slug'], story.slug)
                    for question in level.config['questions']:
                        self.assertNotIn(question['id'], question_ids)
                        question_ids.add(question['id'])
                        self.assertIn(question['source_excerpt'], story.body)
                        texts = [choice['text'] for choice in question['options']]
                        self.assertEqual(len(set(texts)), 3)
                        answer_positions[question['correct_option_id']] += 1
                    evaluation = evaluate_level(level, self.perfect_result(level))
                    self.assertTrue(evaluation.completed)
                    self.assertEqual((evaluation.score, evaluation.stars), (100, 3))
        self.assertEqual(len(question_ids), 81)
        self.assertEqual(answer_positions, {'a': 27, 'b': 27, 'c': 27})

    def test_each_new_quiz_api_hides_answers_provenance_and_pass_score(self):
        # Retain the frozen quizzes' serializer contract in this scoped fixture,
        # without making retired quizzes available in the default catalogue.
        Game.objects.filter(slug__in=QUIZ_SLUGS).update(is_published=True)
        for slug in QUIZ_SLUGS:
            with self.subTest(slug=slug):
                response = self.client.get(f'/api/games/{slug}/', {'profile_id': self.profile.pk})
                self.assertEqual(response.status_code, 200)
                for level in response.data['levels']:
                    self.assertEqual(set(level['config']), {'questions'})
                    self.assertEqual(len(level['config']['questions']), 3)
                    for question in level['config']['questions']:
                        self.assertEqual(set(question), {'id', 'prompt', 'options'})
                        for choice in question['options']:
                            self.assertEqual(set(choice), {'id', 'text'})

    def test_all_new_quizzes_complete_sequentially_with_normal_50_plus_stars_reward(self):
        Game.objects.filter(slug__in=QUIZ_SLUGS).update(is_published=True)
        for slug in sorted(QUIZ_SLUGS):
            for level in GameLevel.objects.filter(game__slug=slug).select_related('game'):
                with self.subTest(slug=slug, round=level.level_number):
                    response = self.submit(level)
                    self.assertEqual(response.status_code, 201)
                    self.assertEqual((response.data['score'], response.data['stars']), (100, 3))
                    self.assertTrue(response.data['completed'])
                    progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
                    self.assertEqual(progress.level_progress[str(level.level_number)]['completion_xp'], 50)
        self.assertEqual(GameAttempt.objects.count(), 27)
        self.assertEqual(build_profile_level(self.profile)['xp'], 27 * 110)

    def test_retry_is_same_receipt_and_new_replay_does_not_repeat_xp(self):
        # Explicitly opt into this retired quiz for its legacy receipt test.
        Game.objects.filter(slug='ruth-and-naomi-quiz').update(is_published=True)
        level = GameLevel.objects.get(game__slug='ruth-and-naomi-quiz', level_number=1)
        operation = uuid.uuid4()
        first = self.submit(level, operation=operation)
        retry = self.submit(level, operation=operation)
        self.assertEqual((first.status_code, retry.status_code), (201, 200))
        self.assertEqual(first.data['attempt_id'], retry.data['attempt_id'])
        self.assertTrue(retry.data['idempotent_replay'])
        progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
        self.assertEqual(progress.level_progress['1']['attempts'], 1)
        self.assertEqual(GameAttempt.objects.count(), 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)
        replay = self.submit(level)
        self.assertEqual(replay.status_code, 201)
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)
        wrong = self.perfect_result(level)
        wrong['answers'][0]['option_id'] = next(
            choice['id'] for choice in level.config['questions'][0]['options']
            if choice['id'] != wrong['answers'][0]['option_id']
        )
        conflict = self.submit(level, wrong, operation=operation)
        self.assertEqual(conflict.status_code, 409)
        self.assertEqual(GameAttempt.objects.count(), 2)

    def test_wrong_incomplete_and_client_claimed_results_do_not_unlock_or_award(self):
        Game.objects.filter(slug='good-samaritan-quiz').update(is_published=True)
        level = GameLevel.objects.get(game__slug='good-samaritan-quiz', level_number=1)
        wrong = {'answers': [
            {'question_id': question['id'], 'option_id': next(
                choice['id'] for choice in question['options'] if choice['id'] != question['correct_option_id'])}
            for question in level.config['questions']
        ]}
        incomplete = copy.deepcopy(self.perfect_result(level))
        incomplete['answers'].pop()
        for result in (wrong, incomplete):
            response = self.submit(level, result)
            self.assertEqual(response.status_code, 201)
            self.assertFalse(response.data['completed'])
            self.assertEqual(response.data['stars'], 0)
        second = GameLevel.objects.get(game=level.game, level_number=2)
        self.assertEqual(self.submit(second).status_code, 400)
        self.assertEqual(self.submit(level, {**self.perfect_result(level), 'score': 100}).status_code, 400)
        self.assertEqual(build_profile_level(self.profile)['xp'], 0)
        self.assertEqual(GameAttempt.objects.count(), 2)

    def test_retired_games_preserve_saved_attempts_progress_and_legacy_xp(self):
        for slug in RETIRED_GAME_SLUGS:
            game = Game.objects.get(slug=slug)
            level = game.levels.get(level_number=1)
            KidGameProgress.objects.create(
                profile=self.profile, game=game, highest_completed_level=2, total_stars=5,
                level_progress={
                    '1': {'completed': True, 'best_stars': 3, 'best_score': 100, 'attempts': 2},
                    '2': {'completed': True, 'best_stars': 2, 'best_score': 80, 'attempts': 1, 'completion_xp': 50},
                },
            )
            GameAttempt.objects.create(
                operation_id=uuid.uuid4(), profile=self.profile, game=game, level=level,
                submitted_result={}, completed=True, score=100, stars=3,
                feedback='Saved historical result.', evaluation={'correct_pairs': 3},
            )
        saved_progress = list(KidGameProgress.objects.filter(profile=self.profile).values())
        saved_attempts = list(GameAttempt.objects.filter(profile=self.profile).values())
        saved_levels = list(GameLevel.objects.filter(game__slug__in=RETIRED_GAME_SLUGS).values())
        # Prove that publishing status has no effect on lifetime XP or rank.
        Game.objects.filter(slug__in=RETIRED_GAME_SLUGS).update(is_published=True)
        before = build_profile_level(self.profile)
        MIGRATION.add_story_quizzes_and_retire_memory(apps, SimpleNamespace(connection=connection))
        self.assertEqual(Game.objects.filter(slug__in=RETIRED_GAME_SLUGS, is_published=True).count(), 0)
        self.assertEqual(build_profile_level(self.profile), before)
        self.assertEqual(before['xp'], 3 * (100 + 50 + 5 * 20))
        summary = build_kid_profile_summary(self.profile)
        self.assertEqual(summary['xp_breakdown']['quests'], 750)
        self.assertEqual(summary['stats']['completed_game_levels'], 0)
        self.assertEqual(summary['stats']['game_stars'], 0)
        self.assertEqual(summary['stats']['games_started'], 0)
        self.assertEqual(list(GameAttempt.objects.filter(profile=self.profile).values()), saved_attempts)
        self.assertEqual(list(KidGameProgress.objects.filter(profile=self.profile).values()), saved_progress)
        self.assertEqual(list(GameLevel.objects.filter(game__slug__in=RETIRED_GAME_SLUGS).values()), saved_levels)

    def test_idempotent_additive_seed_preserves_all_old_content_and_editorial_changes(self):
        previous_games = list(Game.objects.exclude(slug__in=QUIZ_SLUGS).values())
        previous_levels = list(GameLevel.objects.exclude(game__slug__in=QUIZ_SLUGS).values())
        stories = list(Story.objects.values())
        narrations = list(StoryNarration.objects.values())
        voices = list(NarratorVoice.objects.values())
        edited = GameLevel.objects.get(game__slug='noah-quiz', level_number=1)
        edited.title = 'An editor’s updated round'
        edited.save(update_fields=['title'])
        for _ in range(2):
            MIGRATION.add_story_quizzes_and_retire_memory(apps, SimpleNamespace(connection=connection))
        self.assertEqual(Game.objects.count(), 29)
        self.assertEqual(GameLevel.objects.count(), 87)
        self.assertEqual(list(Game.objects.exclude(slug__in=QUIZ_SLUGS).values()), previous_games)
        self.assertEqual(list(GameLevel.objects.exclude(game__slug__in=QUIZ_SLUGS).values()), previous_levels)
        self.assertEqual(list(Story.objects.values()), stories)
        self.assertEqual(list(StoryNarration.objects.values()), narrations)
        self.assertEqual(list(NarratorVoice.objects.values()), voices)
        edited.refresh_from_db()
        self.assertEqual(edited.title, 'An editor’s updated round')

    def test_frozen_payload_and_migration_depend_on_existing_cover_migration(self):
        self.assertEqual(len(quiz_games()), 9)
        loader = MigrationLoader(None)
        plan = loader.graph.forwards_plan(('games', '0017_story_quizzes_and_retire_memory'))
        self.assertIn(('games', '0016_wise_builders'), plan)
        self.assertIn(('stories', '0010_storybook_cover_artwork'), plan)
