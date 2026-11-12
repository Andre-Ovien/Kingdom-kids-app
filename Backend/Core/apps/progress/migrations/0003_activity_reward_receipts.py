from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('progress', '0002_streak_daily_visit'),
    ]

    operations = [
        migrations.AddField(
            model_name='kidactivityevent',
            name='reward_receipt',
            field=models.JSONField(default=dict),
        ),
        migrations.AddField(
            model_name='streakdailyvisit',
            name='reward_receipt',
            field=models.JSONField(default=dict),
        ),
    ]
