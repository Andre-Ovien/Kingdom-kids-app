"""Install the new single-level garden locally, retaining all account history."""

import json
from pathlib import Path
import sqlite3

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from apps.games.ark_garden import validate_ark_garden_config
from apps.games.models import Game, GameLevel

SLUG = 'noahs-ark-garden'


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
    destination = directory / f'pre-ark-garden-{stamp}.sqlite3'
    # SQLite's backup API includes committed WAL pages consistently. Copying
    # the database file alone while the app is running would not do that.
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as original:
        with sqlite3.connect(destination) as backup:
            original.backup(backup)
    return destination


class Command(BaseCommand):
    help = 'Install the checked v2 Ark garden as a new local single-level game.'

    def add_arguments(self, parser):
        parser.add_argument('--course', type=Path, default=Path(__file__).resolve().parents[2] /
                            'content/ark_garden_course_v2.json')
        parser.add_argument('--backup-directory', type=Path,
                            default=settings.BASE_DIR / '.cache/ark-garden-backups')
        parser.add_argument('--publish', action='store_true',
                            help='Make this game available in the local review catalogue.')
        parser.add_argument('--dry-run', action='store_true')

    def handle(self, *args, **options):
        if settings.DATABASES['default']['ENGINE'] != 'django.db.backends.sqlite3':
            raise CommandError('This command changes only the local SQLite review database.')
        try:
            config = json.loads(options['course'].read_text())
            validate_ark_garden_config(config)
            if config['garden']['version'] != 2:
                raise ValueError('Only the complete v2 native garden can be installed.')
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise CommandError(f'The checked garden course is unavailable or invalid: {exc}') from exc
        game = Game.objects.filter(slug=SLUG).first()
        levels = list(game.levels.all()) if game else []
        if game and (game.game_type != Game.Type.MATCHING or any(
                level.level_number != 1 or level.config.get('mode') != 'ark_garden' for level in levels)):
            raise CommandError('The existing garden identity has another definition; nothing was changed.')
        desired = {
            'title': "Noah's Ark Garden", 'subtitle': 'Help every animal aboard',
            'description': 'Explore the garden, find the ten animals, and tap them to help them walk into the Ark.',
            'game_type': Game.Type.MATCHING, 'difficulty': Game.Difficulty.EASY,
            'estimated_duration_seconds': config['garden']['time_limit_ticks'] // 10,
            'cover_asset_key': 'story:noah', 'accent_color': '#4B9267', 'icon_key': 'pets',
            'sort_order': 3, 'is_published': bool(options['publish']) or bool(game and game.is_published),
        }
        level_values = {'title': 'All aboard',
                        'instructions': 'Find the ten animals and tap each one to help it into the Ark.',
                        'config': config, 'max_score': 100, 'star_thresholds': [60, 80, 95]}
        unchanged = game and len(levels) == 1 and all(getattr(game, key) == value for key, value in desired.items()) and all(
            getattr(levels[0], key) == value for key, value in level_values.items())
        if unchanged:
            self.stdout.write('The local single-level Ark garden is already current; no data changed.')
            return
        if options['dry_run']:
            self.stdout.write('The checked ten-animal course would install as one new local garden level; no data changed.')
            return
        backup = backup_local_database(options['backup_directory'])
        with transaction.atomic():
            game = Game.objects.select_for_update().filter(slug=SLUG).first()
            if game is None:
                game = Game.objects.create(slug=SLUG, **desired)
            else:
                for key, value in desired.items():
                    setattr(game, key, value)
                game.save()
            level, created = GameLevel.objects.get_or_create(game=game, level_number=1, defaults=level_values)
            if not created:
                for key, value in level_values.items():
                    setattr(level, key, value)
                level.save()
        self.stdout.write(self.style.SUCCESS(
            f'Installed the local Ark garden with one level and ten animals. Database backup: {backup.name}'))
        self.stdout.write('Retired matching games, profiles, earned XP and past attempts were not modified.')
