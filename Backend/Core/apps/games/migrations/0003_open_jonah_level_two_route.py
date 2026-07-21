from django.db import migrations


BLOCKED_SQUARE = [1, 3]


def open_route(apps, schema_editor):
    GameLevel = apps.get_model('games', 'GameLevel')
    level = GameLevel.objects.filter(
        game__slug='jonah-ocean-maze',
        level_number=2,
    ).first()
    if level is None:
        return
    config = dict(level.config)
    grid = dict(config['grid'])
    grid['walls'] = [wall for wall in grid.get('walls', []) if wall != BLOCKED_SQUARE]
    config['grid'] = grid
    level.config = config
    level.save(update_fields=('config',))


def close_route(apps, schema_editor):
    GameLevel = apps.get_model('games', 'GameLevel')
    level = GameLevel.objects.filter(
        game__slug='jonah-ocean-maze',
        level_number=2,
    ).first()
    if level is None:
        return
    config = dict(level.config)
    grid = dict(config['grid'])
    walls = list(grid.get('walls', []))
    if BLOCKED_SQUARE not in walls:
        walls.append(BLOCKED_SQUARE)
    grid['walls'] = walls
    config['grid'] = grid
    level.config = config
    level.save(update_fields=('config',))


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0002_seed_game_catalogue'),
    ]

    operations = [
        migrations.RunPython(open_route, close_route),
    ]
