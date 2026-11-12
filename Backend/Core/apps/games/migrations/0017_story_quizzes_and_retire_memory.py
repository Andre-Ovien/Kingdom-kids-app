"""Add nine story quizzes and retire Memory/Match without deleting history."""
from django.db import migrations


RETIRED_GAME_SLUGS = ('daniel-memory', 'ark-animal-match', 'moses-match')


def add_story_quizzes_and_retire_memory(apps, schema_editor):
    from apps.games.story_quizzes_v1 import quiz_games

    alias = schema_editor.connection.alias
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    for definition in quiz_games():
        defaults = {key: value for key, value in definition.items() if key not in {'slug', 'levels'}}
        game, _ = Game.objects.using(alias).get_or_create(slug=definition['slug'], defaults=defaults)
        for level in definition['levels']:
            GameLevel.objects.using(alias).get_or_create(
                game=game, level_number=level['level_number'],
                defaults={key: value for key, value in level.items() if key != 'level_number'},
            )
    # Protected attempts, best-progress rows, and their saved XP remain intact.
    Game.objects.using(alias).filter(slug__in=RETIRED_GAME_SLUGS).update(is_published=False)


class Migration(migrations.Migration):
    dependencies = [
        ('games', '0016_wise_builders'),
        ('stories', '0010_storybook_cover_artwork'),
    ]
    # Content retirement is deliberately not reversed into a deletion of games
    # that children may already have played. A future catalogue edit is additive.
    operations = [migrations.RunPython(add_story_quizzes_and_retire_memory, migrations.RunPython.noop)]
