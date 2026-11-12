"""Protect original progress and verify the additive story/puzzle contract."""
import copy
import importlib
from types import SimpleNamespace

from django.apps import apps
from django.db import connection
from django.db.migrations.loader import MigrationLoader
from django.test import TestCase

from apps.games.models import Game, GameLevel
from apps.games.services import evaluate_level
from apps.games.validators import validate_level_definition

from .catalogue_expansion_v1 import STORIES, PUZZLE_THEMES
from .models import NarratorVoice, Story, StoryNarration


EXPANSION = importlib.import_module('apps.stories.migrations.0009_additional_bible_stories')
ORIGINAL_STORIES = {
    'david-and-goliath', 'jonah-and-the-big-fish', 'crossing-the-red-sea',
    'noah-builds-the-ark', 'creation-week', 'daniel-in-the-lions-den',
    'moses-follows-god', 'esther-speaks-up',
}
ORIGINAL_GAMES = {
    'ark-animal-match', 'creation-order', 'david-sling-shot', 'jonah-ocean-maze',
    'red-sea-path', 'daniel-memory', 'esther-quiz', 'moses-match', 'puzzle-quest',
}


class AdditionalCatalogueTests(TestCase):
    def test_five_readable_original_retellings_have_existing_character_options(self):
        new = Story.objects.filter(slug__in=[story['slug'] for story in STORIES])
        self.assertEqual(new.count(), 5)
        self.assertEqual(Story.objects.filter(slug__in=ORIGINAL_STORIES).count(), 8)
        self.assertEqual(set(NarratorVoice.objects.values_list('voice_key', flat=True)),
                         {'kai', 'nia', 'zuri'})
        for story in new:
            with self.subTest(story=story.slug):
                self.assertTrue(180 <= len(story.body.split()) <= 250)
                self.assertEqual(len(story.body.split('\n\n')), 5)
                self.assertEqual(story.reading_time_minutes, 2)
                self.assertEqual(story.cover_asset_key,
                                 f'assets/images/stories/{story.slug}-storybook-v1.webp')
                self.assertEqual(set(story.narrations.values_list('narrator_id', flat=True)),
                                 {'lion', 'dove', 'rainbow'})
                self.assertEqual(set(story.narrations.values_list('status', flat=True)),
                                 {'processing'})
                self.assertTrue(all(not track.audio_available for track in story.narrations.all()))

    def test_ruth_gleans_to_support_naomi_and_jericho_has_no_graphic_details(self):
        ruth = Story.objects.get(slug='ruth-and-naomi').body
        self.assertIn('grain that the harvesters left behind', ruth)
        self.assertIn('brought grain and leftover food back to Naomi', ruth)
        self.assertIn('Boaz made sure she could work safely', ruth)
        jericho = Story.objects.get(slug='walls-of-jericho').body
        self.assertIn('For six days', jericho)
        self.assertIn('seventh day', jericho)
        self.assertIn('seven times', jericho)
        self.assertIn('Rahab and her family were brought to safety', jericho)
        for word in ('blood', 'slaughter', 'corpse', 'sword'):
            self.assertNotIn(word, jericho.lower())

    def test_ten_extra_puzzle_themes_each_have_three_playable_piece_sizes(self):
        slugs = {f'puzzle-{theme[0]}' for theme in PUZZLE_THEMES}
        games = Game.objects.filter(slug__in=slugs)
        self.assertEqual(games.count(), 10)
        ids = set()
        for game in games:
            self.assertEqual(game.game_type, 'puzzle')
            levels = list(game.levels.order_by('level_number'))
            self.assertEqual([level.level_number for level in levels], [1, 2, 3])
            self.assertEqual([len(level.config['pieces']) for level in levels], [4, 6, 9])
            for level in levels:
                with self.subTest(game=game.slug, level=level.level_number):
                    validate_level_definition(game_type='puzzle', config=level.config,
                                              max_score=100, star_thresholds=[60, 80, 95])
                    config = level.config
                    self.assertEqual(config['artwork']['asset_key'], game.cover_asset_key)
                    for piece in config['pieces']:
                        self.assertNotIn(piece['id'], ids)
                        ids.add(piece['id'])
                    result = {
                        'placements': [{'piece_id': key, 'slot_id': value}
                                       for key, value in config['solution'].items()],
                        'moves': config['target_moves'],
                        'elapsed_seconds': config['target_seconds'],
                    }
                    evaluation = evaluate_level(level, result)
                    self.assertTrue(evaluation.completed)
                    self.assertEqual(evaluation.score, 100)
                    self.assertEqual(evaluation.stars, 3)
                    wrong = copy.deepcopy(result)
                    first, second = wrong['placements'][:2]
                    first['slot_id'], second['slot_id'] = second['slot_id'], first['slot_id']
                    self.assertFalse(evaluate_level(level, wrong).completed)

    def test_seeding_twice_preserves_all_original_ids_content_and_voice_settings(self):
        originals = list(Story.objects.filter(slug__in=ORIGINAL_STORIES).values())
        games = list(Game.objects.filter(slug__in=ORIGINAL_GAMES).values())
        levels = list(GameLevel.objects.filter(game__slug__in=ORIGINAL_GAMES).values())
        voices = list(NarratorVoice.objects.values())
        narration_ids = list(StoryNarration.objects.order_by('pk').values_list('pk', flat=True))
        edited = Story.objects.get(slug='lost-sheep')
        edited.body += '\n\nAn editor’s later note.'
        edited.save(update_fields=['body'])
        EXPANSION.add_story_and_puzzle_catalogue(apps, SimpleNamespace(connection=connection))
        EXPANSION.add_story_and_puzzle_catalogue(apps, SimpleNamespace(connection=connection))
        self.assertEqual(list(Story.objects.filter(slug__in=ORIGINAL_STORIES).values()), originals)
        self.assertEqual(list(Game.objects.filter(slug__in=ORIGINAL_GAMES).values()), games)
        self.assertEqual(list(GameLevel.objects.filter(game__slug__in=ORIGINAL_GAMES).values()), levels)
        self.assertEqual(list(NarratorVoice.objects.values()), voices)
        self.assertEqual(list(StoryNarration.objects.order_by('pk').values_list('pk', flat=True)), narration_ids)
        edited.refresh_from_db()
        self.assertTrue(edited.body.endswith('An editor’s later note.'))
        self.assertEqual(Game.objects.get(slug='esther-quiz').game_type, 'quiz')
        self.assertEqual(Game.objects.get(slug='daniel-memory').game_type, 'memory')
        self.assertEqual(Game.objects.get(slug='puzzle-quest').game_type, 'puzzle')

    def test_migration_graph_depends_only_on_existing_story_and_ark_nodes(self):
        loader = MigrationLoader(None)
        plan = loader.graph.forwards_plan(('stories', '0009_additional_bible_stories'))
        self.assertIn(('stories', '0008_recorded_word_timings'), plan)
        self.assertIn(('games', '0014_ark_traffic_routes'), plan)
        self.assertEqual(loader.disk_migrations[('stories', '0009_additional_bible_stories')].dependencies,
                         [('stories', '0008_recorded_word_timings'), ('games', '0014_ark_traffic_routes')])
