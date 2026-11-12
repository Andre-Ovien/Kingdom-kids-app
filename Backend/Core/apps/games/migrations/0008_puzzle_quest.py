from django.db import migrations, models


PUZZLE_SLUG = 'puzzle-quest'


def _slots(rows, columns):
    return [
        {
            'id': f'slot-{row + 1}-{column + 1}',
            'row': row,
            'column': column,
        }
        for row in range(rows)
        for column in range(columns)
    ]


def _puzzle_config(
    *,
    asset_key,
    artwork_title,
    alt_text,
    rows,
    columns,
    pieces,
    preview_seconds,
    target_seconds,
):
    public_pieces = [
        {
            'id': piece_id,
            'label': label,
            'source_row': row,
            'source_column': column,
        }
        for piece_id, label, row, column in pieces
    ]
    return {
        'artwork': {
            'asset_key': asset_key,
            'title': artwork_title,
            'alt_text': alt_text,
            'aspect_ratio': 1,
        },
        'grid': {'rows': rows, 'columns': columns},
        # The authored order is deliberately not the solved order. Devices may
        # shuffle again when a round begins.
        'pieces': public_pieces,
        'slots': _slots(rows, columns),
        'solution': {
            piece['id']: f"slot-{piece['source_row'] + 1}-{piece['source_column'] + 1}"
            for piece in public_pieces
        },
        'preview_seconds': preview_seconds,
        'target_moves': rows * columns,
        'target_seconds': target_seconds,
    }


LEVELS = (
    {
        'title': 'Rainbow Rescue',
        'instructions': (
            'Study the picture, then rebuild Noah’s bright ark with four big pieces.'
        ),
        'config': _puzzle_config(
            asset_key=(
                'assets/images/games/puzzle_quest/'
                'noahs-ark-rainbow-v1.webp'
            ),
            artwork_title='Noah’s Rainbow Ark',
            alt_text=(
                'A joyful wooden ark sailing beneath a bright rainbow with '
                'friendly animals and a dove.'
            ),
            rows=2,
            columns=2,
            pieces=(
                ('golden-dove', 'Rainbow, dove, and Noah puzzle piece', 0, 1),
                (
                    'splashing-water',
                    'Ark, zebras, sheep, and water puzzle piece',
                    1,
                    1,
                ),
                (
                    'warm-sunbeam',
                    'Rainbow, giraffes, and ark puzzle piece',
                    0,
                    0,
                ),
                (
                    'wooden-ark',
                    'Elephants, lions, and wooden ark puzzle piece',
                    1,
                    0,
                ),
            ),
            preview_seconds=6,
            target_seconds=45,
        ),
    },
    {
        'title': 'Shepherd Hills',
        'instructions': (
            'Remember David’s peaceful hillside, then fit six adventure pieces.'
        ),
        'config': _puzzle_config(
            asset_key=(
                'assets/images/games/puzzle_quest/'
                'david-shepherd-hills-v1.webp'
            ),
            artwork_title='David the Young Shepherd',
            alt_text=(
                'Young David watching cheerful sheep across colorful rolling '
                'hills beneath a glowing morning sky.'
            ),
            rows=2,
            columns=3,
            pieces=(
                ('gentle-sheep', 'Sheep and little harp puzzle piece', 1, 0),
                (
                    'morning-clouds',
                    'Clouds and hillside village puzzle piece',
                    0,
                    2,
                ),
                (
                    'little-harp',
                    'David’s robe and sandals puzzle piece',
                    1,
                    1,
                ),
                (
                    'golden-sunrise',
                    'Green tree and shepherd staff puzzle piece',
                    0,
                    0,
                ),
                ('wildflowers', 'Sheep and wildflowers puzzle piece', 1, 2),
                ('brave-shepherd', 'Young David puzzle piece', 0, 1),
            ),
            preview_seconds=6,
            target_seconds=75,
        ),
    },
    {
        'title': 'Promise Parade',
        'instructions': (
            'Rebuild the grand rainbow story scene with all nine sparkling pieces.'
        ),
        'config': _puzzle_config(
            asset_key=(
                'assets/images/games/puzzle_quest/'
                'puzzle-quest-cover-v1.webp'
            ),
            artwork_title='The Rainbow Promise',
            alt_text=(
                'Noah, his family, and friendly animals celebrating beneath '
                'a brilliant rainbow after the ark adventure.'
            ),
            rows=3,
            columns=3,
            pieces=(
                (
                    'promise-piece-g',
                    'Lamb, lion, deer, and trees puzzle piece',
                    1,
                    2,
                ),
                (
                    'promise-piece-h',
                    'Shining river and flowers puzzle piece',
                    2,
                    1,
                ),
                (
                    'promise-piece-c',
                    'Rainbow, dove, and clouds puzzle piece',
                    0,
                    2,
                ),
                (
                    'promise-piece-d',
                    'Noah, his wife, rabbit, and flowers puzzle piece',
                    2,
                    0,
                ),
                (
                    'promise-piece-a',
                    'Rainbow, dove, and leafy tree puzzle piece',
                    0,
                    0,
                ),
                (
                    'promise-piece-i',
                    'Lion and bright flowers puzzle piece',
                    2,
                    2,
                ),
                (
                    'promise-piece-e',
                    'Ark, green hills, and river puzzle piece',
                    1,
                    1,
                ),
                (
                    'promise-piece-b',
                    'Rainbow, giraffes, elephant, and ark puzzle piece',
                    0,
                    1,
                ),
                (
                    'promise-piece-f',
                    'Noah, his wife, flowers, and ark puzzle piece',
                    1,
                    0,
                ),
            ),
            preview_seconds=7,
            target_seconds=120,
        ),
    },
)


