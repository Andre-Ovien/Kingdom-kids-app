from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0004_game_catalogue_metadata'),
    ]

    operations = [
        migrations.AddConstraint(
            model_name='gamelevel',
            constraint=models.CheckConstraint(
                condition=models.Q(level_number__gte=1),
                name='game_level_number_at_least_one',
            ),
        ),
    ]
