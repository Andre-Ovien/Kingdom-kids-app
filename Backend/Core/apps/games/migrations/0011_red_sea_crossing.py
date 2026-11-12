from django.db import migrations


def crossing_config(level_number):
    count = {1: 6, 2: 8, 3: 10}[level_number]
    return {
        'time_limit_seconds': 45,
        'travellers': [
            {'id': f'traveller-{index + 1}', 'label': f'Traveller {index + 1}'}
            for index in range(count)
        ],
        'drop_zone': {
            'left': 0.34,
            'top': 0.43,
            'right': 0.66,
            'bottom': 0.70,
        },
    }


def add_red_sea_crossing(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    alias = schema_editor.connection.alias
    game = Game.objects.using(alias).filter(
        slug='red-sea-path',
        is_published=True,
    ).first()
    if game is None:
        return
    Game.objects.using(alias).filter(pk=game.pk).update(
        subtitle='Help everyone cross the parted sea',
        description=(
            'Watch Moses raise his staff and the sea open. Move every traveller '
            'onto the dry path before time runs out, then see everyone reach '
            'the far shore safely.'
        ),
        estimated_duration_seconds=45,
    )
    levels = GameLevel.objects.using(alias).filter(game=game)
    for level in levels:
        if level.level_number not in (1, 2, 3):
            continue
        # Preserve the level's identity, previous unlocks and legacy grid.
        config = dict(level.config)
        config['crossing'] = crossing_config(level.level_number)
        levels.filter(pk=level.pk).update(
            config=config,
            instructions=(
                'After the sea opens, drag each traveller onto the dry path. '
                'Bring everyone across before the 45-second timer ends.'
            ),
        )


class Migration(migrations.Migration):
    dependencies = [('games', '0010_jonah_continuous_sailing')]
    operations = [
        migrations.RunPython(add_red_sea_crossing, migrations.RunPython.noop),
    ]
