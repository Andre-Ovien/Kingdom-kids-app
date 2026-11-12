import uuid
from collections import deque
from datetime import date, timedelta
from unittest.mock import patch

from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import KidProfile, User
from apps.progress.models import KidActivityEvent, StreakDailyVisit
from apps.progress.services import build_profile_level
from apps.stories.models import Story

from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import evaluate_level
from .wise_builders import example_builders_result


PASSWORD = 'A-strong-password-123!'


class GameApiTests(TestCase):
    """Shared authentication, receipts and legacy-engine compatibility.

    Ark Traffic, Living World and Builders exercise their current command
    protocols in their dedicated API suites. Keep the legacy ordering and
    boarding fixtures here so the older supported engines remain covered.
    """

    def setUp(self):
        # Retired quests are published only in these legacy fixtures so their
        # preserved scorers remain covered.
        Game.objects.filter(slug__in=(
            'daniel-memory', 'ark-animal-match', 'moses-match', 'red-sea-path',
            'creation-order',
            'wise-and-foolish-builders',
            'david-sling-shot', 'jonah-ocean-maze',
        )).update(is_published=True)
        for level in GameLevel.objects.filter(
            game__slug__in=('creation-order', 'ark-animal-match'),
        ).select_related('game'):
            config = dict(level.config)
            if config.get('mode') == 'living_world':
                config.pop('mode')
                config.pop('world')
            elif config.get('mode') == 'ark_traffic':
                config['mode'] = 'ark_boarding'
                config.pop('traffic')
            level.config = config
            level.save(update_fields=('config',))
        self.parent = User.objects.create_user(
            email='games@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Ada',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        self.client = APIClient()
        self.authenticate(self.parent)

    def authenticate(self, user):
        token = RefreshToken.for_user(user).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')

    def catalogue(self, profile=None):
        return self.client.get(
            '/api/games/',
            {'profile_id': profile or self.profile.pk},
        )

    def detail(self, slug, profile=None):
        return self.client.get(
            f'/api/games/{slug}/',
            {'profile_id': profile or self.profile.pk},
        )

    def submit(self, slug, result, *, level=1, operation_id=None, profile=None):
        return self.client.post(
            f'/api/games/{slug}/submit/',
            {
                'profile_id': str(profile or self.profile.pk),
                'level_number': level,
                'operation_id': str(operation_id or uuid.uuid4()),
                'result': result,
            },
            format='json',
        )

    def set_completed_progress(self, game, stars_by_level, *, profile=None):
        entries = {
            str(number): {
                'best_score': 100 if stars == 3 else 60,
                'best_stars': stars,
                'completed': True,
                'attempts': 1,
            }
            for number, stars in stars_by_level.items()
        }
        return KidGameProgress.objects.create(
            profile=profile or self.profile,
            game=game,
            highest_completed_level=len(entries),
            total_stars=sum(stars_by_level.values()),
            level_progress=entries,
        )

    def test_overall_level_seven_to_eight_is_stored_with_its_attempt(self):
        target = GameLevel.objects.get(game__slug='esther-quiz', level_number=1)
        seeded_levels = list(
            GameLevel.objects.exclude(game=target.game)
            .select_related('game')
            .order_by('game__sort_order', 'level_number')[:13]
        )
        by_game = {}
        for index, level in enumerate(seeded_levels):
            game, entries = by_game.setdefault(level.game_id, (level.game, {}))
            entries[level.level_number] = 3 if index < 12 else 0
        for game, entries in by_game.values():
            self.set_completed_progress(game, entries)
        self.assertEqual(build_profile_level(self.profile)['xp'], 2020)
        self.assertEqual(build_profile_level(self.profile)['number'], 7)

        response = self.submit(target.game.slug, self.perfect_result(target))

        self.assertEqual(response.status_code, 201)
        expected = {
            'previous_level': 7,
            'level': {
                'number': 8,
                'title': 'Courageous Heart',
                'xp': 2130,
                'next_level_xp': 2400,
                'max_level': 15,
                'is_max_level': False,
            },
        }
        self.assertEqual(response.data['level_milestone'], expected)
        self.assertEqual(build_profile_level(self.profile), expected['level'])
        attempt = GameAttempt.objects.get(pk=response.data['attempt_id'])
        self.assertEqual(attempt.evaluation['_level_milestone'], expected)
        self.assertIn('correct_answers', attempt.evaluation)

    def test_saved_attempt_without_overall_advancement_has_no_milestone(self):
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)

        first = self.submit(level.game.slug, self.perfect_result(level))
        again = self.submit(level.game.slug, self.perfect_result(level))

        self.assertEqual(first.status_code, 201)
        self.assertEqual(again.status_code, 201)
        self.assertIsNone(first.data['level_milestone'])
        self.assertIsNone(again.data['level_milestone'])
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)
        progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
        self.assertEqual(progress.level_progress['1']['completion_xp'], 50)
        self.assertEqual(GameAttempt.objects.count(), 2)

    def test_quest_advancement_includes_earned_reading_and_streak_xp(self):
        story = Story.objects.filter(is_published=True).first()
        KidActivityEvent.objects.create(
            profile=self.profile,
            story=story,
            operation_id=uuid.uuid4(),
            event_type=KidActivityEvent.EventType.STORY_COMPLETED,
        )
        for days_ago in range(7):
            StreakDailyVisit.objects.create(
                profile=self.profile,
                local_date=date(2026, 7, 25) - timedelta(days=days_ago),
                state=StreakDailyVisit.State.CONTINUED,
                timezone_offset_minutes=0,
            )
        self.assertEqual(build_profile_level(self.profile)['xp'], 240)
        target = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        response = self.submit(target.game.slug, self.perfect_result(target))
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data['level_milestone']['previous_level'], 1)
        self.assertEqual(response.data['level_milestone']['level']['number'], 2)
        self.assertEqual(response.data['level_milestone']['level']['xp'], 350)
        self.assertEqual(build_profile_level(self.profile)['xp'], 350)

    def test_better_stars_on_completed_quest_can_advance_overall_level(self):
        target = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        other = Game.objects.get(slug='ark-animal-match')
        self.set_completed_progress(target.game, {1: 1})
        self.set_completed_progress(other, {1: 2})
        self.assertEqual(build_profile_level(self.profile)['xp'], 260)

        response = self.submit(target.game.slug, self.perfect_result(target))

        self.assertEqual(response.status_code, 201)
        self.assertEqual(
            response.data['level_milestone'],
            {
                'previous_level': 1,
                'level': {
                    'number': 2,
                    'title': 'Story Scout',
                    'xp': 300,
                    'next_level_xp': 600,
                    'max_level': 15,
                    'is_max_level': False,
                },
            },
        )
        self.assertEqual(response.data['progress']['completed_levels'], 1)
        progress = KidGameProgress.objects.get(profile=self.profile, game=target.game)
        self.assertEqual(progress.level_progress['1']['completion_xp'], 100)

    def test_failed_first_attempt_then_completion_earns_50_and_keeps_it_on_replay(self):
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        result = self.perfect_result(level)
        failed = self.submit(level.game.slug, {'sequence': list(reversed(result['sequence']))})
        self.assertEqual(failed.status_code, 201)
        self.assertEqual(build_profile_level(self.profile)['xp'], 0)
        operation_id = uuid.uuid4()
        earned = self.submit(level.game.slug, result, operation_id=operation_id)
        replay = self.submit(level.game.slug, result, operation_id=operation_id)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.data['attempt_id'], earned.data['attempt_id'])
        self.assertEqual(build_profile_level(self.profile)['xp'], 110)
        progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
        self.assertEqual(progress.level_progress['1']['completion_xp'], 50)
        self.assertEqual(progress.level_progress['1']['attempts'], 2)

    def test_legacy_and_new_completions_in_one_game_keep_different_awards(self):
        game = Game.objects.get(slug='creation-order')
        self.set_completed_progress(game, {1: 3})
        second = game.levels.get(level_number=2)
        self.assertEqual(build_profile_level(self.profile)['xp'], 160)
        self.submit(game.slug, self.perfect_result(second), level=2)
        self.assertEqual(build_profile_level(self.profile)['xp'], 270)
        first = game.levels.get(level_number=1)
        self.submit(game.slug, self.perfect_result(first))
        self.assertEqual(build_profile_level(self.profile)['xp'], 270)
        progress = KidGameProgress.objects.get(profile=self.profile, game=game)
        self.assertEqual(progress.level_progress['1']['completion_xp'], 100)
        self.assertEqual(progress.level_progress['2']['completion_xp'], 50)

    def test_quest_at_max_level_earns_xp_without_a_sixteenth_level(self):
        for days_ago in range(210):
            StreakDailyVisit.objects.create(
                profile=self.profile,
                local_date=date(2026, 7, 25) - timedelta(days=days_ago),
                state=StreakDailyVisit.State.CONTINUED,
                timezone_offset_minutes=0,
            )
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        earned = self.submit(level.game.slug, self.perfect_result(level))
        self.assertEqual(earned.status_code, 201)
        self.assertIsNone(earned.data['level_milestone'])
        current = build_profile_level(self.profile)
        self.assertEqual(current['xp'], 4310)
        self.assertEqual(current['number'], 15)
        self.assertTrue(current['is_max_level'])

    def test_historical_game_milestone_above_fifteen_is_not_replayed(self):
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        result = self.perfect_result(level)
        self.set_completed_progress(level.game, {1: 3})
        milestone = {
            'previous_level': 15,
            'level': {'number': 16, 'title': 'Kingdom Champion', 'xp': 4500, 'next_level_xp': 4800},
        }
        attempt = GameAttempt.objects.create(
            profile=self.profile,
            game=level.game,
            level=level,
            operation_id=uuid.uuid4(),
            submitted_result=result,
            completed=True,
            stars=3,
            score=100,
            feedback='Historical result',
            evaluation={'_level_milestone': milestone},
        )
        replay = self.submit(level.game.slug, result, operation_id=attempt.operation_id)
        self.assertEqual(replay.status_code, 200)
        self.assertIsNone(replay.data['level_milestone'])
        attempt.refresh_from_db()
        self.assertEqual(attempt.evaluation['_level_milestone'], milestone)
        self.assertEqual(build_profile_level(self.profile)['xp'], 160)

    def test_milestone_replay_keeps_original_transition_after_later_level_up(self):
        levels = [
            GameLevel.objects.get(game__slug=slug, level_number=1)
            for slug in (
                'creation-order',
                'ark-animal-match',
                'esther-quiz',
                'david-sling-shot',
            )
        ]
        self.submit(levels[0].game.slug, self.perfect_result(levels[0]))
        for days_ago in range(4):
            StreakDailyVisit.objects.create(
                profile=self.profile,
                local_date=date(2026, 7, 25) - timedelta(days=days_ago),
                state=StreakDailyVisit.State.CONTINUED,
                timezone_offset_minutes=0,
            )
        operation_id = uuid.uuid4()
        result = self.perfect_result(levels[1])
        earned = self.submit(
            levels[1].game.slug, result, operation_id=operation_id,
        )
        for level in levels[2:]:
            self.submit(level.game.slug, self.perfect_result(level))
        for days_ago in range(4, 8):
            StreakDailyVisit.objects.create(
                profile=self.profile,
                local_date=date(2026, 7, 25) - timedelta(days=days_ago),
                state=StreakDailyVisit.State.CONTINUED,
                timezone_offset_minutes=0,
            )
        self.assertEqual(build_profile_level(self.profile)['number'], 3)

        replay = self.submit(
            levels[1].game.slug, result, operation_id=operation_id,
        )

        self.assertEqual(replay.status_code, 200)
        self.assertTrue(replay.data['idempotent_replay'])
        self.assertEqual(replay.data['attempt_id'], earned.data['attempt_id'])
        self.assertEqual(replay.data['level_milestone'], earned.data['level_milestone'])
        self.assertEqual(replay.data['level_milestone']['level']['number'], 2)
        self.assertEqual(GameAttempt.objects.count(), 4)

    def test_historical_attempt_does_not_invent_a_level_milestone(self):
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        result = self.perfect_result(level)
        operation_id = uuid.uuid4()
        self.set_completed_progress(level.game, {1: 3})
        self.set_completed_progress(Game.objects.get(slug='ark-animal-match'), {1: 3})
        GameAttempt.objects.create(
            profile=self.profile,
            game=level.game,
            level=level,
            operation_id=operation_id,
            submitted_result=result,
            completed=True,
            score=100,
            stars=3,
            feedback='Historical result',
            evaluation={'correct_positions': len(result['sequence'])},
        )
        self.assertEqual(build_profile_level(self.profile)['number'], 2)

        replay = self.submit(level.game.slug, result, operation_id=operation_id)

        self.assertEqual(replay.status_code, 200)
        self.assertTrue(replay.data['idempotent_replay'])
        self.assertIsNone(replay.data['level_milestone'])
        self.assertEqual(GameAttempt.objects.count(), 1)

    def test_client_cannot_inject_level_milestone_metadata(self):
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)

        response = self.submit(
            level.game.slug,
            {
                **self.perfect_result(level),
                '_level_milestone': {'previous_level': 7, 'level': {'number': 8}},
            },
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(GameAttempt.objects.count(), 0)
        self.assertEqual(KidGameProgress.objects.count(), 0)

    def test_attempt_write_failure_rolls_back_progress_and_milestone(self):
        target = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        self.set_completed_progress(target.game, {1: 1})
        self.set_completed_progress(Game.objects.get(slug='ark-animal-match'), {1: 2})

        with patch(
            'apps.games.views.GameAttempt.objects.create',
            side_effect=IntegrityError('The attempt could not be recorded.'),
        ), self.assertRaises(IntegrityError):
            self.submit(target.game.slug, self.perfect_result(target))

        progress = KidGameProgress.objects.get(profile=self.profile, game=target.game)
        self.assertEqual(progress.level_progress['1']['best_stars'], 1)
        self.assertEqual(progress.level_progress['1']['attempts'], 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], 260)
        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_catalogue_requires_verified_authentication_and_profile(self):
        anonymous = APIClient()
        self.assertEqual(
            anonymous.get('/api/games/', {'profile_id': self.profile.pk}).status_code,
            401,
        )

        unverified = User.objects.create_user(
            email='pending-games@example.com',
            password=PASSWORD,
        )
        self.authenticate(unverified)
        self.assertEqual(self.catalogue().status_code, 401)

        self.authenticate(self.parent)
        missing = self.client.get('/api/games/')
        self.assertEqual(missing.status_code, 400)
        self.assertIn('profile_id', missing.data)

    def test_profile_scope_never_discloses_another_parents_child(self):
        other_parent = User.objects.create_user(
            email='other-games@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        other_profile = KidProfile.objects.create(
            parent=other_parent,
            display_name='Tomi',
            avatar_key=KidProfile.AvatarKey.LION,
        )

        self.assertEqual(self.catalogue(other_profile.pk).status_code, 404)
        self.assertEqual(self.detail('esther-quiz', other_profile.pk).status_code, 404)
        response = self.submit(
            'esther-quiz',
            self.perfect_result(GameLevel.objects.get(game__slug='esther-quiz', level_number=1)),
            profile=other_profile.pk,
        )
        self.assertEqual(response.status_code, 404)
        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_expanded_catalogue_keeps_original_games_and_profile_progress(self):
        response = self.catalogue()

        self.assertEqual(response.status_code, 200)
        # Twelve shipped games plus the six scoped legacy-engine fixtures.
        self.assertEqual(len(response.data), 18)
        self.assertEqual(
            [game['slug'] for game in response.data[:9]],
            [
                'ark-animal-match',
                'creation-order',
                'david-sling-shot',
                'jonah-ocean-maze',
                'red-sea-path',
                'daniel-memory',
                'esther-quiz',
                'moses-match',
                'puzzle-quest',
            ],
        )
        first = response.data[0]
        self.assertEqual(first['total_levels'], 3)
        self.assertEqual(first['difficulty'], 'Easy')
        self.assertEqual(first['estimated_duration_seconds'], 180)
        self.assertTrue(first['is_featured'])
        self.assertEqual(first['progress']['total_levels'], 3)
        self.assertEqual(first['progress']['max_stars'], 9)
        self.assertEqual(first['progress']['total_stars'], 0)
        self.assertEqual(first['progress']['completed_levels'], 0)
        self.assertIsNone(first['progress']['last_played_at'])
        self.assertEqual(
            {game['slug']: game['cover_asset_key'] for game in response.data[:9]},
            {
                'ark-animal-match': 'assets/images/stories/noah-builds-the-ark-v2.webp',
                'creation-order': 'assets/images/stories/creation-week-v2.webp',
                'david-sling-shot': 'assets/images/stories/david-and-goliath-v2.webp',
                'jonah-ocean-maze': 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
                'red-sea-path': 'assets/images/stories/crossing-the-red-sea-v2.webp',
                'daniel-memory': 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
                'esther-quiz': 'assets/images/stories/esther-speaks-up-v2.webp',
                'moses-match': 'assets/images/stories/moses-follows-god-v2.webp',
                'puzzle-quest': (
                    'assets/images/games/puzzle_quest/'
                    'puzzle-quest-cover-v1.webp'
                ),
            },
        )

    def test_unpublished_game_is_hidden_from_catalogue_and_detail(self):
        game = Game.objects.get(slug='esther-quiz')
        game.is_published = False
        game.save(update_fields=('is_published',))

        response = self.catalogue()
        self.assertNotIn('esther-quiz', [item['slug'] for item in response.data])
        self.assertEqual(self.detail('esther-quiz').status_code, 404)

    def test_detail_has_three_ordered_levels_and_hides_private_answers(self):
        quiz = self.detail('esther-quiz')
        self.assertEqual(quiz.status_code, 200)
        self.assertEqual([level['level_number'] for level in quiz.data['levels']], [1, 2, 3])
        quiz_config = quiz.data['levels'][0]['config']
        self.assertNotIn('pass_score', quiz_config)
        self.assertNotIn('correct_option_id', str(quiz_config))

        ordering = self.detail('creation-order').data['levels'][0]['config']
        self.assertNotIn('answer_sequence', ordering)
        matching = self.detail('ark-animal-match').data['levels'][0]['config']
        self.assertNotIn('expected_pairs', matching)

        memory = self.detail('daniel-memory').data['levels'][0]['config']
        self.assertIn('match_key', memory['cards'][0])
        self.assertEqual(len(memory['cards']), 6)

    def test_all_catalogue_levels_have_a_valid_complete_result(self):
        self.assertEqual(Game.objects.count(), 29)
        self.assertEqual(GameLevel.objects.count(), 87)

        for level in GameLevel.objects.select_related('game'):
            with self.subTest(game=level.game.slug, level=level.level_number):
                evaluation = evaluate_level(level, self.perfect_result(level))
                self.assertTrue(evaluation.completed)
                self.assertEqual(evaluation.score, level.max_score)
                self.assertEqual(evaluation.stars, 3)

    def test_quiz_submission_is_scored_server_side_and_updates_progress(self):
        level = GameLevel.objects.get(game__slug='esther-quiz', level_number=1)
        result = self.perfect_result(level)
        response = self.submit('esther-quiz', result)

        self.assertEqual(response.status_code, 201)
        self.assertTrue(response.data['completed'])
        self.assertEqual(response.data['score'], 100)
        self.assertEqual(response.data['stars'], 3)
        self.assertEqual(response.data['max_score'], 100)
        self.assertEqual(response.data['progress']['highest_completed_level'], 1)
        self.assertEqual(response.data['progress']['completed_levels'], 1)
        self.assertEqual(response.data['progress']['total_stars'], 3)

        progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
        self.assertEqual(progress.level_progress['1']['attempts'], 1)
        self.assertEqual(progress.level_progress['1']['best_score'], 100)

    def test_client_score_and_completion_fields_are_rejected(self):
        level = GameLevel.objects.get(game__slug='esther-quiz', level_number=1)
        result = {**self.perfect_result(level), 'score': 999, 'stars': 99}

        response = self.submit('esther-quiz', result)

        self.assertEqual(response.status_code, 400)
        self.assertIn('computed by the server', str(response.data))
        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_every_engine_rejects_unknown_result_fields(self):
        levels_by_type = {}
        for level in GameLevel.objects.select_related('game').order_by(
            'game__sort_order',
            'level_number',
        ):
            levels_by_type.setdefault(level.game.game_type, level)

        for game_type, level in levels_by_type.items():
            with self.subTest(game_type=game_type):
                response = self.submit(
                    level.game.slug,
                    {
                        **self.perfect_result(level),
                        'child_note': 'arbitrary retained data',
                    },
                )
                self.assertEqual(response.status_code, 400)
                self.assertIn('only contain', str(response.data))

        self.assertEqual(GameAttempt.objects.count(), 0)

    def test_wrong_quiz_answers_do_not_unlock_the_next_level(self):
        level = GameLevel.objects.get(game__slug='esther-quiz', level_number=1)
        answers = [
            {
                'question_id': question['id'],
                'option_id': next(
                    option['id']
                    for option in question['options']
                    if option['id'] != question['correct_option_id']
                ),
            }
            for question in level.config['questions']
        ]
        failed = self.submit('esther-quiz', {'answers': answers})
        self.assertEqual(failed.status_code, 201)
        self.assertFalse(failed.data['completed'])
        self.assertEqual(failed.data['stars'], 0)

        next_level = GameLevel.objects.get(game__slug='esther-quiz', level_number=2)
        locked = self.submit(
            'esther-quiz',
            self.perfect_result(next_level),
            level=2,
        )
        self.assertEqual(locked.status_code, 400)
        self.assertIn('previous level', str(locked.data))

    def test_completed_levels_unlock_in_order_and_keep_best_stars(self):
        first = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        second = GameLevel.objects.get(game__slug='creation-order', level_number=2)

        locked = self.submit('creation-order', self.perfect_result(second), level=2)
        self.assertEqual(locked.status_code, 400)

        self.assertEqual(
            self.submit('creation-order', self.perfect_result(first), level=1).status_code,
            201,
        )
        completed = self.submit('creation-order', self.perfect_result(second), level=2)
        self.assertEqual(completed.status_code, 201)
        self.assertEqual(completed.data['progress']['highest_completed_level'], 2)
        self.assertEqual(completed.data['progress']['total_stars'], 6)

    def test_identical_operation_is_replayed_without_double_progress(self):
        level = GameLevel.objects.get(game__slug='ark-animal-match', level_number=1)
        result = self.perfect_result(level)
        operation_id = uuid.uuid4()

        first = self.submit('ark-animal-match', result, operation_id=operation_id)
        replay = self.submit('ark-animal-match', result, operation_id=operation_id)

        self.assertEqual(first.status_code, 201)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(first.data['attempt_id'], replay.data['attempt_id'])
        self.assertFalse(first.data['idempotent_replay'])
        self.assertTrue(replay.data['idempotent_replay'])
        self.assertEqual(GameAttempt.objects.count(), 1)
        progress = KidGameProgress.objects.get(profile=self.profile, game=level.game)
        self.assertEqual(progress.level_progress['1']['attempts'], 1)
        self.assertEqual(progress.total_stars, 3)

    def test_changed_idempotent_operation_returns_conflict(self):
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        operation_id = uuid.uuid4()
        result = self.perfect_result(level)
        self.assertEqual(
            self.submit('creation-order', result, operation_id=operation_id).status_code,
            201,
        )

        changed = self.submit(
            'creation-order',
            {'sequence': list(reversed(result['sequence']))},
            operation_id=operation_id,
        )
        self.assertEqual(changed.status_code, 409)
        self.assertIn('different submission', changed.data['detail'])
        self.assertEqual(GameAttempt.objects.count(), 1)

    def test_matching_memory_maze_path_and_aim_are_authoritatively_validated(self):
        slugs = (
            'ark-animal-match',
            'daniel-memory',
            'jonah-ocean-maze',
            'red-sea-path',
            'david-sling-shot',
        )
        for slug in slugs:
            level = GameLevel.objects.get(game__slug=slug, level_number=1)
            with self.subTest(slug=slug):
                response = self.submit(slug, self.perfect_result(level))
                self.assertEqual(response.status_code, 201)
                self.assertTrue(response.data['completed'])
                self.assertEqual(response.data['score'], 100)

        bad_maze = self.submit(
            'jonah-ocean-maze',
            {'path': [[0, 0], [1, 1]]},
        )
        self.assertEqual(bad_maze.status_code, 400)
        self.assertIn('one square', str(bad_maze.data))

        bad_memory = self.submit(
            'daniel-memory',
            {'matched_pairs': [['prayer-a', 'window-a']], 'moves': 1, 'elapsed_seconds': 4},
        )
        self.assertEqual(bad_memory.status_code, 400)
        self.assertIn('do not match', str(bad_memory.data))

        too_many_shots = self.submit(
            'david-sling-shot',
            {'shots': [{'x': 0, 'y': 0}] * 4},
        )
        self.assertEqual(too_many_shots.status_code, 400)
        self.assertIn('No more than', str(too_many_shots.data))

    def test_model_and_database_prevent_duplicate_levels_and_progress(self):
        game = Game.objects.get(slug='esther-quiz')
        existing = game.levels.get(level_number=1)
        with self.assertRaises(DjangoValidationError):
            GameLevel.objects.create(
                game=game,
                level_number=1,
                title='Duplicate',
                instructions='No',
                config=existing.config,
                max_score=existing.max_score,
                star_thresholds=existing.star_thresholds,
            )

        KidGameProgress.objects.create(profile=self.profile, game=game)
        with self.assertRaises(IntegrityError), transaction.atomic():
            KidGameProgress.objects.create(profile=self.profile, game=game)

    def test_level_authoring_rejects_invalid_config_and_number_gaps(self):
        game = Game.objects.create(
            slug='authoring-test',
            title='Authoring Test',
            subtitle='A safe draft',
            description='Used to validate game content.',
            game_type=Game.Type.ORDERING,
            cover_asset_key='assets/images/creation_week.jpg',
            is_published=False,
        )

        with self.assertRaises(DjangoValidationError) as invalid_config:
            GameLevel.objects.create(
                game=game,
                level_number=1,
                title='Broken order',
                instructions='Arrange the cards.',
                config={'items': []},
                star_thresholds=[60, 80, 95],
            )
        self.assertIn('config', invalid_config.exception.message_dict)

        first = GameLevel.objects.create(
            game=game,
            level_number=1,
            title='First',
            instructions='Arrange the cards.',
            config={
                'items': [
                    {'id': 'a', 'label': 'First'},
                    {'id': 'b', 'label': 'Second'},
                ],
                'answer_sequence': ['a', 'b'],
            },
            star_thresholds=[60, 80, 95],
        )
        with self.assertRaises(DjangoValidationError) as skipped_level:
            GameLevel.objects.create(
                game=game,
                level_number=3,
                title='Skipped',
                instructions='This cannot strand level two.',
                config=first.config,
                star_thresholds=[60, 80, 95],
            )
        self.assertIn('level_number', skipped_level.exception.message_dict)

    def test_changing_game_type_revalidates_existing_levels(self):
        game = Game.objects.get(slug='creation-order')
        game.game_type = Game.Type.QUIZ

        with self.assertRaises(DjangoValidationError) as incompatible:
            game.save(update_fields=('game_type',))

        self.assertIn('game_type', incompatible.exception.message_dict)

    def test_game_attempt_model_rejects_updates_and_direct_deletes(self):
        level = GameLevel.objects.get(game__slug='creation-order', level_number=1)
        attempt = GameAttempt.objects.create(
            operation_id=uuid.uuid4(),
            profile=self.profile,
            game=level.game,
            level=level,
            submitted_result=self.perfect_result(level),
            completed=True,
            score=100,
            stars=3,
            feedback='Complete',
            evaluation={},
        )

        attempt.feedback = 'Tampered'
        with self.assertRaises(DjangoValidationError):
            attempt.save(update_fields=('feedback',))
        with self.assertRaises(DjangoValidationError):
            attempt.delete()

    @classmethod
    def perfect_result(cls, level):
        config = level.config
        game_type = level.game.game_type
        if game_type == Game.Type.QUIZ:
            return {
                'answers': [
                    {
                        'question_id': question['id'],
                        'option_id': question['correct_option_id'],
                    }
                    for question in config['questions']
                ]
            }
        if game_type == Game.Type.ORDERING:
            if config.get('mode') == 'wise_builders':
                return example_builders_result(config)
            return {'sequence': config['answer_sequence']}
        if game_type == Game.Type.MATCHING:
            result = {
                'pairs': [
                    {'left_id': left_id, 'right_id': right_id}
                    for left_id, right_id in config['expected_pairs'].items()
                ]
            }
            if config.get('mode') == 'ark_boarding':
                result['elapsed_seconds'] = 1
            return result
        if game_type == Game.Type.MEMORY:
            by_match = {}
            for card in config['cards']:
                by_match.setdefault(card['match_key'], []).append(card['id'])
            return {
                'matched_pairs': list(by_match.values()),
                'moves': len(by_match),
                'elapsed_seconds': 0,
            }
        if game_type in {Game.Type.MAZE, Game.Type.PATH}:
            return {'path': cls.shortest_path(config['grid'])}
        if game_type == Game.Type.AIM:
            return {
                'shots': [
                    {
                        'x': config['target']['x'],
                        'y': config['target']['y'],
                    }
                ]
            }
        if game_type == Game.Type.PUZZLE:
            return {
                'placements': [
                    {'piece_id': piece_id, 'slot_id': slot_id}
                    for piece_id, slot_id in config['solution'].items()
                ],
                'moves': len(config['solution']),
                'elapsed_seconds': 0,
            }
        raise AssertionError(f'Unsupported test game type: {game_type}')

    @staticmethod
    def shortest_path(grid):
        start = tuple(grid['start'])
        end = tuple(grid['end'])
        walls = {tuple(value) for value in grid['walls']}
        queue = deque([(start, [start])])
        seen = {start}
        while queue:
            current, path = queue.popleft()
            if current == end:
                return [list(value) for value in path]
            row, column = current
            for neighbor in (
                (row - 1, column),
                (row + 1, column),
                (row, column - 1),
                (row, column + 1),
            ):
                n_row, n_column = neighbor
                if (
                    0 <= n_row < grid['rows']
                    and 0 <= n_column < grid['columns']
                    and neighbor not in walls
                    and neighbor not in seen
                ):
                    seen.add(neighbor)
                    queue.append((neighbor, path + [neighbor]))
        raise AssertionError('Seeded grid has no playable route.')
