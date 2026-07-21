from django.db import migrations, models


GAME_METADATA = {
    'ark-animal-match': ('Easy', 180, True),
    'creation-order': ('Easy', 240, False),
    'david-sling-shot': ('Medium', 300, True),
    'jonah-ocean-maze': ('Medium', 240, False),
    'red-sea-path': ('Easy', 240, False),
    'daniel-memory': ('Easy', 180, True),
    'esther-quiz': ('Easy', 180, False),
    'moses-match': ('Medium', 300, False),
}


def populate_metadata(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    for slug, (difficulty, duration, featured) in GAME_METADATA.items():
        Game.objects.filter(slug=slug).update(
            difficulty=difficulty,
            estimated_duration_seconds=duration,
            is_featured=featured,
        )


def reset_metadata(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    Game.objects.filter(slug__in=GAME_METADATA).update(
        difficulty='Easy',
        estimated_duration_seconds=180,
        is_featured=False,
    )


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0003_open_jonah_level_two_route'),
    ]

    operations = [
        migrations.AddField(
            model_name='game',
            name='difficulty',
            field=models.CharField(
                choices=[
                    ('Easy', 'Easy'),
                    ('Medium', 'Medium'),
                    ('Challenging', 'Challenging'),
                ],
                default='Easy',
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name='game',
            name='estimated_duration_seconds',
            field=models.PositiveSmallIntegerField(default=180),
        ),
        migrations.AddField(
            model_name='game',
            name='is_featured',
            field=models.BooleanField(default=False),
        ),
        migrations.RunPython(populate_metadata, reset_metadata),
    ]
