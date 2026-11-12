"""Pause the three action games without removing content or earned history."""

from django.db import migrations


PAUSED_GAME_SLUGS = (
    'david-sling-shot',
    'jonah-ocean-maze',
    'noahs-ark-garden',
)


def pause_action_games(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    Game.objects.using(schema_editor.connection.alias).filter(
        slug__in=PAUSED_GAME_SLUGS,
    ).update(is_published=False)


class Migration(migrations.Migration):
    dependencies = [('games', '0021_prune_quiz_and_puzzle_catalogue')]
    operations = [
        # A rollback must not silently reopen gameplay. All game/level IDs,
        # rules, media and receipts remain available for an explicit future
        # resume by setting is_published=True on these exact existing games.
        migrations.RunPython(pause_action_games, migrations.RunPython.noop),
    ]
