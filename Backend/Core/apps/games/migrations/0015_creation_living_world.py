from django.db import migrations


def author_creation_worlds(apps, schema_editor):
    from apps.games.creation_world import build_creation_world_config
    GameLevel = apps.get_model('games', 'GameLevel')
    levels = GameLevel.objects.using(schema_editor.connection.alias).filter(
        game__slug='creation-order', level_number__in=(1, 2, 3),
    )
    for level in levels:
        levels.filter(pk=level.pk).update(
            config=build_creation_world_config(level.level_number, level.config),
            instructions=(
                'Build each Creation day in Bible order. Place chunky water, land and plants; '
                'connect the river and leave a meadow route. Give the creatures safe homes, '
                'then tap and explore your living world.'
            ),
        )


class Migration(migrations.Migration):
    dependencies = [('games', '0014_ark_traffic_routes')]
    operations = [migrations.RunPython(author_creation_worlds, migrations.RunPython.noop)]
