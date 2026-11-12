"""Retire the Red Sea Path quest without deleting earned progress or XP."""
from django.db import migrations


def retire_red_sea_path(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    Game.objects.using(schema_editor.connection.alias).filter(
        slug='red-sea-path',
    ).update(is_published=False)


class Migration(migrations.Migration):
    dependencies = [('games', '0017_story_quizzes_and_retire_memory')]
    # Reversing a catalogue retirement must not silently republish a quest.
    # Its levels, attempts, and progress remain available for a future edit.
    operations = [migrations.RunPython(retire_red_sea_path, migrations.RunPython.noop)]
