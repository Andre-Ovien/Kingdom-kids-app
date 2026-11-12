"""Add new rows only; leave every existing story/game/progress ID untouched."""
import uuid
from django.db import migrations


def add_story_and_puzzle_catalogue(apps, schema_editor):
    from apps.stories.catalogue_expansion_v1 import STORIES, puzzle_games

    alias = schema_editor.connection.alias
    Story = apps.get_model('stories', 'Story')
    NarratorVoice = apps.get_model('stories', 'NarratorVoice')
    StoryNarration = apps.get_model('stories', 'StoryNarration')
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    voices = list(NarratorVoice.objects.using(alias).filter(avatar_key__in=('lion', 'dove', 'rainbow')))
    for payload in STORIES:
        fields = {key: value for key, value in payload.items() if key != 'scripture'}
        slug = fields.pop('slug')
        story, _ = Story.objects.using(alias).get_or_create(slug=slug, defaults={
            **fields, 'id': uuid.uuid5(uuid.NAMESPACE_URL, f'kingdom-kids/story/{slug}'),
            'author': 'Kingdom Kids', 'reading_time_minutes': 2,
            'cover_focus_x': 0, 'cover_focus_y': 0, 'review_count': 0,
            'rating': '4.8', 'is_featured': False, 'is_published': True,
        })
        for voice in voices:
            # The already approved character recordings will be attached by
            # the validated installer. No generic TTS voice is introduced.
            StoryNarration.objects.using(alias).get_or_create(
                story_id=story.pk, narrator_id=voice.pk,
                defaults={'status': 'processing'},
            )
    for payload in puzzle_games():
        levels = payload.pop('levels')
        slug = payload.pop('slug')
        game, _ = Game.objects.using(alias).get_or_create(slug=slug, defaults={
            **payload, 'id': uuid.uuid5(uuid.NAMESPACE_URL, f'kingdom-kids/game/{slug}'),
        })
        for level in levels:
            number = level.pop('level_number')
            GameLevel.objects.using(alias).get_or_create(
                game_id=game.pk, level_number=number,
                defaults={**level, 'id': uuid.uuid5(uuid.NAMESPACE_URL,
                                                   f'kingdom-kids/game/{slug}/level/{number}')},
            )


class Migration(migrations.Migration):
    dependencies = [
        ('stories', '0008_recorded_word_timings'),
        ('games', '0014_ark_traffic_routes'),
    ]
    # Data is retained on reverse so a downgrade cannot erase newly earned
    # progress or overwrite editorial changes. Old catalogue rows are untouched.
    operations = [migrations.RunPython(add_story_and_puzzle_catalogue, migrations.RunPython.noop)]
