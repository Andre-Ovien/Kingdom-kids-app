from django.db import migrations, models

import apps.games.models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0005_game_level_positive_number'),
    ]

    operations = [
        migrations.AlterField(
            model_name='gamelevel',
            name='star_thresholds',
            field=models.JSONField(default=apps.games.models.default_star_thresholds),
        ),
    ]
