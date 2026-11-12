from django.db import migrations


CROSSING_ROUNDS = {1: (10, 45), 2: (15, 30), 3: (20, 15)}


def expand_crossing_families(apps, schema_editor):
    GameLevel = apps.get_model('games', 'GameLevel')
    levels = GameLevel.objects.using(schema_editor.connection.alias).filter(
        game__slug='red-sea-path', level_number__in=CROSSING_ROUNDS,
    )
    for level in levels:
        crossing = level.config.get('crossing')
        if not isinstance(crossing, dict):
            continue
        count, seconds = CROSSING_ROUNDS[level.level_number]
        config = dict(level.config)
        config['crossing'] = {
            **crossing,
            'time_limit_seconds': seconds,
            'travellers': [
                {
                    'id': f'traveller-{index + 1}',
                    'label': f'{("Father", "Mother", "Child")[index % 3]} {index // 3 + 1}',
                }
                for index in range(count)
            ],
        }
        # Keep the level identity, lane geometry, legacy grid and saved progress.
        levels.filter(pk=level.pk).update(
            config=config,
            instructions=(
                'After the sea opens, drag each traveller onto the dry path. '
                f'Bring all {count} people across before the {seconds}-second timer ends.'
            ),
        )


class Migration(migrations.Migration):
    dependencies = [('games', '0012_crossing_dry_land_polygon')]
    operations = [
        migrations.RunPython(expand_crossing_families, migrations.RunPython.noop),
    ]
