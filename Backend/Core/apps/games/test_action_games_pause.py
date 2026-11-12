"""Pausing action-game availability preserves every retained activity and XP."""

import importlib
import io
from pathlib import Path
from types import SimpleNamespace
import uuid
from unittest.mock import patch

from django.apps import apps
from django.core.management import call_command
from django.core.cache import cache
from django.db import connection
from django.db.migrations.loader import MigrationLoader
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, KidProfilePreferences, User
from apps.progress.models import KidActivityEvent, StreakDailyVisit
from apps.progress.services import build_kid_profile_summary, build_profile_level
from apps.stories.models import NarratorVoice, Story, StoryNarration

from .ark_garden import build_ark_garden_config
from .matching_collection import example_scene_matching_result
from .matching_studio import example_coat_studio_result, example_harvest_chain_result
from .models import Game, GameAttempt, GameLevel, KidGameProgress


PAUSE = importlib.import_module('apps.games.migrations.0022_pause_action_games')
PAUSED_SLUGS = set(PAUSE.PAUSED_GAME_SLUGS)
MATCHING_SLUGS = {
    'josephs-coat-studio', 'ruths-harvest', 'find-my-sheep',
    'creation-match-bloom', 'esthers-celebration-table',
}
PUZZLE_SLUGS = {'puzzle-quest', 'puzzle-esther', 'puzzle-noah', 'puzzle-david', 'puzzle-lost-sheep'}
QUIZ_SLUGS = {'esther-quiz', 'noah-quiz', 'david-quiz', 'jonah-quiz', 'lost-sheep-quiz'}
PRESERVED_MODELS = (
    GameLevel, GameAttempt, KidGameProgress, User, KidProfile, KidProfilePreferences,
    KidActivityEvent, StreakDailyVisit, Story, StoryNarration, NarratorVoice,
)


def rows(model):
    return list(model.objects.order_by('pk').values())


