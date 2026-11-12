"""Retire selected extra quizzes and puzzles without deleting earned history."""
from django.db import migrations


RETIRED_GAME_SLUGS = (
    'puzzle-red-sea',
    'puzzle-jonah',
    'puzzle-joseph-colorful-coat',
    'puzzle-good-samaritan',
    'puzzle-walls-of-jericho',
    'puzzle-ruth-and-naomi',
    'creation-quiz',
    'joseph-colorful-coat-quiz',
    'good-samaritan-quiz',
    'walls-of-jericho-quiz',
    'ruth-and-naomi-quiz',
)


def retire_extra_quizzes_and_puzzles(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    Game.objects.using(schema_editor.connection.alias).filter(
        slug__in=RETIRED_GAME_SLUGS,
    ).update(is_published=False)


class Migration(migrations.Migration):
    dependencies = [('games', '0020_retire_wise_and_foolish_builders')]
    operations = [
        migrations.RunPython(retire_extra_quizzes_and_puzzles, migrations.RunPython.noop),
    ]
