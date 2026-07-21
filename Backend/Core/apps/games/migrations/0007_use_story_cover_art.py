from django.db import migrations


NEW_COVER_KEYS = {
    'ark-animal-match': 'assets/images/stories/noah-builds-the-ark-v2.webp',
    'creation-order': 'assets/images/stories/creation-week-v2.webp',
    'david-sling-shot': 'assets/images/stories/david-and-goliath-v2.webp',
    'jonah-ocean-maze': 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
    'red-sea-path': 'assets/images/stories/crossing-the-red-sea-v2.webp',
    'daniel-memory': 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
    'esther-quiz': 'assets/images/stories/esther-speaks-up-v2.webp',
    'moses-match': 'assets/images/stories/moses-follows-god-v2.webp',
}


PREVIOUS_COVER_KEYS = {
    'ark-animal-match': 'assets/images/noahs_ark.png',
    'creation-order': 'assets/images/creation_week.jpg',
    'david-sling-shot': 'assets/images/david_and_goliath.png',
    'jonah-ocean-maze': 'assets/images/jonah.jpg',
    'red-sea-path': 'assets/images/crossing_red_sea.webp',
    'daniel-memory': 'assets/images/daniel.jpeg',
    'esther-quiz': 'assets/images/esther.jpeg',
    'moses-match': 'assets/images/moses2.jpeg',
}


def _set_cover_art(apps, cover_keys):
    Game = apps.get_model('games', 'Game')
    for slug, cover_asset_key in cover_keys.items():
        Game.objects.filter(slug=slug).update(cover_asset_key=cover_asset_key)


def use_story_cover_art(apps, schema_editor):
    _set_cover_art(apps, NEW_COVER_KEYS)


def restore_previous_cover_art(apps, schema_editor):
    _set_cover_art(apps, PREVIOUS_COVER_KEYS)


class Migration(migrations.Migration):
    dependencies = [('games', '0006_game_level_star_threshold_defaults')]

    operations = [
        migrations.RunPython(
            use_story_cover_art,
            restore_previous_cover_art,
        ),
    ]
