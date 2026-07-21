from django.db import migrations, models


PREVIOUS_READ_TIMES = {
    'david-and-goliath': 4,
    'jonah-and-the-big-fish': 4,
    'crossing-the-red-sea': 4,
    'noah-builds-the-ark': 5,
    'creation-week': 5,
    'daniel-in-the-lions-den': 4,
    'moses-follows-god': 5,
    'esther-speaks-up': 4,
}


def use_short_read_times(apps, schema_editor):
    Story = apps.get_model('stories', 'Story')
    Story.objects.filter(slug__in=PREVIOUS_READ_TIMES).update(
        reading_time_minutes=2,
    )


def restore_read_times(apps, schema_editor):
    Story = apps.get_model('stories', 'Story')
    for slug, minutes in PREVIOUS_READ_TIMES.items():
        Story.objects.filter(slug=slug).update(reading_time_minutes=minutes)


class Migration(migrations.Migration):
    dependencies = [('stories', '0003_refresh_story_cover_art')]

    operations = [
        migrations.AlterField(
            model_name='story',
            name='reading_time_minutes',
            field=models.PositiveSmallIntegerField(default=2),
        ),
        migrations.RunPython(use_short_read_times, restore_read_times),
    ]