def seed_puzzle_quest(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    game, _ = Game.objects.update_or_create(
        slug=PUZZLE_SLUG,
        defaults={
            'title': 'Puzzle Quest',
            'subtitle': 'Study it. Shuffle it. Build it!',
            'description': (
                'Look closely at a brilliant Bible picture, then rebuild the '
                'whole scene one beautifully decorated piece at a time.'
            ),
            'game_type': 'puzzle',
            'difficulty': 'Easy',
            'estimated_duration_seconds': 240,
            'cover_asset_key': (
                'assets/images/games/puzzle_quest/'
                'puzzle-quest-cover-v1.webp'
            ),
            'accent_color': '#7C5CFC',
            'icon_key': 'extension',
            'is_featured': True,
            'is_published': True,
            'sort_order': 9,
        },
    )
    active_numbers = []
    for level_number, level in enumerate(LEVELS, start=1):
        active_numbers.append(level_number)
        GameLevel.objects.update_or_create(
            game=game,
            level_number=level_number,
            defaults={
                **level,
                'max_score': 100,
                'star_thresholds': [60, 80, 95],
            },
        )
    GameLevel.objects.filter(game=game).exclude(
        level_number__in=active_numbers,
    ).delete()


def remove_puzzle_quest(apps, schema_editor):
    GameAttempt = apps.get_model('games', 'GameAttempt')
    Game = apps.get_model('games', 'Game')
    GameAttempt.objects.filter(game__slug=PUZZLE_SLUG).delete()
    Game.objects.filter(slug=PUZZLE_SLUG).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0007_use_story_cover_art'),
    ]

    operations = [
        migrations.AlterField(
            model_name='game',
            name='game_type',
            field=models.CharField(
                choices=[
                    ('quiz', 'Quiz'),
                    ('memory', 'Memory cards'),
                    ('ordering', 'Ordering'),
                    ('matching', 'Matching'),
                    ('maze', 'Maze'),
                    ('path', 'Path finding'),
                    ('aim', 'Aim'),
                    ('puzzle', 'Puzzle'),
                ],
                max_length=16,
            ),
        ),
        migrations.RunPython(seed_puzzle_quest, remove_puzzle_quest),
    ]
