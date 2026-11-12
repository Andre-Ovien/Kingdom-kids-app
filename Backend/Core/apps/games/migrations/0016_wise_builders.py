from django.db import migrations


def author_wise_builders(apps, schema_editor):
    from apps.games.wise_builders import build_wise_builders_config
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    alias = schema_editor.connection.alias
    game, _ = Game.objects.using(alias).get_or_create(slug='wise-and-foolish-builders', defaults={
        'title': 'The Wise and Foolish Builders', 'subtitle': 'Build, test, and discover what stands strong.',
        'description': 'Build two little houses, choose rock and sand foundations, and test them in rain and wind. Discover Jesus’s lesson from Matthew 7:24–27.',
        'game_type': 'ordering', 'difficulty': 'Easy', 'estimated_duration_seconds': 240,
        'cover_asset_key': 'assets/images/games/wise_builders/cover.png',
        'accent_color': '#E6A34A', 'icon_key': 'home', 'sort_order': 10,
        'is_featured': True, 'is_published': True,
    })
    for number, title in enumerate(('Rain on the Roof', 'A Gusty Afternoon', 'The Big Storm'), 1):
        GameLevel.objects.using(alias).get_or_create(game=game, level_number=number, defaults={
            'title': title, 'instructions': 'Choose rock and sand foundations. Build four walls, then the roof. Finish both houses and test the storm to discover which foundation stands strong.',
            'config': build_wise_builders_config(number), 'max_score': 100, 'star_thresholds': [60, 80, 95],
        })


class Migration(migrations.Migration):
    dependencies = [('games', '0015_creation_living_world')]
    operations = [migrations.RunPython(author_wise_builders, migrations.RunPython.noop)]
