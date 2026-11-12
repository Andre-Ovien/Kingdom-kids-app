"""Stage the two new portrait matching games without altering legacy history."""

from pathlib import Path
import sqlite3

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from apps.games.matching_studio import (build_coat_studio_config,
                                       build_harvest_chain_config)
from apps.games.models import Game, GameLevel
from apps.games.validators import validate_level_definition

DEFINITIONS = (
    {
        'slug': 'josephs-coat-studio', 'title': 'Joseph’s Coat Studio',
        'subtitle': 'A little stitch. A lot of colour.',
        'description': 'Become a little coat designer. Find each fabric’s colour and pattern, stitch it into Joseph’s coat, and watch your creation come to life.',
        'mode': 'coat_studio', 'builder': build_coat_studio_config,
        'cover_asset_key': 'assets/images/stories/joseph-colorful-coat-storybook-v1.webp',
        'accent_color': '#C96B4A', 'icon_key': 'palette', 'sort_order': 50,
        'estimated_duration_seconds': 90,
        'round_titles': ('First stitches', 'Colour play', 'Masterpiece'),
        'instructions': 'Match each fabric’s colour and pattern to Joseph’s coat.',
    },
    {
        'slug': 'ruths-harvest', 'title': 'Ruth’s Harvest',
        'subtitle': 'Little bundles. Big kindness.',
        'description': 'Trace a path through matching grain bundles to gather a generous harvest. Fill Naomi’s three baskets with wheat, barley and oats.',
        'mode': 'harvest_chain', 'builder': build_harvest_chain_config,
        'cover_asset_key': 'assets/images/stories/ruth-and-naomi-storybook-v1.webp',
        'accent_color': '#A57B33', 'icon_key': 'grass', 'sort_order': 51,
        'estimated_duration_seconds': 120,
        'round_titles': ('Morning gathering', 'A generous basket', 'Harvest of kindness'),
        'instructions': 'Join three or more matching grain bundles to fill Naomi’s baskets.',
    },
)


def backup_local_database(directory):
    database = settings.DATABASES['default']
    if database['ENGINE'] != 'django.db.backends.sqlite3':
        raise CommandError('This review installer is limited to the local SQLite database.')
    source = Path(database['NAME']).resolve()
    if not source.is_file():
        raise CommandError('The local database must exist before it can be backed up.')
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    stamp = timezone.now().strftime('%Y%m%d-%H%M%S-%f')
    destination = directory / f'pre-matching-studio-{stamp}.sqlite3'
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as original:
        with sqlite3.connect(destination) as backup:
            original.backup(backup)
    return destination


def _desired_game(definition, previous, publish):
    return {
        key: definition[key] for key in (
            'title', 'subtitle', 'description', 'cover_asset_key', 'accent_color',
            'icon_key', 'sort_order', 'estimated_duration_seconds')
    } | {
        'game_type': Game.Type.MATCHING, 'difficulty': Game.Difficulty.EASY,
        'is_featured': False,
        # Staging cannot unexpectedly hide an already-approved local game.
        'is_published': bool(publish) or bool(previous and previous.is_published),
    }


def _desired_level(definition, number):
    return {'title': definition['round_titles'][number - 1],
            'instructions': definition['instructions'],
            'config': definition['builder'](number),
            'max_score': 100, 'star_thresholds': [60, 80, 95]}


def _check_identity(game, definition):
    if game is None:
        return
    levels = list(game.levels.all())
    if game.game_type != Game.Type.MATCHING or any(
            level.level_number not in (1, 2, 3) or level.config.get('mode') != definition['mode']
            for level in levels):
        raise CommandError(f'{game.slug} already belongs to another definition; nothing was changed.')
    for level in levels:
        desired = _desired_level(definition, level.level_number)
        if level.attempts.exists() and (level.config != desired['config'] or
                level.max_score != desired['max_score'] or level.star_thresholds != desired['star_thresholds']):
            raise CommandError(f'{game.slug} has played rules that differ from this version; nothing was changed.')


class Command(BaseCommand):
    definitions = DEFINITIONS
    help = 'Stage Joseph’s Coat Studio and Ruth’s Harvest locally, retaining all existing history.'

    def add_arguments(self, parser):
        parser.add_argument('--backup-directory', type=Path,
                            default=settings.BASE_DIR / '.cache/matching-studio-backups')
        parser.add_argument('--publish', action='store_true',
                            help='Expose the new games in the local review catalogue after the supported app is installed.')
        parser.add_argument('--dry-run', action='store_true')

    def handle(self, *args, **options):
        if settings.DATABASES['default']['ENGINE'] != 'django.db.backends.sqlite3':
            raise CommandError('This command changes only the local SQLite review database.')
        planned = []
        for definition in self.definitions:
            game = Game.objects.filter(slug=definition['slug']).first()
            _check_identity(game, definition)
            desired_game = _desired_game(definition, game, options['publish'])
            desired_levels = [_desired_level(definition, number) for number in (1, 2, 3)]
            for level in desired_levels:
                validate_level_definition(game_type=Game.Type.MATCHING, config=level['config'],
                                          max_score=level['max_score'], star_thresholds=level['star_thresholds'])
            levels = list(game.levels.all()) if game else []
            unchanged = bool(game and len(levels) == 3 and
                all(getattr(game, key) == value for key, value in desired_game.items()) and
                all(all(getattr(level, key) == value for key, value in desired.items())
                    for level, desired in zip(levels, desired_levels)))
            planned.append((definition, desired_game, desired_levels, unchanged))
        if all(plan[-1] for plan in planned):
            self.stdout.write('Selected local matching games are current; no data changed.')
            return
        if options['dry_run']:
            self.stdout.write('Selected matching games with three rounds each would be staged; no data changed.')
            return
        backup = backup_local_database(options['backup_directory'])
        with transaction.atomic():
            for definition, desired_game, desired_levels, unchanged in planned:
                if unchanged:
                    continue
                game = Game.objects.select_for_update().filter(slug=definition['slug']).first()
                _check_identity(game, definition)
                if game is None:
                    game = Game.objects.create(slug=definition['slug'], **desired_game)
                else:
                    for key, value in desired_game.items():
                        setattr(game, key, value)
                    game.save()
                for number, desired_level in enumerate(desired_levels, 1):
                    level, created = GameLevel.objects.get_or_create(
                        game=game, level_number=number, defaults=desired_level)
                    if not created:
                        for key, value in desired_level.items():
                            setattr(level, key, value)
                        level.save()
        visibility = 'available in the local review catalogue' if options['publish'] else 'staged unpublished'
        self.stdout.write(self.style.SUCCESS(
            f'{", ".join(definition["title"] for definition in self.definitions)} are {visibility}. Backup: {backup.name}'))
        self.stdout.write('Existing games, retired matching IDs, profiles, earned XP and attempts were not modified.')
