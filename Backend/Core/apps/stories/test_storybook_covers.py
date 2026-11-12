"""A cover replacement must leave reading, narration and puzzle progress intact."""
import hashlib
import importlib
import uuid
from types import SimpleNamespace

from django.apps import apps
from django.db import connection
from django.db.migrations.loader import MigrationLoader
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import KidProfile, User
from apps.games.models import Game, GameAttempt, GameLevel, KidGameProgress
from apps.progress.models import KidActivityEvent

from .catalogue_expansion_v1 import STORIES
from .catalogue_policy import UNAVAILABLE_STORY_SLUGS
from .models import Story, StoryNarration


COVERS = importlib.import_module('apps.stories.migrations.0010_storybook_cover_artwork')
SLUGS = COVERS.STORY_SLUGS


def asset_key(slug, version='storybook-v1'):
    return f'assets/images/stories/{slug}-{version}.webp'


def rows(model):
    return list(model.objects.order_by('pk').values())


class StorybookCoverTests(TestCase):
    def setUp(self):
        self.schema_editor = SimpleNamespace(connection=connection)
        self.parent = User.objects.create_user(
            email='storybook-cover@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent, display_name='Cover reader', avatar_key='lion',
        )

    def test_cover_migration_preserves_every_other_field_and_earned_progress(self):
        COVERS.restore_previous_cover_references(apps, self.schema_editor)
        story = Story.objects.get(slug='lost-sheep')
        story.body += '\n\nAn editor’s later revision remains intact.'
        story.save(update_fields=['body'])
        track = story.narrations.get(narrator_id='lion')
        track.text_sha256 = hashlib.sha256(story.body.encode()).hexdigest()
        track.audio_file = 'character_narration/accepted-kai-recording.mp3'
        track.segments = [{'index': 0, 'start': 0.0, 'end': 2.0}]
        track.words = [{'word': 'Jesus', 'start': 0.0, 'end': 0.5}]
        track.duration_seconds = 120
        track.save(update_fields=[
            'text_sha256', 'audio_file', 'segments', 'words', 'duration_seconds',
        ])
        KidActivityEvent.objects.create(
            profile=self.profile, story=story, operation_id=uuid.uuid4(),
            event_type='story_completed', reward_receipt={'xp_awarded': 50},
        )
        game = Game.objects.get(slug='puzzle-lost-sheep')
        level = game.levels.get(level_number=1)
        KidGameProgress.objects.create(
            profile=self.profile, game=game, highest_completed_level=1,
            total_stars=3,
            level_progress={'1': {'completed': True, 'completion_xp': 50}},
        )
        GameAttempt.objects.create(
            profile=self.profile, game=game, level=level,
            operation_id=uuid.uuid4(), completed=True, score=100, stars=3,
            feedback='Picture complete.', evaluation={'xp_awarded': 110},
        )
        expected_stories = rows(Story)
        expected_games = rows(Game)
        expected_levels = rows(GameLevel)
        for row in expected_stories:
            if row['slug'] in SLUGS:
                row['cover_asset_key'] = asset_key(row['slug'])
        game_slugs = {row['id']: row['slug'] for row in expected_games}
        for row in expected_games:
            if row['slug'].removeprefix('puzzle-') in SLUGS:
                row['cover_asset_key'] = asset_key(row['slug'].removeprefix('puzzle-'))
        for row in expected_levels:
            slug = game_slugs[row['game_id']].removeprefix('puzzle-')
            if slug in SLUGS:
                row['config']['artwork']['asset_key'] = asset_key(slug)
        unchanged = {model: rows(model) for model in (
            StoryNarration, KidProfile, KidActivityEvent, GameAttempt, KidGameProgress,
        )}

        COVERS.use_storybook_covers(apps, self.schema_editor)

        self.assertEqual(rows(Story), expected_stories)
        self.assertEqual(rows(Game), expected_games)
        self.assertEqual(rows(GameLevel), expected_levels)
        for model, expected in unchanged.items():
            self.assertEqual(rows(model), expected)
        self.assertEqual(GameLevel.objects.filter(
            game__slug__in=[f'puzzle-{slug}' for slug in SLUGS],
        ).count(), 15)

    def test_repeated_migration_and_reverse_preserve_later_editorial_artwork(self):
        story = Story.objects.get(slug='lost-sheep')
        game = Game.objects.get(slug='puzzle-lost-sheep')
        level = game.levels.get(level_number=1)
        custom_asset = 'assets/images/stories/editor-approved-cover.webp'
        story.cover_asset_key = custom_asset
        story.save(update_fields=['cover_asset_key'])
        game.cover_asset_key = custom_asset
        game.save(update_fields=['cover_asset_key'])
        level.config['artwork']['asset_key'] = custom_asset
        level.save(update_fields=['config'])
        COVERS.use_storybook_covers(apps, self.schema_editor)
        expected = (rows(Story), rows(Game), rows(GameLevel))
        COVERS.use_storybook_covers(apps, self.schema_editor)
        self.assertEqual((rows(Story), rows(Game), rows(GameLevel)), expected)
        COVERS.restore_previous_cover_references(apps, self.schema_editor)
        story.refresh_from_db()
        game.refresh_from_db()
        level.refresh_from_db()
        self.assertEqual(story.cover_asset_key, custom_asset)
        self.assertEqual(game.cover_asset_key, custom_asset)
        self.assertEqual(level.config['artwork']['asset_key'], custom_asset)

    def test_story_and_puzzle_apis_return_matching_storybook_asset_references(self):
        # These four later-retired puzzle themes remain explicit fixtures for
        # the preserved cover API contract; their default publication stays off.
        Game.objects.filter(slug__in=[f'puzzle-{slug}' for slug in SLUGS]).update(is_published=True)
        client = APIClient()
        token = RefreshToken.for_user(self.parent).access_token
        client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')
        story_response = client.get('/api/stories/')
        game_response = client.get('/api/games/', {'profile_id': self.profile.pk})
        self.assertEqual(story_response.status_code, 200)
        self.assertEqual(game_response.status_code, 200)
        story_covers = {row['slug']: row['cover_asset_key'] for row in story_response.data}
        game_covers = {row['slug']: row['cover_asset_key'] for row in game_response.data}
        for slug in SLUGS:
            with self.subTest(slug=slug):
                expected = asset_key(slug)
                self.assertEqual(game_covers[f'puzzle-{slug}'], expected)
                story_detail = client.get(f'/api/stories/{slug}/')
                game_detail = client.get(
                    f'/api/games/puzzle-{slug}/', {'profile_id': self.profile.pk},
                )
                if slug in UNAVAILABLE_STORY_SLUGS:
                    # Editorially hidden stories retain their puzzle artwork.
                    self.assertNotIn(slug, story_covers)
                    self.assertEqual(story_detail.status_code, 404)
                else:
                    self.assertEqual(story_covers[slug], expected)
                    self.assertEqual(story_detail.status_code, 200)
                    self.assertEqual(story_detail.data['cover_asset_key'], expected)
                self.assertEqual(game_detail.status_code, 200)
                self.assertEqual(game_detail.data['cover_asset_key'], expected)
                self.assertEqual([
                    level['config']['artwork']['asset_key']
                    for level in game_detail.data['levels']
                ], [expected] * 3)

    def test_migration_is_additive_without_rewriting_the_frozen_story_seed(self):
        loader = MigrationLoader(None)
        node = ('stories', '0010_storybook_cover_artwork')
        self.assertEqual(loader.disk_migrations[node].dependencies,
                         [('stories', '0009_additional_bible_stories')])
        self.assertIn(('stories', '0009_additional_bible_stories'),
                      loader.graph.forwards_plan(node))
        for story in STORIES:
            self.assertEqual(story['cover_asset_key'],
                             asset_key(story['slug'], 'blender-v1'))
