"""Install the reviewed matching release without importing test/user data."""
import hashlib
import json
from pathlib import Path
import uuid

from django.core.exceptions import ValidationError
from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction
from django.db.models import Prefetch

from apps.games.models import Game, GameLevel
from apps.games.validators import validate_level_definition


RELEASE_ID = 'published-matching-v1'
RELEASE_FILE = Path(__file__).resolve().parents[2] / 'content/published_matching_release_v1.json'
# Filled from the reviewed, deterministic bundle. A content revision needs a
# newly reviewed bundle/hash, not an arbitrary input manifest at deploy time.
RELEASE_SHA256 = 'b819fd5b5a398f0f3907149e0f33289c23a55b381e3cb703c1e9abad1139d378'
EXPECTED_MODES = {
    'josephs-coat-studio': 'coat_studio',
    'ruths-harvest': 'harvest_chain',
    'find-my-sheep': 'sheep_reunion',
    'creation-match-bloom': 'creation_bloom',
    'esthers-celebration-table': 'esther_table',
}
GAME_FIELDS = {
    'title', 'subtitle', 'description', 'game_type', 'difficulty',
    'estimated_duration_seconds', 'cover_asset_key', 'accent_color', 'icon_key',
    'is_featured', 'sort_order',
}
LEVEL_FIELDS = {'title', 'instructions', 'config', 'max_score', 'star_thresholds'}
RULE_FIELDS = ('config', 'max_score', 'star_thresholds')


def load_release(path):
    try:
        with Path(path).open('rb') as handle:
            raw = handle.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != RELEASE_SHA256:
            raise ValueError('The release checksum differs from the reviewed bundle.')
        release = json.loads(raw)
        if release.get('release_id') != RELEASE_ID or release.get('version') != 1:
            raise ValueError('Choose the reviewed version-one matching release.')
        games = release['games']
        if not isinstance(games, list) or len(games) != len(EXPECTED_MODES):
            raise ValueError('The release must contain exactly five matching games.')
        if {game['slug'] for game in games} != set(EXPECTED_MODES):
            raise ValueError('The release game identities are not the reviewed set.')
        for game in games:
            if set(game) != GAME_FIELDS | {'slug', 'levels'} or game['game_type'] != Game.Type.MATCHING:
                raise ValueError('The release has unexpected game fields or type.')
            candidate = Game(slug=game['slug'], is_published=False,
                             **{key: game[key] for key in GAME_FIELDS})
            candidate.full_clean(validate_unique=False, validate_constraints=False)
            levels = game['levels']
            if not isinstance(levels, list) or [row['level_number'] for row in levels] != [1, 2, 3]:
                raise ValueError('Each game must contain exactly rounds one through three.')
            for level in levels:
                if set(level) != LEVEL_FIELDS | {'level_number'}:
                    raise ValueError('The release has unexpected level fields.')
                if level['config'].get('mode') != EXPECTED_MODES[game['slug']]:
                    raise ValueError('The release mode does not match its game identity.')
                validate_level_definition(game_type=Game.Type.MATCHING,
                    config=level['config'], max_score=level['max_score'],
                    star_thresholds=level['star_thresholds'])
        return sorted(games, key=lambda row: row['slug'])
    except (OSError, ValueError, KeyError, TypeError, ValidationError) as exc:
        raise CommandError(f'The reviewed matching release is unavailable or invalid: {exc}') from exc


def check_existing(game, desired):
    if game is None:
        return
    if game.game_type != Game.Type.MATCHING:
        raise CommandError(f'{game.slug} belongs to a different game type; nothing was changed.')
    levels = list(game.levels.all())
    if [level.level_number for level in levels] != list(range(1, len(levels) + 1)) or len(levels) > 3:
        raise CommandError(f'{game.slug} has a different round identity; nothing was changed.')
    for level in levels:
        expected = desired['levels'][level.level_number - 1]
        # A bootstrap must never rewrite authored/played rules. Even an
        # unplayed conflict needs a separate explicit content revision.
        if any(getattr(level, field) != expected[field] for field in RULE_FIELDS):
            raise CommandError(f'{game.slug} has different existing rules; nothing was changed.')


class Command(BaseCommand):
    help = 'Validate or explicitly install the reviewed five-game matching release on SQLite/PostgreSQL.'

    def add_arguments(self, parser):
        parser.add_argument('--release-file', type=Path, default=RELEASE_FILE)
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument('--apply', action='store_true', help='Apply the validated release atomically.')
        mode.add_argument('--dry-run', action='store_true', help='Validate only (the default).')
        parser.add_argument('--publish', action='store_true',
                            help='Publish only these five games when --apply is also supplied.')

    def handle(self, *args, **options):
        definitions = load_release(options['release_file'])
        if not options['apply']:
            for desired in definitions:
                check_existing(Game.objects.filter(slug=desired['slug']).first(), desired)
            self.stdout.write('Validated five matching games / 15 rounds; dry-run, no data changed.')
            return
        with transaction.atomic():
            if connection.vendor == 'postgresql':
                # Serialize duplicate administrative deploy invocations,
                # including absent rows that select_for_update cannot lock.
                lock_id = int.from_bytes(hashlib.sha256(RELEASE_ID.encode()).digest()[:8], 'big', signed=True)
                with connection.cursor() as cursor:
                    cursor.execute('SELECT pg_advisory_xact_lock(%s)', [lock_id])
            current = {
                game.slug: game for game in Game.objects.select_for_update()
                .filter(slug__in=EXPECTED_MODES).order_by('slug')
                .prefetch_related(Prefetch('levels', queryset=GameLevel.objects.select_for_update()
                                          .order_by('level_number')))
            }
            for desired in definitions:
                check_existing(current.get(desired['slug']), desired)
            for desired in definitions:
                game = current.get(desired['slug'])
                values = {key: desired[key] for key in GAME_FIELDS}
                values['is_published'] = bool(options['publish']) or bool(game and game.is_published)
                if game is None:
                    game = Game.objects.create(
                        id=uuid.uuid5(uuid.NAMESPACE_URL, f"kingdom-kids/game/{desired['slug']}"),
                        slug=desired['slug'], **values)
                elif any(getattr(game, key) != value for key, value in values.items()):
                    for key, value in values.items():
                        setattr(game, key, value)
                    game.save()
                existing = {level.level_number: level for level in game.levels.all()}
                for row in desired['levels']:
                    number = row['level_number']
                    fields = {key: row[key] for key in LEVEL_FIELDS}
                    level = existing.get(number)
                    if level is None:
                        GameLevel.objects.create(
                            id=uuid.uuid5(uuid.NAMESPACE_URL, f'kingdom-kids/game/{game.slug}/level/{number}'),
                            game=game, level_number=number, **fields)
                    elif any(getattr(level, key) != value for key, value in fields.items()):
                        for key, value in fields.items():
                            setattr(level, key, value)
                        level.save()
        visibility = 'published' if options['publish'] else 'staged (existing publication preserved)'
        self.stdout.write(self.style.SUCCESS(
            f'Installed reviewed five matching games / 15 rounds: {visibility}.'))
        self.stdout.write('Existing IDs, other games, profiles, attempts, progress and earned XP were retained.')
