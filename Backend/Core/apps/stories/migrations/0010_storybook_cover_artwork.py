"""Replace only the five expansion covers and their picture-puzzle artwork."""
from django.db import migrations


STORY_SLUGS = (
    'lost-sheep',
    'joseph-colorful-coat',
    'good-samaritan',
    'walls-of-jericho',
    'ruth-and-naomi',
)


def _replace_cover_references(apps, schema_editor, *, old_suffix, new_suffix):
    alias = schema_editor.connection.alias
    Story = apps.get_model('stories', 'Story')
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    for slug in STORY_SLUGS:
        old_asset = f'assets/images/stories/{slug}-{old_suffix}.webp'
        new_asset = f'assets/images/stories/{slug}-{new_suffix}.webp'
        # Conditional updates leave subsequent editorial choices untouched.
        Story.objects.using(alias).filter(
            slug=slug, cover_asset_key=old_asset,
        ).update(cover_asset_key=new_asset)
        game_slug = f'puzzle-{slug}'
        Game.objects.using(alias).filter(
            slug=game_slug, cover_asset_key=old_asset,
        ).update(cover_asset_key=new_asset)
        for level in GameLevel.objects.using(alias).filter(
            game__slug=game_slug,
        ).only('id', 'config'):
            config = level.config
            artwork = config.get('artwork') if isinstance(config, dict) else None
            if not isinstance(artwork, dict) or artwork.get('asset_key') != old_asset:
                continue
            # Keep the same puzzle, piece IDs, solutions and scoring settings.
            updated_config = {
                **config,
                'artwork': {**artwork, 'asset_key': new_asset},
            }
            GameLevel.objects.using(alias).filter(pk=level.pk).update(
                config=updated_config,
            )


def use_storybook_covers(apps, schema_editor):
    _replace_cover_references(
        apps, schema_editor, old_suffix='blender-v1', new_suffix='storybook-v1',
    )


def restore_previous_cover_references(apps, schema_editor):
    _replace_cover_references(
        apps, schema_editor, old_suffix='storybook-v1', new_suffix='blender-v1',
    )


class Migration(migrations.Migration):
    dependencies = [('stories', '0009_additional_bible_stories')]
    operations = [migrations.RunPython(
        use_storybook_covers, restore_previous_cover_references,
    )]
