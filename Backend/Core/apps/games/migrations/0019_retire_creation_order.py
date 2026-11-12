"""Retire Creation Order while preserving its content and earned rewards."""
from django.db import migrations


def retire_creation_order(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    Game.objects.using(schema_editor.connection.alias).filter(
        slug='creation-order',
    ).update(is_published=False)


class Migration(migrations.Migration):
    dependencies = [('games', '0018_retire_red_sea_path')]
    operations = [migrations.RunPython(retire_creation_order, migrations.RunPython.noop)]
