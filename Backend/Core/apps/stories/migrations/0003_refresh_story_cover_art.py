from django.db import migrations


NEW_COVER_KEYS = {
    'david-and-goliath': 'assets/images/stories/david-and-goliath-v2.webp',
    'jonah-and-the-big-fish': 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
    'crossing-the-red-sea': 'assets/images/stories/crossing-the-red-sea-v2.webp',
    'noah-builds-the-ark': 'assets/images/stories/noah-builds-the-ark-v2.webp',
    'creation-week': 'assets/images/stories/creation-week-v2.webp',
    'daniel-in-the-lions-den': 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
    'moses-follows-god': 'assets/images/stories/moses-follows-god-v2.webp',
    'esther-speaks-up': 'assets/images/stories/esther-speaks-up-v2.webp',
}


PREVIOUS_COVER_KEYS = {
    'david-and-goliath': 'assets/images/david_and_goliath.png',
    'jonah-and-the-big-fish': 'assets/images/jonah.jpg',
    'crossing-the-red-sea': 'assets/images/crossing_red_sea.webp',
    'noah-builds-the-ark': 'assets/images/noahs_ark.png',
    'creation-week': 'assets/images/creation_week.jpg',
    'daniel-in-the-lions-den': 'assets/images/daniel.jpeg',
    'moses-follows-god': 'assets/images/moses2.jpeg',
    'esther-speaks-up': 'assets/images/esther.jpeg',
}

PREVIOUS_COVER_FOCUS = {
    'david-and-goliath': (0.2, 0.1),
    'jonah-and-the-big-fish': (0, 0),
    'crossing-the-red-sea': (-0.38, 0),
    'noah-builds-the-ark': (-0.4, 0),
    'creation-week': (0, 0),
    'daniel-in-the-lions-den': (0, -0.12),
    'moses-follows-god': (0, 0),
    'esther-speaks-up': (0, 0),
}


def _set_cover_art(apps, cover_keys, cover_focus):
    Story = apps.get_model('stories', 'Story')
    for slug, cover_asset_key in cover_keys.items():
        focus_x, focus_y = cover_focus[slug]
        Story.objects.filter(slug=slug).update(
            cover_asset_key=cover_asset_key,
            cover_focus_x=focus_x,
            cover_focus_y=focus_y,
        )


def use_refreshed_cover_art(apps, schema_editor):
    centered_focus = {slug: (0, 0) for slug in NEW_COVER_KEYS}
    _set_cover_art(apps, NEW_COVER_KEYS, centered_focus)


def restore_previous_cover_art(apps, schema_editor):
    _set_cover_art(apps, PREVIOUS_COVER_KEYS, PREVIOUS_COVER_FOCUS)


class Migration(migrations.Migration):
    dependencies = [('stories', '0002_seed_initial_catalogue')]

    operations = [
        migrations.RunPython(
            use_refreshed_cover_art,
            restore_previous_cover_art,
        ),
    ]
