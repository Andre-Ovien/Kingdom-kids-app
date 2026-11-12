"""Retire Wise and Foolish Builders without deleting its earned history."""
from django.db import migrations


def retire_wise_builders(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    Game.objects.using(schema_editor.connection.alias).filter(
        slug='wise-and-foolish-builders',
    ).update(is_published=False)


class Migration(migrations.Migration):
    dependencies = [('games', '0019_retire_creation_order')]
    operations = [migrations.RunPython(retire_wise_builders, migrations.RunPython.noop)]
