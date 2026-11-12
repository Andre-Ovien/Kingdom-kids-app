from django.db import migrations


ARK_INSTRUCTIONS = {
    1: (
        'Draw connected trails to bring every animal aboard. The tortoise starts on the bridge! '
        'Tap an animal to wait or resume, and guide goats over the rocky shortcut.'
    ),
    2: (
        'Bring all ten animal friends aboard. Draw a new route from the next junction, '
        'tap animals to wait or resume, and tap the gate to open the east crossing.'
    ),
    3: (
        'Guide all twelve animals safely aboard. Manage the gates, avoid muddy delays, '
        'and spread the animals across different river routes for a smooth rescue.'
    ),
}


def author_ark_traffic(apps, schema_editor):
    from apps.games.ark_traffic import build_ark_traffic_config

    GameLevel = apps.get_model('games', 'GameLevel')
    levels = GameLevel.objects.using(schema_editor.connection.alias).filter(
        game__slug='ark-animal-match', level_number__in=ARK_INSTRUCTIONS,
    )
    for level in levels:
        # Preserve all existing level UUIDs, titles, rewards, progress, and
        # legacy matching portraits/answer fields for older clients.
        config = build_ark_traffic_config(level.level_number, level.config)
        levels.filter(pk=level.pk).update(
            config=config,
            instructions=ARK_INSTRUCTIONS[level.level_number],
        )


class Migration(migrations.Migration):
    dependencies = [('games', '0013_crossing_family_rounds')]
    operations = [migrations.RunPython(author_ark_traffic, migrations.RunPython.noop)]
