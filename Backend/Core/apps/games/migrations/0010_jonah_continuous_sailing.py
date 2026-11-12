from django.db import migrations


OBSTACLE_X = (
    0.0, 0.74, -0.74, 0.2, -0.25, 0.65, -0.6, 0.38, -0.38,
    0.8, -0.8, 0.08, 0.5, -0.5, 0.15, -0.12, 0.7, -0.7, 0.0,
)


def sailing_config(level_number):
    count = {1: 12, 2: 15, 3: 19}[level_number]
    return {
        'duration_seconds': 60,
        'distance_m': 1200,
        'ship_radius': 0.09,
        'collision_window': 0.007,
        'max_hits': 3,
        'steer_speed': 1.4,
        'obstacles': [
            {
                'id': f'rock-{index + 1}',
                'progress': round(0.15 + 0.7 * index / (count - 1), 6),
                'x': OBSTACLE_X[index],
                'radius': (0.14, 0.16, 0.18)[level_number - 1],
            }
            for index in range(count)
        ],
    }


def add_continuous_sailing(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    alias = schema_editor.connection.alias
    game = Game.objects.using(alias).filter(
        slug='jonah-ocean-maze',
        is_published=True,
    ).first()
    if game is None:
        return
    Game.objects.using(alias).filter(pk=game.pk).update(
        subtitle='Steer through the storm to the calm shore',
        description=(
            'Sail with Jonah for one minute. Steer around ocean rocks and '
            'guide the boat safely to the calm shore.'
        ),
        estimated_duration_seconds=60,
    )
    levels = GameLevel.objects.using(alias).filter(game=game)
    for level in levels:
        if level.level_number not in (1, 2, 3):
            continue
        # Keep level IDs, existing progress, and the legacy grid route intact.
        config = dict(level.config)
        config['sailing'] = sailing_config(level.level_number)
        levels.filter(pk=level.pk).update(
            config=config,
            instructions=(
                'Slide left and right to steer Jonah’s boat. Avoid the rocks '
                'and reach the shore in 60 seconds. Three hits ends the voyage.'
            ),
        )


class Migration(migrations.Migration):
    dependencies = [('games', '0009_playful_gameplay')]
    operations = [
        migrations.RunPython(add_continuous_sailing, migrations.RunPython.noop),
    ]