class ActionGamesPauseTests(TestCase):
    def setUp(self):
        # TestCase rolls the database back, but throttle cache keys otherwise
        # survive and can alias the next fixture's reused parent primary key.
        cache.clear()
        self.addCleanup(cache.clear)
        self.default_publication = dict(Game.objects.filter(
            slug__in=PAUSED_SLUGS).values_list('slug', 'is_published'))
        # These five matching games and the Ark are local installer content,
        # not historical migration seeds. Model the full current catalogue.
        with patch('apps.games.management.commands.install_matching_studio.backup_local_database',
                   return_value=Path('/private/tmp/pause-fixture-backup.sqlite3')):
            call_command('install_matching_studio', publish=True, stdout=io.StringIO())
            call_command('install_matching_collection', publish=True, stdout=io.StringIO())
        ark = Game.objects.create(
            slug='noahs-ark-garden', title='Noah’s Ark Garden', subtitle='All aboard',
            description='Find the animals and help them board.', game_type=Game.Type.MATCHING,
            cover_asset_key='story:noah', is_published=True,
        )
        GameLevel.objects.create(
            game=ark, level_number=1, title='All aboard',
            instructions='Help the animals board.', config=build_ark_garden_config(),
        )
        Game.objects.filter(slug__in=PAUSED_SLUGS).update(is_published=True)
        self.parent = User.objects.create_user(
            email='action-pause@example.com', password='Pause-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(parent=self.parent, display_name='Ada', avatar_key='lion')
        self.client = APIClient()
        self.client.force_authenticate(self.parent)
        self.editor = SimpleNamespace(connection=connection)

    def pause(self):
        PAUSE.pause_action_games(apps, self.editor)

    def catalogue(self):
        return self.client.get('/api/games/', {'profile_id': self.profile.pk})

    def saved_history(self):
        for index, game in enumerate(Game.objects.filter(slug__in=PAUSED_SLUGS).order_by('slug')):
            level = game.levels.get(level_number=1)
            completion = {'completed': True, 'best_stars': 3, 'best_score': 100, 'attempts': 1}
            # Missing historical completion_xp retains the old 100-XP rate;
            # the newer snapshot keeps its recorded 50 XP after pausing.
            if index == 1:
                completion['completion_xp'] = 50
            KidGameProgress.objects.create(
                profile=self.profile, game=game, highest_completed_level=1,
                total_stars=3, level_progress={'1': completion},
            )
            GameAttempt.objects.create(
                operation_id=uuid.uuid4(), profile=self.profile, game=game, level=level,
                submitted_result={}, completed=True, score=100, stars=3,
                feedback='Saved before the pause.', evaluation={'saved': True},
            )
        KidActivityEvent.objects.create(
            profile=self.profile, operation_id=uuid.uuid4(),
            event_type=KidActivityEvent.EventType.STORY_COMPLETED,
            story=Story.objects.filter(is_published=True).first(),
        )
        StreakDailyVisit.objects.create(
            profile=self.profile, local_date=timezone.localdate(),
            state=StreakDailyVisit.State.FIRST_STREAK, timezone_offset_minutes=60,
        )

    def test_default_migration_pauses_only_seeded_action_games_and_keeps_definitions(self):
        self.assertEqual(self.default_publication,
                         {'david-sling-shot': False, 'jonah-ocean-maze': False})
        self.assertEqual(GameLevel.objects.filter(game__slug__in=PAUSED_SLUGS).count(), 7)
        self.assertEqual(Game.objects.filter(slug__in=PAUSED_SLUGS).count(), 3)

    def test_paused_catalogue_keeps_five_puzzles_five_quizzes_and_five_matching_games(self):
        self.assertEqual(len(self.catalogue().data), 18)
        self.pause()
        response = self.catalogue()
        self.assertEqual(response.status_code, 200)
        self.assertEqual({game['slug'] for game in response.data},
                         PUZZLE_SLUGS | QUIZ_SLUGS | MATCHING_SLUGS)
        for kind in ('puzzle', 'quiz', 'matching'):
            self.assertEqual(sum(game['game_type'] == kind for game in response.data), 5)
        self.assertEqual(sum(game['total_levels'] for game in response.data), 45)

    def test_stale_links_new_submissions_and_saved_retries_cannot_play_paused_games(self):
        self.saved_history()
        xp = build_profile_level(self.profile)
        attempts, progress = rows(GameAttempt), rows(KidGameProgress)
        self.pause()
        for slug in PAUSED_SLUGS:
            with self.subTest(slug=slug):
                self.assertEqual(self.client.get(f'/api/games/{slug}/',
                    {'profile_id': self.profile.pk}).status_code, 404)
                attempt = GameAttempt.objects.get(game__slug=slug)
                for operation in (uuid.uuid4(), attempt.operation_id):
                    self.assertEqual(self.client.post(f'/api/games/{slug}/submit/', {
                        'profile_id': str(self.profile.pk), 'level_number': 1,
                        'operation_id': str(operation), 'result': attempt.submitted_result,
                    }, format='json').status_code, 404)
        self.assertEqual(rows(GameAttempt), attempts)
        self.assertEqual(rows(KidGameProgress), progress)
        self.assertEqual(build_profile_level(self.profile), xp)

    def test_idempotent_pause_and_noop_rollback_change_only_three_publication_flags(self):
        self.saved_history()
        preserved = {model: rows(model) for model in PRESERVED_MODELS}
        expected_games = rows(Game)
        for row in expected_games:
            if row['slug'] in PAUSED_SLUGS:
                row['is_published'] = False
        xp = build_profile_level(self.profile)
        self.assertEqual(build_kid_profile_summary(self.profile)['stats']['completed_game_levels'], 3)
        for _ in range(2):
            self.pause()
        PAUSE.Migration.operations[0].reverse_code(apps, self.editor)
        self.assertEqual(rows(Game), expected_games)
        for model, expected in preserved.items():
            self.assertEqual(rows(model), expected, model.__name__)
        self.assertEqual(build_profile_level(self.profile), xp)
        summary = build_kid_profile_summary(self.profile)
        self.assertEqual(summary['stats']['completed_game_levels'], 0)
        self.assertEqual(summary['stats']['total_game_levels'], 45)
        self.assertEqual(summary['xp_breakdown']['quests'], 430)

    def test_pause_does_not_create_missing_games_or_catch_future_games_by_type_or_prefix(self):
        Game.objects.filter(slug='noahs-ark-garden').delete()
        for slug, kind in (('david-sling-shot-future', Game.Type.AIM),
                           ('jonah-ocean-maze-preview', Game.Type.MAZE),
                           ('noahs-ark-garden-future', Game.Type.MATCHING)):
            Game.objects.create(slug=slug, title='Future game', subtitle='Keep available',
                description='Exact pause boundary.', game_type=kind,
                cover_asset_key='story:noah', is_published=True)
        self.pause()
        self.assertFalse(Game.objects.filter(slug='noahs-ark-garden').exists())
        self.assertEqual(Game.objects.filter(slug__in=PAUSED_SLUGS).count(), 2)
        self.assertEqual(Game.objects.filter(slug__endswith='-future', is_published=True).count(), 2)
        self.assertTrue(Game.objects.get(slug='jonah-ocean-maze-preview').is_published)

    @staticmethod
    def perfect_result(level):
        config = level.config
        if level.game.game_type == Game.Type.QUIZ:
            return {'answers': [{'question_id': question['id'], 'option_id': question['correct_option_id']}
                                for question in config['questions']]}
        if level.game.game_type == Game.Type.PUZZLE:
            return {'placements': [{'piece_id': piece, 'slot_id': slot}
                                   for piece, slot in config['solution'].items()],
                    'moves': config['target_moves'], 'elapsed_seconds': config['target_seconds']}
        if config['mode'] == 'coat_studio':
            return example_coat_studio_result(config)
        if config['mode'] == 'harvest_chain':
            return example_harvest_chain_result(config)
        return example_scene_matching_result(config)

    def test_all_retained_activities_still_score_and_award_only_once(self):
        self.pause()
        for slug in sorted(PUZZLE_SLUGS | QUIZ_SLUGS | MATCHING_SLUGS):
            with self.subTest(slug=slug):
                self.assertEqual(self.client.get(f'/api/games/{slug}/',
                    {'profile_id': self.profile.pk}).status_code, 200)
                level = GameLevel.objects.select_related('game').get(game__slug=slug, level_number=1)
                payload = {'profile_id': str(self.profile.pk), 'level_number': 1,
                           'operation_id': str(uuid.uuid4()), 'result': self.perfect_result(level)}
                created = self.client.post(f'/api/games/{slug}/submit/', payload, format='json')
                retry = self.client.post(f'/api/games/{slug}/submit/', payload, format='json')
                self.assertEqual((created.status_code, retry.status_code), (201, 200))
                self.assertTrue(created.data['completed'])
                self.assertEqual(created.data['attempt_id'], retry.data['attempt_id'])
        self.assertEqual(GameAttempt.objects.count(), 15)
        stars = sum(KidGameProgress.objects.values_list('total_stars', flat=True))
        self.assertEqual(build_profile_level(self.profile)['xp'], 15 * 50 + stars * 20)

    def test_explicit_future_publication_restores_same_game_and_receipt_without_new_xp(self):
        self.saved_history()
        game = Game.objects.get(slug='david-sling-shot')
        attempt = GameAttempt.objects.get(game=game)
        before = {model: rows(model) for model in PRESERVED_MODELS}
        xp = build_profile_level(self.profile)
        self.pause()
        # Resuming is an explicit editorial decision, not a migration rollback.
        Game.objects.filter(pk=game.pk).update(is_published=True)
        self.assertEqual(self.client.get(f'/api/games/{game.slug}/',
            {'profile_id': self.profile.pk}).status_code, 200)
        response = self.client.post(f'/api/games/{game.slug}/submit/', {
            'profile_id': str(self.profile.pk), 'level_number': 1,
            'operation_id': str(attempt.operation_id), 'result': attempt.submitted_result,
        }, format='json')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['attempt_id'], attempt.pk)
        self.assertTrue(response.data['idempotent_replay'])
        self.assertEqual(build_profile_level(self.profile), xp)
        for model, expected in before.items():
            self.assertEqual(rows(model), expected, model.__name__)

    def test_migration_is_additive_after_catalogue_pruning_and_has_safe_reverse(self):
        loader = MigrationLoader(None)
        node = ('games', '0022_pause_action_games')
        self.assertEqual(loader.disk_migrations[node].dependencies,
                         [('games', '0021_prune_quiz_and_puzzle_catalogue')])
        self.assertEqual(len(PAUSE.Migration.operations), 1)
        self.assertEqual(PAUSED_SLUGS, {'david-sling-shot', 'jonah-ocean-maze', 'noahs-ark-garden'})
