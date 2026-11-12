from django.db import migrations


DRY_LAND_POLYGON = [
    [0.43, 0.33], [0.57, 0.33], [0.705, 0.43],
    [0.855, 0.70], [0.145, 0.70], [0.295, 0.43],
]


def align_crossing_dry_land(apps, schema_editor):
    GameLevel = apps.get_model('games', 'GameLevel')
    levels = GameLevel.objects.using(schema_editor.connection.alias).filter(
        game__slug='red-sea-path', level_number__in=(1, 2, 3),
    )
    for level in levels:
        crossing = level.config.get('crossing')
        if not isinstance(crossing, dict) or not isinstance(crossing.get('drop_zone'), dict):
            continue
        config = dict(level.config)
        config['crossing'] = dict(crossing)
        config['crossing']['drop_zone'] = dict(crossing['drop_zone'])
        # The old rectangle remains available to older app versions.
        config['crossing']['drop_zone']['polygon'] = DRY_LAND_POLYGON
        levels.filter(pk=level.pk).update(config=config)


class Migration(migrations.Migration):
    dependencies = [('games', '0011_red_sea_crossing')]
    operations = [
        migrations.RunPython(align_crossing_dry_land, migrations.RunPython.noop),
    ]
